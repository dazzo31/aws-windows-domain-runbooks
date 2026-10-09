---
title: "Runbook: Audit, Evidence Lineage, and Data Retention"
status: "UNTESTED_REFERENCE_SPECIFICATION"
offline_verified: true
lab_testing_required: true
target_audience:
  - "Human Systems Administrators"
  - "Autonomous LLM / AI Orchestration Agents"
last_updated: "2026-10-08"
---

# Runbook: Audit, Evidence Lineage, and Data Retention

> [!WARNING]
> **UNTESTED IN LIVE PRODUCTION ENVIRONMENT — LAB QUALIFICATION REQUIRED**  
> The procedures, commands, and architectural patterns in this runbook have been verified offline against simulated fixtures and syntax parsers. They have **never been executed against a live enterprise Active Directory forest or production WSUS hierarchy**.  
> Every procedure must be rehearsed and verified in an isolated testbed lab (Gates G1–G3) before considering live staging or production execution.

## LLM Execution Instructions
When an Autonomous Agent or LLM is reading or executing steps from this runbook:
1. **Safety Gate:** Verify caller possesses `WuuOperatorRole` or audit retrieval credentials.
2. **Lineage Verification:** Ensure the unbroken chain of custody (`ChangeTicket` -> `PlanId` -> `ExecutionArn` -> `CommandId` -> `OperationId` -> Node Evidence) is complete.
3. **Data Minimization:** Prohibit recording plain-text secrets, credentials, or customer PII in audit payloads.
4. **Immutability:** Never overwrite existing S3 evidence objects or alter historical DynamoDB records.

## 1. Executive Summary & Evidence Lineage

This runbook establishes the cryptographic provenance, evidence lineage, data minimization, and retention standards for all WUU2-CLI automated patch deployments across AWS and Windows infrastructure.

Every fleet action must provide an unbroken chain of custody:
```text
Change Ticket (Jira/ServiceNow)
  ↓
Frozen Deployment Plan (SHA-256 PlanDigest)
  ↓
SSM Automation Approval (Approver IAM Role Session)
  ↓
Step Functions Execution (State Machine Execution ARN)
  ↓
SSM SendCommand (Command ID + Numeric Document Version)
  ↓
Local Worker Execution (Local Atomic Journal + Exit Code)
  ↓
Authoritative Dual-Envelope Result (S3 VersionId + Digest)
```

---

## 2. Local Journal & Cryptographic Hash-Chain Anchoring

### Local Host Journals
Managed nodes maintain per-operation journals under the protected path `C:\ProgramData\WUU\journal\`:
- Accessible only by `NT AUTHORITY\SYSTEM` and local `Administrators`.
- Each journal record includes: `operationId`, `changeTicket`, `action`, `startTime`, `bootIdentifier`, and update outcomes.
- Upon completion, the local worker calculates the SHA-256 hash of the journal record (`JournalDigest`).

### Off-Host Anchoring
To prevent host tampering or accidental destruction from invalidating audit records:
1. The `JournalDigest` is returned in the dual-envelope stdout result payload.
2. The Lambda reconciler (`cloud/reconcile.mjs`) anchors the digest into the encrypted DynamoDB operations table (`wuu-operations-${Environment}`).
3. The full structured result payload is written to the immutable S3 results bucket (`s3://wuu-artifacts-${Environment}/results/`).

---

## 3. Data Minimization & Secret Redaction

Audit and log records must adhere to strict data minimization principles:
- **No Credentials:** Passwords, private keys, Kerberos ticket grantors, and AWS session tokens are strictly prohibited from logs, journals, and reports.
- **Reference Over Value:** Parameter Store SecureStrings must only be logged by parameter name (`/wuu/passwords/admin`), never by decrypted value.
- **Error Sanitization:** Diagnostic outputs must preserve Windows error codes (e.g., `0x80240020`, `0x80070005`) and module messages while stripping any system memory dumps or credentials.

---

## 4. Retention Lifecycle Policies

### DynamoDB State Records
- Operational records (PK: `OP#...`, SK: `RESULT#...`) have a configurable `RecordTtl` timestamp attribute (default: 90 days).
- **Critical Invariant:** Time-To-Live (TTL) expiration in DynamoDB must **never** be used to release an active lock. Lock records (SK: `LOCK_STATE`) are explicitly managed and cleared by the reconciler.

### Amazon S3 Result Artifacts
- **0–90 Days:** S3 Standard storage for immediate audit queries.
- **91–365 Days:** Transition to S3 Standard-Infrequent Access (Standard-IA).
- **366+ Days:** Expire or transition to S3 Glacier Flexible Retrieval based on organizational regulatory policy.

### CloudWatch Logs
- State machine and Lambda logs are retained for 30 days under customer-managed KMS encryption.

---

## 5. S3 Object Lock & Compliance Holds

- **Default Setting:** S3 buckets use standard S3 Versioning with bucket policies enforcing TLS 1.2+ (`aws:SecureTransport: true`).
- **Object Lock (Governance Mode):** May be enabled in staging and production to prevent accidental deletion of deployment reports by privileged administrators during the retention period.
- **Object Lock (Compliance Mode):** Strictly requires written sign-off from the Lead Architect and Infrastructure Owner prior to activation. In Compliance Mode, neither AWS accounts nor root users can delete objects or alter the retention period before expiration.

