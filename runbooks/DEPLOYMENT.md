---
title: "Deployment And Permissions"
status: "UNTESTED_REFERENCE_SPECIFICATION"
offline_verified: true
lab_testing_required: true
target_audience:
  - "Human Systems Administrators"
  - "Autonomous LLM / AI Orchestration Agents"
last_updated: "2026-10-08"
---

# Deployment And Permissions

> [!WARNING]
> **UNTESTED IN LIVE PRODUCTION ENVIRONMENT — LAB QUALIFICATION REQUIRED**  
> The procedures, commands, and architectural patterns in this runbook have been verified offline against simulated fixtures and syntax parsers. They have **never been executed against a live enterprise Active Directory forest or production WSUS hierarchy**.  
> Every procedure must be rehearsed and verified in an isolated testbed lab (Gates G1–G3) before considering live staging or production execution.

## LLM Execution Instructions
When an Autonomous Agent or LLM is reading or executing steps from this runbook:
1. **Safety Gate:** Verify caller possesses `WuuPublisherRole` or infrastructure admin credentials with an active `ChangeTicket`.
2. **Preview Mode:** Always validate CloudFormation change sets (`DryRun`) before stack execution.
3. **IAM Least Privilege:** Enforce strict separation between AD management nodes, DC diagnostics, and member servers.
4. **No Blanket Grants:** Never grant full Domain Admin or CA Admin rights to generic SSM instance profiles.

All commands in this runbook are examples for the future environment. They were not executed during pack creation. Replace every sample account, ARN, instance, domain, OU, region, template and policy scope.

## Required Decisions

Record Windows Server editions/versions, forest/domain functional levels, region/account, DC names, management-node instance IDs, delegated OUs/groups, DNS zones, GPO IDs, WSUS port/TLS/database topology, CA hierarchy/template names and artifact retention rules. This pack intentionally does not assume those details.

Use separate target roles/tags for AD management, DC diagnostics, DNS, WSUS and PKI. Do not grant every SSM-managed node domain-admin or CA-admin rights. Restrict who can modify target tags, assume privileged roles, update SSM documents, or execute other arbitrary-script documents.

## Target Prerequisites

| Target | Requirements |
| --- | --- |
| All Windows targets | Healthy current SSM Agent >=3.3.2746.0, Windows PowerShell 5.1, SSM managed-node IAM/core permissions, required endpoint access |
| AD management | Domain membership, ActiveDirectory RSAT module, AD Web Services/DNS connectivity, computer-account rights delegated only to managed objects |
| User password operations | Preinstalled AWS.Tools.SimpleSystemsManagement compatible with PowerShell 5.1, configured AWS region, node permission to read a narrow SecureString path and decrypt its KMS key |
| DC health | NTDS/Netlogon/DFSR/DNS/W32Time, ActiveDirectory module, repadmin, dcdiag, SMB cmdlets; Server must identify the target DC |
| DNS | DnsServer module and permitted local DNS administration |
| GPO | GroupPolicy and ActiveDirectory modules; delegated GPO read/backup/link rights; writable protected backup directory |
| WSUS server | Installed WSUS role, UpdateServices and WebAdministration modules, WsusPool, configured API/TLS port, healthy database access |
| WSUS client | Windows Update/BITS services, domain computer policy, outbound WSUS connectivity; no concurrent maintenance |
| CA administration | certutil and CertificateAuthority.Request/Admin COM APIs, DCOM/RPC access to CA, delegated CA rights. Validate on the selected OS; do not assume COM availability on every member server |
| Machine enrollment | PKI module, certreq, domain enrollment policy, local machine private key access and template enrollment rights |

SSM Run Command normally executes as **LocalSystem**. On a domain member it authenticates to remote AD/services as the computer account (`DOMAIN\HOST$`). AWS IAM permissions do not grant AD rights. This pack does not implement alternate AD credentials or a gMSA worker. Use a dedicated delegated management computer account, or design and review a separate constrained worker if your policy requires one.

Do not use a domain controller as the general-purpose mutation worker: LocalSystem there has extremely broad authority. Treat SSM access to DCs/CAs as Tier 0. Never grant an ordinary operator arbitrary Run Command access to those nodes.

Provision `C:\ProgramData\WinDomain` and its `Requests`, `DNSBackups`, `GPOBackups` subdirectories before use. Limit write/delete access to SYSTEM and the designated service administrators; remove untrusted inherited write permissions. Reject any junction/symlinked staging directories. These artifacts and backups may contain sensitive directory/policy data. They are not a replacement for off-host, encrypted, tested backups.

## IAM Separation

**Managed-node role:** SSM core access and required logging permissions. Only the AD password worker gets `ssm:GetParameter` on the approved password path plus `kms:Decrypt` for the dedicated key, with suitable key policy/encryption-context restrictions. No wildcard access to all secrets.

**Automation service role:** trust only `ssm.amazonaws.com`, constrained by `aws:SourceAccount` and the account/region's Automation execution ARN. Grant `ssm:SendCommand` on only these child document ARNs and the approved EC2 instance resources/tags. Grant required document reads and command-status reads; status/list APIs may require `Resource="*"`. Do not grant this role SSM document mutation, IAM administration or arbitrary `AWS-RunPowerShellScript` execution.

