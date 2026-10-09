---
title: "Runbook: Day-2 Fleet Operations and Cost Governance"
status: "UNTESTED_REFERENCE_SPECIFICATION"
offline_verified: true
lab_testing_required: true
target_audience:
  - "Human Systems Administrators"
  - "Autonomous LLM / AI Orchestration Agents"
last_updated: "2026-10-08"
---

# Runbook: Day-2 Fleet Operations and Cost Governance

> [!WARNING]
> **UNTESTED IN LIVE PRODUCTION ENVIRONMENT — LAB QUALIFICATION REQUIRED**  
> The procedures, commands, and architectural patterns in this runbook have been verified offline against simulated fixtures and syntax parsers. They have **never been executed against a live enterprise Active Directory forest or production WSUS hierarchy**.  
> Every procedure must be rehearsed and verified in an isolated testbed lab (Gates G1–G3) before considering live staging or production execution.

## LLM Execution Instructions
When an Autonomous Agent or LLM is reading or executing steps from this runbook:
1. **Safety Gate:** Verify caller role matches operating role assignments (`WuuOperatorRole` vs `WuuApproverRole`).
2. **Quarantine Handling:** Investigate quarantined nodes individually; never clear node locks without reviewing DynamoDB and CBS logs.
3. **Cost Governance:** Monitor CloudWatch metrics for excessive Step Functions state transitions or DynamoDB throttling.
4. **Maintenance Windows:** Abort scheduled mutations if window deadline is within 30 minutes.

## 1. Operational Overview & Ownership

This runbook establishes standard operating procedures for operating, monitoring, and budgeting the WUU2-CLI AWS Systems Manager integration.

### Operating Roles & Responsibilities
- **Deployment Operator:** Prepares changes, scopes member server batches, initiates deployment plans, monitors Step Functions progress.
- **Change Approver:** Independent technical authority who reviews frozen plan digests against approved change tickets and signals approval.
- **Incident Owner:** Responsible for resolving quarantined nodes, CBS servicing corruptions, and reconciliation mismatches.

---

## 2. Concurrency Budgets & API Quotas

### SSM SendCommand Rate Limits
- AWS SSM enforces account-level limits on `SendCommand` requests (default 40 TPS).
- Fleet sequencing bounds concurrency via Step Functions:
  - **Phase 1 (Canary):** Strictly `MaxConcurrency = 1`.
  - **Phases 2–5 (Batches):** `MaxConcurrency = 5` per phase.
- Polling intervals in Step Functions use 15-second minimum wait intervals to prevent hitting SSM `GetCommandInvocation` rate limits.

### DynamoDB Capacity Management
- Tables are provisioned with `PAY_PER_REQUEST` (on-demand billing) to absorb bursts during large fleet deployments without requiring manual capacity planning.

---

## 3. Cost Governance & Drivers

### Primary Cost Drivers
1. **VPC Endpoints (PrivateLink):**
   - Endpoints (`ssm`, `ssmmessages`, `logs`) incur hourly charges per Availability Zone plus data processing fees.
   - Deploy VPC endpoints only in VPCs hosting managed nodes; utilize S3 Gateway Endpoints (free of charge) for all S3 traffic.
2. **CloudWatch Logs Ingestion:**
   - Detailed PowerShell execution transcripts can consume significant storage.
   - Retain logs for 30 days maximum, with KMS encryption.
3. **S3 Artifacts & Results:**
   - Enforce lifecycle rules transitioning results to Infrequent Access after 90 days.

---

## 4. Reconciliation Ownership & Incident Triage

### Quarantine Handling
- When a node enters `QUARANTINED` state (due to transport timeout, unknown exit status, or network disruption):
  1. Automated deployments halt at the end of the current phase.
  2. The Incident Owner receives an alert via `wuu-alerts-${Environment}` SNS topic.
  3. The Incident Owner inspects the node using `Get-DeploymentStatus.ps1` and AWS EC2 console logs.
  4. Once health is restored, the quarantine record is released manually as documented in `REBOOT-AND-PATCH-RECOVERY.md`.

### Blind Unlock Prohibition
- **Absolute Rule:** Operators must never execute blind deletions of DynamoDB lock items (`LOCK_STATE`) while an SSM command or Step Functions execution may still be active. Reconcile or cancel before releasing locks.

---

## 5. Backup Monitoring & Safe Cleanup

### WSUS Database (SUSDB) Backups
- The `WinDomain-WSUSServer.yaml` cleanup action requires `BackupConfirmed = true`.
- Operators must verify that a full SQL Server backup or volume snapshot of SUSDB was completed within the preceding 24 hours before approving cleanup.

### Resource Deprovisioning Safeguards
- When decommissioning an environment:
  - Do not delete S3 buckets containing compliance reports without audit sign-off.
  - Enable deletion protection on DynamoDB tables with PITR enabled until data export is complete.

