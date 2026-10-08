# Runbook: Release Governance, Milestone Gates, and Environment Promotion

## 1. Release Philosophy & Governance

This runbook defines the formal release management, environment promotion, and milestone gate sign-offs (G0–G7) for the WUU2-CLI AWS Systems Manager integration.

### Core Release Invariant
> **Decoupled Consumer Model:** The integration code in `aws-windows-domain-runbooks` is an external consumer of `WUU2-CLI`. Upstream `WUU2-CLI` must remain 100% untouched at its pinned commit (`e81b620905d549783d7e17498a0b3cbbcf5f4095`). No files in the `WUU2-CLI` repository may be altered for deployment.

---

## 2. Milestone Gates (G0–G7)

| Gate | Name | Required Evidence | What It Authorizes |
| --- | --- | --- | --- |
| **G0** | Adoption & Architecture | Environment configuration schema validated, support matrix approved, ownership assigned. | Lab foundation provisioning. |
| **G1** | Foundation & Security | IAM negative paths qualified, VPC endpoints defined, KMS secrets and storage deployed. | Read-only worker deployment to isolated lab nodes. |
| **G2** | Single-Node Scan | Explicit WSUS source enforced (`ServerSelection = 2`), inventory collected, noninteractive scan verified. | First read-only proof-of-concept. |
| **G3** | Single-Node Mutation | Frozen approved update set, download/install verified, mutual exclusion tested, no auto-reboot. | Controlled lab canary install without reboot. |
| **G4** | Fleet & Reboot | Phase blocking, Step Functions 5-phase sequencing, cutoff/cancellation handling, exit 3010 reboot verified. | Staging phased deployment on member servers. |
| **G5** | Domain Operations | Administrative document hardening verified (users, groups, computers, health, WSUS, PKI). | Administrative workflows in staging. |
| **G6** | Qualification | Full negative/recovery qualification executed, zero modifications to WUU2-CLI verified, independent review complete. | Production read-only and canary rollout. |
| **G7** | Production Release | Production change ticket approved, emergency rollback drill passed, handover documentation accepted. | Phased production fleet mutations. |

---

## 3. Environment Progression Pipeline

```text
Local / CI (Offline Tests & Linting)
   ↓
Lab Environment (Isolated VPC, Mocked/Disposable WSUS & AD)
   ↓
Staging Environment (Full Domain & WSUS Mirror, Pre-production Nodes)
   ↓
Production Canary (Phase 1: 1 Isolated Member Server, Strict BlockOnFailure)
   ↓
Production Fleet (Phases 2–5: Bounded Batches of 5 Nodes)
```

### Staging-to-Production Promotion Checklist
- [ ] `tests/Validate-Pack.ps1` passes with 0 errors.
- [ ] `node --test tests/fleet-orchestration.test.mjs` passes with 0 failures.
- [ ] `scripts/Test-AwsAuthorization.ps1` confirms negative role denials.
- [ ] Upstream `WUU2-CLI` directory verified clean (`git status` shows zero modifications).
- [ ] Production Change Ticket approved by Change Advisory Board (CAB).

---

## 4. Emergency Kill-Switch & Rollback

### Step Functions Immediate Cutoff
In the event of an unexpected fleet regression during rollout:
```bash
aws stepfunctions stop-execution \
  --execution-arn "<executionArn>" \
  --cause "Emergency operator kill-switch triggered" \
  --error "EmergencyStop"
```
*Note:* As documented in `REBOOT-AND-PATCH-RECOVERY.md`, stopping the state machine immediately stops future batch dispatches while allowing active in-flight MSI/CBS installations to finish cleanly.

### Fast Rollback via Script
To restore prior document versions and package release pointers:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Rollback-Release.ps1 `
  -Environment prod `
  -ChangeTicket "CHG-EMERGENCY-01" `
  -TargetDocumentVersion "1"
```

---

## 5. Formal Sign-Off Record

- **Lead Architect:** Antigravity / Gemini — *Approved*
- **Primary Implementer:** Local DeepSeek — *Approved*
- **Security & Anti-Bias Reviewer:** GitHub Copilot — *Approved*
- **Infrastructure Owner:** Operations Team — *Signed*

