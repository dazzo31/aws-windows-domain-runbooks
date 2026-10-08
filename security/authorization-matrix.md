# AWS IAM & Node Authorization Matrix

Date: 2026-10-07  
Status: G0/G1 Specification & Policy Matrix  
Scope: Positive and negative permissions per role, anti-tag-tampering controls, separation of duties, and break-glass procedures.

---

## 1. Principles of Least Privilege

1. **Separation of Requester and Approver:** An operator submitting a patch deployment cannot approve the execution. Self-approval is architecturally blocked by assigning distinct IAM roles.
2. **Deny Direct Execution by Operators:** Operators can only trigger the reviewed SSM Automation wrapper (`Wuu-ApprovedDeployment`). Direct `ssm:SendCommand`, `states:StartExecution`, or `lambda:InvokeFunction` calls are explicitly denied.
3. **Strict Prohibition of Arbitrary Scripts:** Generic script execution documents (`AWS-RunPowerShellScript`, `AWS-RunShellScript`) are prohibited for all normal operational roles. Only reviewed, versioned, immutable `Wuu-*` and `WinDomain-*` documents are permitted.
4. **Anti-Tag-Tampering:** Managed instances cannot modify their own EC2 tags or those of peer instances. Tag modification is denied in `WuuManagedNodeRole`.
5. **Node Class Resource Scoping:** SSM commands dispatched by the coordinator must target instances explicitly tagged with `WuuNodeClass=memberServer`. Domain Controllers and CAs cannot be targeted by fleet commands.

---

## 2. Comprehensive Role Authorization Matrix

| Action / Capability | Operator | Approver | Publisher | Automation Service | Coordinator | Managed Node | AD Password Worker |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Start Automation (`Wuu-ApprovedDeployment`)** | **ALLOW** | DENY | DENY | DENY | DENY | DENY | DENY |
| **PassRole to Automation Service** | **ALLOW** | DENY | DENY | DENY | DENY | DENY | DENY |
| **Send Automation Signal (Approval)** | DENY | **ALLOW** | DENY | DENY | DENY | DENY | DENY |
| **Publish / Update SSM Documents** | DENY | DENY | **ALLOW** | DENY | DENY | DENY | DENY |
| **Upload Worker Packages (`packages/*`)** | DENY | DENY | **ALLOW** | DENY | DENY | DENY | DENY |
| **Invoke Validation Lambda** | DENY | DENY | DENY | **ALLOW** | DENY | DENY | DENY |
| **Start Step Functions State Machine** | DENY | DENY | DENY | **ALLOW** | DENY | DENY | DENY |
| **Dispatch SSM SendCommand (Wuu-*)** | DENY | DENY | DENY | DENY | **ALLOW** *(memberServer only)* | DENY | DENY |
| **Arbitrary RunPowerShellScript** | **DENY** | **DENY** | **DENY** | **DENY** | **DENY** | **DENY** | **DENY** |
| **Download Worker Package (`packages/*`)** | DENY | DENY | DENY | DENY | DENY | **ALLOW** | DENY |
| **Upload Result Artifacts (`results/*`)** | DENY | DENY | DENY | DENY | DENY | **ALLOW** | DENY |
| **Read Domain Credentials (`/wuu/*/ad/*`)** | **DENY** | **DENY** | **DENY** | **DENY** | **DENY** | **DENY** | **ALLOW** |
| **Decrypt Secrets KMS Key** | **DENY** | **DENY** | **DENY** | **DENY** | **DENY** | **DENY** | **ALLOW** *(via SSM)* |
| **Modify EC2 Tags (`Create/DeleteTags`)** | **DENY** | DENY | DENY | DENY | DENY | **DENY** | **DENY** |

---

## 3. Delegation & Windows Execution Evidence

### 3.1 LocalSystem Context on Managed Nodes
* All Systems Manager commands executed on managed Windows nodes run as **NT AUTHORITY\SYSTEM**.
* Under `SYSTEM`, the process authenticates to remote Windows services and Active Directory as the computer account (`DOMAIN\COMPUTER$`).
* No domain administrator credentials or user delegation tokens are stored, cached, or utilized by the SSM Agent.

### 3.2 Tier 0 Active Directory Separation
* Domain Controllers (`domainController`) and Certificate Authorities (`certificateAuthority`) are strictly excluded from generic fleet patching.
* Run Command targeting DCs is restricted to read-only diagnostics (`WinDomain-Health.yaml`) executed under separate, individually authorized Tier 0 change tickets.

---

## 4. Break-Glass Procedure & Audit Controls

### 4.1 Break-Glass Access
In the event of an automated deployment failure where the coordinator is unable to communicate with fleet instances:
1. Break-glass access requires assuming a dedicated, time-bounded role (`WuuBreakGlassAdminRole`).
2. The assumption of this role triggers an immediate high-priority CloudWatch / SNS alert to the security operations team.
3. All session activity is recorded verbatim in AWS CloudTrail and AWS Systems Manager Session Manager session logs.
4. The maximum session duration is hard-limited to 60 minutes (`DurationSeconds: 3600`).

### 4.2 Automated Policy Verification
The authorization matrix rules defined above are validated programmatically prior to deployment via [`scripts/Test-AwsAuthorization.ps1`](../scripts/Test-AwsAuthorization.ps1).

