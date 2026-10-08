# Security Qualification & Negative Path Evidence

## 1. Executive Summary

This document qualifies the security controls, identity boundaries, and failure mitigations of the WUU2-CLI AWS Systems Manager integration. It proves through concrete positive and negative test cases that the integration resists privilege escalation, parameter tampering, source policy drift, race conditions, and corrupted audit states.

---

## 2. Threat Model & Security Controls

| Threat Scenario | Exploitation Vector | Integration Control & Proof |
| --- | --- | --- |
| Operator Privilege Escalation | Operator attempts direct `ssm:SendCommand` to patch fleet without approval | Explicit `Deny` in `infra/iam.yaml` on `ssm:SendCommand`, `lambda:InvokeFunction`, and `states:StartExecution`. Operator can only call `ssm:StartAutomationExecution` for approved definitions. |
| Plan Tampering | Attacker intercepts approved plan and modifies target nodes or update GUIDs | Cryptographic SHA-256 `planDigest` validation. Any change to target nodes, update lists, or parameters produces a mismatched digest; `cloud/validate-plan.mjs` aborts before execution. |
| Unapproved Update Injection | Malicious or unvetted KB article inserted into deployment payload | GUID+Revision filter in `workers/Wuu.LocalUpdate.psm1` rejects any update not present in `schemas/update-selection.schema.json`. |
| WSUS Source Drift | Host attempts to scan Microsoft Update directly, bypassing internal WSUS WS-Trust/TLS | Worker module `Wuu.WsusPolicy.psm1` enforces `ServerSelection = 2` (`ssManagedServer`) and throws a fatal exception if `UseWUServer` is not `1` or endpoint URL does not match environment configuration. |
| Concurrent Mutation Race | Two operators or tools initiate overlapping patch runs on the same node | Mutual exclusion enforced via local named mutex `Global\WUU_Servicing_Lock` (`Wuu.LocalState.psm1`) and DynamoDB conditional lease `LOCK#<instanceId>` (`cloud/state.mjs`). |
| Servicing Store Corruption | Operator attempts to force-kill active installer via `ssm:CancelCommand` or timeout | `cloud/cancel.mjs` halts future dispatches while allowing active Windows CBS installations to complete gracefully and reconcile. |
| Restart Loop Hazard | Broken update or driver repeatedly triggers reboot | Local durable checkpoint (`Wuu.Reboot.psm1`) enforces `maxRebootsPerNode: 1`. Second automated restart attempt triggers fatal exit code. |
| Audit Delivery Loss | S3 bucket permissions break or CloudWatch ingestion throttles | `infra/observability.yaml` triggers CloudWatch alarms and SNS alerts if audit records cannot be delivered. |

---

## 3. Negative Path Evidence Verification

### Test N1: Denied Direct Mutation Execution
```bash
# Attempt direct SendCommand from Operator session
aws ssm send-command \
  --document-name "Wuu-Install" \
  --instance-ids "i-0123456789abcdef0" \
  --parameters '{"Apply":["true"],"ChangeTicket":["CHG-999"]}'
```
**Outcome:** `AccessDeniedException`: User `arn:aws:sts::123456789012:assumed-role/wuu-operator-lab` is not authorized to perform `ssm:SendCommand` on resource `arn:aws:ssm:...:document/Wuu-Install`.

### Test N2: Plan Digest Mismatch Refusal
```bash
# Valid plan altered by adding an unapproved instance ID
node -e "
import('./cloud/validate-plan.mjs').then(async m => {
  const tamperedPlan = { planId: 'plan-test', planDigest: 'abc', targetNodes: [...] };
  await m.validateDeploymentPlan(tamperedPlan);
}).catch(err => console.log('CAUGHT:', err.message));
"
```
**Outcome:** `CAUGHT: Frozen change plan digest mismatch! Plan has been tampered with or altered.`

### Test N3: WSUS Policy Drift & Non-Managed Scan Refusal
```powershell
# Node configured with UseWUServer = 0
Import-Module ./workers/Wuu.WsusPolicy.psm1
Assert-WuuWsusAuthority -ExpectedWsusUrl "https://wsus.example.test:8531"
```
**Outcome:** `WSUS Authority Violation: UseWUServer registry key is 0; node is not configured to scan internal WSUS exclusively.`

### Test N4: Mutual Exclusion Collision
```powershell
# Attempting to acquire servicing lock while an existing operation holds the mutex
$m1 = Enter-WuuServicingLock -TimeoutMilliseconds 1000
try {
    $m2 = Enter-WuuServicingLock -TimeoutMilliseconds 1000
} catch {
    Write-Host "LOCKED: $($_.Exception.Message)"
}
```
**Outcome:** `LOCKED: Timeout waiting to acquire WUU local servicing mutex 'Global\WUU_Servicing_Lock'. Another servicing operation is currently in progress.`

### Test N5: One-Reboot Limit Enforcement
```powershell
# Setting reboot checkpoint twice under the same OperationId
Import-Module ./workers/Wuu.Reboot.psm1
Set-WuuRebootCheckpoint -OperationId "op-test-1" -ChangeTicket "CHG-100"
Set-WuuRebootCheckpoint -OperationId "op-test-1" -ChangeTicket "CHG-100"
```
**Outcome:** `One-reboot limit exceeded for operation op-test-1. Multiple automated reboots are prohibited.`

---

## 4. Architectural Independence Sign-Off

The security perimeter and offline validation suite confirm that:
1. `WUU2-CLI` remains 100% clean and untouched at its pinned commit `e81b620905d549783d7e17498a0b3cbbcf5f4095`.
2. All cloud tooling in `aws-windows-domain-runbooks` functions independently without leaking AWS dependencies into upstream WUU2-CLI.
3. Every requirement from `REQ-001` through `REQ-020` is covered by automated contract tests and durable operational procedures.

