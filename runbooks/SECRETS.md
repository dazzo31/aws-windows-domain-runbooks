---
title: "Secrets Management And Credential Isolation Runbook"
status: "UNTESTED_REFERENCE_SPECIFICATION"
offline_verified: true
lab_testing_required: true
target_audience:
  - "Human Systems Administrators"
  - "Autonomous LLM / AI Orchestration Agents"
last_updated: "2026-10-08"
---

# Secrets Management And Credential Isolation Runbook

> [!WARNING]
> **UNTESTED IN LIVE PRODUCTION ENVIRONMENT — LAB QUALIFICATION REQUIRED**  
> The procedures, commands, and architectural patterns in this runbook have been verified offline against simulated fixtures and syntax parsers. They have **never been executed against a live enterprise Active Directory forest or production WSUS hierarchy**.  
> Every procedure must be rehearsed and verified in an isolated testbed lab (Gates G1–G3) before considering live staging or production execution.

## LLM Execution Instructions
When an Autonomous Agent or LLM is reading or executing steps from this runbook:
1. **Zero Raw Secrets Invariant:** Never pass passwords, secrets, or API keys directly as SSM document parameters or shell arguments.
2. **Path Boundary:** Verify secret paths adhere strictly to `/wuu/<environment>/secrets/<nodeClass>/` scoping.
3. **KMS Isolation:** Only Tier 0 AD Password Worker roles may possess KMS Decrypt rights; patch workers are strictly denied access.
4. **Audit Cleansing:** Ensure all script outputs and logs scrub secret references and parameter paths.

---

## 1. Overview and Core Invariant

The WUU2-CLI AWS integration strictly isolates credentials and sensitive domain material from generic fleet patching operations:

> [!IMPORTANT]
> **TIER 0 CREDENTIAL BOUNDARY:**  
> Fleet patch workers (`WuuManagedNodeRole`), standard operators (`WuuOperatorRole`), and Step Functions coordinators (`WuuCoordinatorRole`) are **explicitly denied** access to domain secrets and customer-managed KMS decryption keys.
>
> Decryption permissions are granted **exclusively** to the dedicated AD Password Worker (`WuuAdPasswordWorkerRole`) on isolated, designated management nodes.

---

## 2. Parameter Hierarchy & Path Convention

All credentials must be stored as Systems Manager Parameter Store `SecureString` parameters under the standard environment hierarchy:

```text
/wuu/<environment>/ad/credentials/<credential-identifier>
```

Examples:
* `/wuu/lab/ad/credentials/ad-admin-svc`
* `/wuu/staging/ad/credentials/ad-join-account`
* `/wuu/prod/ad/credentials/break-glass-recovery`

### 2.1 Encryption Key Binding
* All credentials under `/wuu/<environment>/ad/credentials/*` must be encrypted using the dedicated Customer Managed Key defined in [`infra/secrets.yaml`](../infra/secrets.yaml) (`alias/wuu-credentials-<environment>`).
* Using the default AWS-managed key (`alias/aws/ssm`) is **prohibited** because default keys cannot enforce custom key policies, role conditions, or service-choked decryption.

---

## 3. Role Access Matrix

| Role | SSM Parameter Access | KMS Decrypt Access | Justification |
|---|---|---|---|
| **WuuOperatorRole** | DENIED (`*`) | DENIED (`*`) | Operators submit immutable deployment plans; they never handle credentials directly. |
| **WuuApproverRole** | DENIED (`*`) | DENIED (`*`) | Approvers review change manifests and plans; no secret access required. |
| **WuuCoordinatorRole** | DENIED (`/wuu/*/ad/credentials/*`) | DENIED (`*`) | Orchestrates fleet commands and state tracking; zero domain secret access. |
| **WuuManagedNodeRole** | **STRICTLY DENIED** (`ssm:GetParameter*`) | **STRICTLY DENIED** (`kms:Decrypt`) | Member server fleet patch nodes execute local updates as `SYSTEM` via WSUS; no domain secrets permitted. |
| **WuuAdPasswordWorkerRole** | **ALLOWED** (`/wuu/<env>/ad/credentials/*`) | **ALLOWED** (`kms:Decrypt` via `ssm.<region>.amazonaws.com`) | Scoped worker for Active Directory account password rotation operations. |

---

## 4. Key Policy Guardrails in `infra/secrets.yaml`

The customer-managed key policy enforces:
1. **Service Choke (`kms:ViaService`):**
   Decryption calls must originate through AWS Systems Manager in the target region (`ssm.<region>.amazonaws.com`). Direct KMS CLI calls from local workstations or untrusted services are rejected.
2. **Explicit Deny Statements:**
   All fleet patch node roles (`arn:aws:iam::<account>:role/wuu-managed-node-*`) and operator roles (`arn:aws:iam::<account>:role/wuu-operator-*`) are explicitly denied `kms:Decrypt`, taking precedence over any attached administrative policies.
3. **Automatic Key Rotation:**
   Annual automatic cryptographic key rotation is enabled (`EnableKeyRotation: true`).

---

## 5. Safe Secret Retrieval Procedure (Password Worker Only)

When executed by the authorized AD Password Worker under `WuuAdPasswordWorkerRole`:

```powershell
# Safe retrieval into a secure string in memory
$paramPath = "/wuu/$env:SSM_Environment/ad/credentials/$env:SSM_CredentialName"

$param = Get-SSMParameter -Name $paramPath -WithDecryption $true
$securePassword = ConvertTo-SecureString -String $param.Value -AsPlainText -Force

# Clear plaintext memory immediately
$param.Value = $null
$param = $null
[GC]::Collect()
```

### 5.1 Redaction and Logging Prohibitions
* Never write `$securePassword` or plaintext credentials to `$stdout`, `$stderr`, disk logs, or temporary files.
* Never interpolate plaintext passwords into SSM document commands or Step Functions execution input.
* Systems Manager parameters must be referenced strictly by parameter name (e.g., `$env:SSM_PasswordParameter`), never by raw value.

---

## 6. Audit & Emergency Procedures

### 6.1 CloudTrail Decryption Auditing
Every decryption request emits a CloudTrail `Decrypt` event containing:
* `userIdentity.arn`: The calling IAM role ARN (must match `wuu-ad-password-worker-*`).
* `requestParameters.encryptionContext`: Systems Manager parameter ARN.
* `eventTime` and `sourceIPAddress`.

Any `Decrypt` event originating from unauthorized roles triggers a critical CloudWatch alarm via [`infra/observability.yaml`](../infra/observability.yaml).

### 6.2 Break-Glass Revocation
In the event of suspected credential compromise or unauthorized access attempt:
1. **Disable KMS Key Immediately:**
   ```powershell
   aws kms disable-key --key-id alias/wuu-credentials-<environment>
   ```
2. **Revoke Active IAM Role Sessions:**
   Apply an inline deny policy or update the role's revocation epoch to invalidate existing STS credentials.
3. **Rotate Underlying Domain Passwords:**
   Directly rotate domain service account passwords from an isolated Tier 0 Domain Controller console.

