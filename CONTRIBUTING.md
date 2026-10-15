# Contributing to AWS Windows Domain Runbooks

Thank you for your interest in contributing to **AWS Windows Domain Runbooks**!

This repository provides offline-verified AWS Systems Manager (SSM) automation documents, Step Functions orchestration, CloudFormation infrastructure templates, and PowerShell 5.1 operational runbooks for managing self-hosted Windows Active Directory and WSUS on Amazon EC2.

---

## Autonomous LLM & Engineering Safety Contract

All contributors, human operators, and AI agents operating in this repository must adhere to the following invariants:

1. **Change Ticket Gate:** Every mutation (`Apply=true`, CloudFormation stack deployment, worker package publish) requires a verified `ChangeTicket`.
2. **Preview Mode:** All automation documents, runbooks, and scripts must default to inspection/diagnostic mode (`Apply=false`) and report `PREVIEW` before any mutating operation.
3. **WSUS Authority Invariant:** WSUS is the sole update authority. Never introduce fallbacks to public Microsoft Update, Windows Update APIs, or AWS Patch Manager.
4. **Node Classification Boundary:** Tier 0 Domain Controllers and Active Directory Certificate Services (AD CS) CAs are strictly isolated from general member server roles.
5. **Environment Variable Interpolation (`ENV_VAR`):** SSM Command documents must use `ENV_VAR` interpolation type. Direct raw parameter interpolation (`{{ Parameter }}`) is strictly prohibited to prevent script injection.
6. **Zero Secrets in Repository:** Never commit real AWS credentials, production Account IDs, Active Directory password hashes, private keys, or internal network topologies. Use standard placeholders (`123456789012`, `111122223333`, `example.local`, `10.0.1.50`).

---

## Local Development & Testing Workflow

### Prerequisites
- **Node.js 20+**
- **Windows PowerShell 5.1** (on Windows)

### Installing Dependencies
```powershell
npm ci
```

### Running the Test Suite
The repository maintains strict test parity between local execution and GitHub Actions CI:
```powershell
npm test
```
This executes:
1. **PowerShell Pack Invariant Gate** (`tests/Validate-Pack.ps1`): Validates YAML parsing, SSM document limits, environment variable guards, PowerShell 5.1 syntax compatibility, and WSUS authority invariants.
2. **Cloud Orchestration Unit Tests** (`tests/fleet-orchestration.test.mjs`): Tests Lambda handlers for dispatch, reconcile, cancel, and report logic.
3. **CloudFormation Infrastructure Validation** (`tests/validate-infra.cjs`): Validates offline YAML syntax, intrinsic tags (`!Sub`, `!Ref`), and structure across all templates in `infra/`.

### Individual Test Commands
- `npm run test:powershell` — Executes PowerShell pack validation only.
- `npm run test:orchestration` — Executes Node.js fleet orchestration tests only.
- `npm run test:infra` — Executes CloudFormation template validation only.
- `npm run test:documents` — Tests SSM document schemas and runbook link integrity.
- `npm run test:planning` — Validates requirement and task checkpoint traceability.

### Lab Qualification Testing
To test the end-to-end qualification runner in offline mode:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Invoke-LabQualification.ps1 -SkipLiveChecks
```

---

## Coding & Architectural Standards

### PowerShell 5.1 Compatibility
- All worker scripts (`workers/`) and runbook tooling (`scripts/`) must execute under **Windows PowerShell 5.1**.
- **Prohibited:** PowerShell 7+ syntax such as null-coalescing operators (`??`, `??=`), safe navigation (`?.`), ternary expressions (`? :`), `ConvertFrom-Json -AsHashtable`, or `Test-Json`.
- **Assertions:** Use native PowerShell assertions and language parser APIs; do not add external test framework dependencies like Pester.
- **Zip Compression:** When creating ZIP packages in PowerShell 5.1, use `.NET` `[System.IO.Compression.ZipFile]::CreateFromDirectory` rather than `Compress-Archive` to prevent Windows file handle leaks.

### Systems Manager (SSM) Documents
- Command documents must use `schemaVersion: '2.2'`, target Windows platforms (`platformType: Windows`), and declare `aws:runPowerShellScript`.
- Automation approval wrappers must use `schemaVersion: '0.3'` with an `aws:approve` gate and pinned child document versions.
- Parameters must specify `type: String` and `interpolationType: ENV_VAR`.

### CloudFormation Templates
- Templates must conform to `AWSTemplateFormatVersion: "2010-09-09"`.
- Use CloudFormation pseudo-parameters (`AWS::Region`, `AWS::AccountId`, `AWS::Partition`) instead of hardcoding region or account strings.
- Enforce least-privilege IAM policies with explicit `Deny` rules protecting Tier 0 resources and preventing secret tampering.

---

## Pull Request Process

1. Fork the repository and create a branch from `main`.
2. Ensure `npm test` passes completely (0 errors, all invariant checks passing).
3. Verify no secrets, unallowlisted ARNs, or personal credentials are added (Gitleaks runs automatically on PRs).
4. Open a Pull Request referencing any related issues and complete the PR checklist.
5. All CI checks (`secret-scan` and `validate`) must pass before a pull request can be merged.

---

## Security Vulnerabilities

Please **do not** open public GitHub issues or discussions for security vulnerabilities. Review our [Security Policy](SECURITY.md) to report vulnerabilities privately via GitHub Private Vulnerability Reporting.

