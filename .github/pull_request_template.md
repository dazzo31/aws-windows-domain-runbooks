## Description

Please provide a summary of the changes proposed in this Pull Request, including the motivation, affected runbooks/documents, and any architectural context.

---

## Type of Change

- [ ] **Bug fix** (non-breaking change fixing a specification error or test failure)
- [ ] **New runbook / document** (addition of an operational procedure or SSM automation definition)
- [ ] **Infrastructure / CloudFormation** (changes to templates under `infra/`)
- [ ] **Worker / Orchestration** (changes to local PowerShell worker modules or Step Functions handlers)
- [ ] **Documentation / Governance** (updates to README, contribution guidelines, or planning checkpoints)

---

## Safety & Invariant Checklist

Before submitting this PR, please confirm that your changes adhere to repository invariants:

- [ ] **Offline Tests Pass:** I have executed `npm test` locally and all assertions pass (PowerShell pack invariants, Node fleet orchestration, and CloudFormation validation).
- [ ] **Zero Secrets & Dummy ARNs:** No live AWS credentials, actual account IDs, password hashes, or private network topology are included. All ARNs use standard dummy placeholders (`123456789012`, `111122223333`).
- [ ] **Safety Contract Compliance:** All mutating operations default to `Apply=false` (`PREVIEW`), require an explicit `ChangeTicket`, and use `ENV_VAR` parameter interpolation.
- [ ] **WSUS Authority Invariant:** Changes do not introduce fallbacks or calls to public Microsoft Update or Windows Update services.
- [ ] **PowerShell 5.1 Compatibility:** Code runs under Windows PowerShell 5.1 without PowerShell 7+ syntax (no `??`, `?.`, ternary operators, or `ConvertFrom-Json -AsHashtable`).
- [ ] **Decoupled Consumer Model:** The upstream WUU2-CLI engine is consumed without in-place modification.

