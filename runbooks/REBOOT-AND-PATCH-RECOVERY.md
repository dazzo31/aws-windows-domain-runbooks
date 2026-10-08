# Runbook: Reboot and Patch Recovery

## 1. Executive Summary & Scope

This runbook defines the operational procedures for managing node reboots, postcheck failures, boot hangs, and patch rollbacks during WUU2-CLI automated fleet deployments.

### Scope Boundaries
- **In Scope:** Windows Server member servers (`WuuNodeClass: memberServer`) undergoing scheduled WSUS patch installation via AWS Systems Manager.
- **Strictly Out of Scope:** Domain Controllers, Active Directory Certificate Services (AD CS) Certification Authorities, and multi-node Failover Clusters. These roles require manual, coordinator-supervised maintenance and must never be subjected to automated multi-node reboot workflows.

---

## 2. Service Draining & Workload Quiescing

Prior to initiating an approved host restart:
1. **Load Balancer Connection Draining:** If the target host participates in an Application Load Balancer (ALB) or Network Load Balancer (NLB) target group, deregister the target and allow existing in-flight connections to drain (minimum 300 seconds).
2. **Scheduled Tasks & Batch Workloads:** Check for active background batch processing jobs. Delay reboot until current batch operations complete.
3. **Cluster Node Pausing:** If member server runs clustered services (e.g., SQL Server Always On Availability Groups), failover the primary replica before executing host reboot.

---

## 3. SSM Exit Code 3010 Mechanics & One-Reboot Limit

### Exit Code 3010 Contract
AWS Systems Manager Agent natively recognizes process exit code `3010` (`ERROR_SUCCESS_REBOOT_REQUIRED`). When a PowerShell command block in an SSM Document terminates with exit code 3010:
1. SSM Agent marks the command execution step as completed.
2. SSM Agent triggers a graceful Windows operating system restart (`shutdown.exe /r /t 5`).
3. Upon reboot and SSM Agent service initialization, SSM Agent reports step status back to the AWS SSM backend.

### Strict One-Reboot Enforcement
To protect the fleet from catastrophic infinite reboot loops:
- Every reboot invocation writes a durable local checkpoint file (`C:\ProgramData\WUU\state\reboot-checkpoint.json`).
- If a node attempts a second automated restart under the same `OperationId`, the worker module (`Wuu.Reboot.psm1`) throws a terminal error (`One-reboot limit exceeded`).
- Manual operator intervention is required to clear or authorize additional reboots.

---

## 4. Failure Scenarios & Diagnostics

### Scenario A: Restart-Not-Observed (Boot Hang or Timeout)
- **Symptom:** Step Functions or SSM marks the post-reboot polling step as `TimedOut` or `Undeliverable`.
- **Diagnostic Steps:**
  1. Inspect EC2 Instance Status Checks (`StatusCheckFailed_System` vs `StatusCheckFailed_Instance`).
  2. Retrieve EC2 System Log: `aws ec2 get-console-output --instance-id <instanceId>`.
  3. Connect to the EC2 Serial Console (if SAC / Emergency Management Services enabled) to observe Windows Boot Manager / BSOD codes.
  4. If the instance is unresponsive due to driver crash or CBS servicing corruption, stop the instance and attach root volume to an offline rescue instance to inspect `C:\Windows\Logs\CBS\CBS.log`.

### Scenario B: Repeated Pending Reboot Deadlock
- **Symptom:** Postcheck detects that `Test-WuuPendingReboot` remains `$true` despite a clean system reboot.
- **Root Cause:** A third-party driver or incomplete MSI installer continuously populates `PendingFileRenameOperations` in `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager`.
- **Remediation:**
  1. Inspect the registry values under `Session Manager\PendingFileRenameOperations`.
  2. If the pending rename is benign (e.g., temporary file cleanup), clear the specific key.
  3. Re-run `Wuu-Verify.yaml` to confirm readiness.

### Scenario C: Postcheck / Service Failure
- **Symptom:** Postcheck fails because essential services (`LanmanServer`, `W32Time`, `EventLog`, `AmazonSSMAgent`) failed to restart.
- **Remediation:**
  1. Check Windows Event Viewer System and Application logs.
  2. Manually start services via PowerShell: `Start-Service -Name <ServiceName>`.
  3. If service fails due to patch conflict, proceed to Patch Rollback.

---

## 5. Patch Rollback Procedures

> [!WARNING]
> **EBS Snapshots are NOT a Universal Recovery Plan:**
> Reverting a live domain-joined Windows server to an earlier EBS snapshot introduces critical machine account password desynchronization with Active Directory and can cause Kerberos authentication failures. In clustered or database applications, snapshot restores can cause transactional data loss and split-brain states. Always prefer native package uninstallation.

### Native Patch Uninstallation via WUSA
To roll back a faulty cumulative update:
```powershell
# Query installed packages
Get-HotFix -Id KB5000000

# Execute silent uninstallation
wusa.exe /uninstall /kb:5000000 /quiet /norestart
```

### Native Patch Uninstallation via DISM
If WUSA uninstallation fails or the update was deployed via servicing stack:
```powershell
# List installed packages
dism.exe /Online /Get-Packages /Format:Table

# Remove offending package
dism.exe /Online /Remove-Package /PackageName:Package_for_RollupFix~31bf3856ad364e35~amd64~~19041.1000.1.0 /Quiet /NoRestart
```

---

## 6. Node Quarantine Release Procedures

When a node enters `QUARANTINED` status in DynamoDB (due to communication transport loss or unknown outcome):
1. Complete manual verification of the node's health and patch status.
2. Remove the quarantine record in DynamoDB using the AWS CLI or administrative tool:
```bash
aws dynamodb delete-item \
  --table-name wuu-operations-lab \
  --key '{"PK": {"S": "LOCK#i-0123456789abcdef0"}, "SK": {"S": "QUARANTINE_STATE"}}'
```
3. Release any lingering lock:
```bash
aws dynamodb delete-item \
  --table-name wuu-operations-lab \
  --key '{"PK": {"S": "LOCK#i-0123456789abcdef0"}, "SK": {"S": "LOCK_STATE"}}'
```
4. Resume fleet operations or schedule a fresh scan.