**Operator role:** allow `ssm:StartAutomationExecution` only on the approved wrapper definition and `iam:PassRole` only for its fixed service role, with `iam:PassedToService=ssm.amazonaws.com`. Provide narrowly scoped read access to execution history. Do not allow direct `ssm:SendCommand`, other arbitrary Automation definitions, target-tag changes, role-policy changes or document updates. If other attached policies grant direct commands, use a suitable explicit deny/permission boundary for the operator; do not apply that deny to the Automation service role.

**Approver role:** allow execution inspection and `ssm:SendAutomationSignal` for the relevant executions. Keep it distinct from requester and document publisher. Fixed approver identity alone does not prevent self-approval if an operator can assume the approver role; enforce separation through IAM/identity policy.

**Document publisher:** separate reviewed deployment role permitted to create/update these documents. Only reviewed numeric child versions may be approved. Numeric pinning prevents default-version drift, but does not prevent a privileged publisher deleting/recreating a document; use change control and CloudTrail alerts.

The IAM design here is a requirements specification, not a ready-to-attach policy granting universal Windows administration. Test it with IAM simulation and actual denied/allowed lab executions before production.

## Import Documents

Edit the fixed account/role/approver ARNs in the approval wrapper first. Keep the default `Apply=false` values in the child documents.

Example for one child document:

```powershell
aws ssm create-document --region eu-west-2 --name WinDomain-Users --document-type Command --document-format YAML --content file://documents/WinDomain-Users.yaml
```

Repeat for the other ten files using their file basenames as names. The approval wrapper is the only document of type `Automation`:

```powershell
aws ssm create-document --region eu-west-2 --name WinDomain-ApprovedChange --document-type Automation --document-format YAML --content file://documents/WinDomain-ApprovedChange.yaml
```

For an existing document, use `update-document` with an explicit reviewed base version. Do not blindly replace an existing default version or overwrite unrelated documents. Record the resulting numeric version and content hash with the change ticket. AWS create/update is the authoritative service-side schema check; local tests cannot replace it.

## Preview And Approval

Use a privileged lab/deployment role for direct preview commands. An ordinary production operator should not have this permission, since IAM does not distinguish `Apply=false` from `Apply=true` at the document parameter level.

Example direct preview parameter map, stored in an environment-specific local JSON file, never committed with secrets:

```json
{
  "Action": ["Disable"],
  "Server": ["dc01.example.test"],
  "ManagedOU": ["OU=Managed,DC=example,DC=test"],
  "Identity": ["lab.user"],
  "Apply": ["false"],
  "ChangeTicket": ["CHG-1001"]
}
```

```powershell
aws ssm send-command --region eu-west-2 --document-name WinDomain-Users --document-version 1 --instance-ids i-0123456789abcdef0 --parameters file://local-parameters-preview.json --max-concurrency 1 --max-errors 0
```

For a production change, start the approval wrapper. Automation's outer Parameters values are lists of strings; the StringMap child input is a JSON-encoded map of **string** values, not a second SendCommand list-valued map:

```json
{
  "DocumentName": "WinDomain-ApprovedChange",
  "DocumentVersion": "1",
  "Parameters": {
    "InstanceId": ["i-0123456789abcdef0"],
    "DocumentName": ["WinDomain-Users"],
    "DocumentVersion": ["1"],
    "ChangeTicket": ["CHG-1001"],
    "CommandParameters": ["{\"Action\":\"Disable\",\"Server\":\"dc01.example.test\",\"ManagedOU\":\"OU=Managed,DC=example,DC=test\",\"Identity\":\"lab.user\",\"Apply\":\"true\",\"ChangeTicket\":\"CHG-1001\"}"]
  }
}
```

```powershell
aws ssm start-automation-execution --region eu-west-2 --cli-input-json file://local-parameters-approved.json
```

The approver must inspect the full execution input, including child map, ticket consistency, host identity/tags, exact version and prior preview. The generic wrapper does not automatically enforce matching outer/inner tickets or prevent a dishonest preview report; a future hardened deployment may use per-operation wrappers/Change Manager constraints. Parameters cannot be changed in place after approval. If inputs need changes, reject/cancel and start a fresh execution.

## Audit And Failure Handling

Configure encrypted CloudWatch/S3 command output, retention, access control and CloudTrail before production. Add a fixed approved CloudWatch log group to the wrapper's `aws:runCommand` `CloudWatchOutputConfig`, or centrally collect equivalent output. Do not leave artifact audit entirely on the node or rely on truncated console output. Preprovision the log group and grant the node logging permissions.

Enable applicable Windows security/AD change auditing and CA audit policy. Record requester, approver, Automation execution ID, child command ID, node, numeric version/hash, exact nonsecret parameters, ticket, before/after state and independent postchecks.

Changes are not transactions. A failed command may have already disabled an account, reset a password, moved an object, altered DNS, submitted a certificate or changed WSUS state. Inspect actual state before retrying; the wrapper deliberately uses one attempt. Cancellation/timeouts cannot reliably undo native tools, background WSUS work or CA requests. Run one operation per target at a time using external scheduling/change control.

## Sources

- [SSM schemas and ENV_VAR interpolation](https://docs.aws.amazon.com/systems-manager/latest/userguide/documents-schemas-features.html)
- [Command plugin reference](https://docs.aws.amazon.com/systems-manager/latest/userguide/ssm-plugins.html)
- [Approval action](https://docs.aws.amazon.com/systems-manager/latest/userguide/automation-action-approve.html)
- [Automation Run Command action](https://docs.aws.amazon.com/systems-manager/latest/userguide/automation-action-runcommand.html)