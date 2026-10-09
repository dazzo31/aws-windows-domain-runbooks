---
title: "Lab Acceptance And Release Gates"
status: "UNTESTED_REFERENCE_SPECIFICATION"
offline_verified: true
lab_testing_required: true
target_audience:
  - "Human Systems Administrators"
  - "Autonomous LLM / AI Orchestration Agents"
last_updated: "2026-10-08"
---

# Lab Acceptance And Release Gates

> [!WARNING]
> **UNTESTED IN LIVE PRODUCTION ENVIRONMENT — LAB QUALIFICATION REQUIRED**  
> The procedures, commands, and architectural patterns in this runbook have been verified offline against simulated fixtures and syntax parsers. They have **never been executed against a live enterprise Active Directory forest or production WSUS hierarchy**.  
> Every procedure must be rehearsed and verified in an isolated testbed lab (Gates G1–G3) before considering live staging or production execution.

## LLM Execution Instructions
When an Autonomous Agent or LLM is reading or executing steps from this runbook:
1. **Safety Gate:** Verify caller executes in an isolated non-production lab environment (Gate G1).
2. **Sequential Progression:** Never jump to staging or production qualification before all offline and lab gates pass cleanly.
3. **Honest Reporting:** Record any unavailable testbeds as `SKIP` or `BLOCKED`; never emit a false `PASS`.
4. **Disaster Recovery Pre-requisite:** Verify system state backup before initiating any live test on Domain Controllers.

These gates are for the future project. None have been executed against AWS, AD, WSUS or AD CS during pack creation. Use an isolated test account/domain/CA with disposable objects and verified backups; never begin by testing against production Tier 0.

## Current Evidence

- Eleven YAML documents parse with unique keys and stay within the local 64 KiB size check.
- Ten embedded scripts parse under Windows PowerShell 5.1.
- Parameter defaults, ENV_VAR references, Windows preconditions and approval-step shape pass local structural checks.
- Ten missing-environment guards and two mocked user safety checks pass locally.
- No real AD/WSUS/CA operation, AWS upload, IAM change or managed-node execution has been performed.

Offline mocks are intentionally narrow. They do not emulate AD filter parsing, replication, WSUS API behavior, COM methods, certreq/CLI execution or AWS Automation parameter conversion. Do not present these results as operational certification.

## Environment Qualification

Record exact Windows/PowerShell/SSM Agent/module versions, functional levels, AWS region/account, node identities, delegated ACLs, WSUS DB engine/version/TLS configuration and CA/template policy. Re-run qualification when any supported OS/service/toolchain version changes.

Require SSM service-side create/update acceptance for every YAML file and retain resulting versions/content hashes. Verify numeric DocumentVersion pinning and StringMap parameter forwarding in the approval wrapper with a harmless child preview before any real mutation. Denial/timeouts must not reach the child command.

## Authorization Tests

1. Ordinary operator cannot directly SendCommand, edit a document, select another Automation definition, alter protected target tags or assume the approver/publisher role.
2. Automation role cannot invoke arbitrary-script documents or target unapproved nodes. Test attempts outside permitted tags/resources and alternate document names.
3. Node machine account can access only delegated AD OU/group/DNS/GPO scope and permitted CA templates/administration; test denied out-of-scope operations even when a caller supplies a different ManagedOU/Zone/CAConfig.
4. Only the password worker can decrypt the narrow SecureString path. A String parameter, a different parameter path and a different KMS key must be denied.
5. Unsupported/old agent input handling fails closed. Inputs with quotes, dollar signs, newlines, invalid enums, wildcards or traversal paths must be rejected or treated as data, never executed.
6. Audit logs contain ticket, execution/command/version/target and before/after evidence, but no passwords, decrypted secrets or private keys.

## Behavior Matrix

| Area | Positive cases | Negative/partial-failure cases | Closure evidence |
| --- | --- | --- | --- |
| Users | Create, disable, unlock, reset in disposable OU | Existing identity, wrong OU, protected account, weak password, missing ticket, reset second-step failure | Selected/second-DC state, sign-in policy, AD audit events |
| Groups | Create, add/remove user and computer | Protected/nested group, group-as-member, out-of-scope DN, duplicate/absent membership | Direct membership and effective access after token refresh |
| Computers | Prestage, disable, move within subtree | DC, protected account, outside target OU, account-reuse join restriction | AD state, host auth, effective GPO |
| Domain health | Each intended DC role healthy | Replication/service/share/time failure and DNS discovery failure | Non-success command plus actionable evidence; no automatic writes |
| DNS | A/CNAME create/update/remove | Multiple records, CNAME conflict, reserved name, zone/ACL denial | Local/remote resolution, replication, prior metadata artifact |
| GPO | Report, backup, OU link/unlink | Default-policy change, existing link, wrong OU/GPO, denied link permission | Native backup, link snapshot/order, effective canary policy |
| WSUS server | Configured HTTP/HTTPS API, restart, reset, sync, each chosen cleanup | Wrong TLS/port, SUSDB down, active sync, missing backup acknowledgement, timeout | Stable pool/API, sync/download outcome, canary client |
| WSUS client | Policy/report, refresh, scan, preserved-cache reset | DC reset, pending reboot, active servicing, cache locked, service restart failure | Policy/scan events, WSUS report, cache artifact, restored service state |
| AD CS | CSR submit (issued/pending), inspect, issue, retrieve, revoke, CRL | Hash mismatch, bad CSR, forbidden template, wrong CA/request/serial, unavailable COM, denied manager rights | CA audit/request state, leaf/chain, live CDP/OCSP result |
| Machine certs | Approved template request, valid-leaf renewal | Missing key, expired/CA certificate, pending issuance, ambiguous new leaf | Subject/SAN/template/EKU, key access, chain and application binding |
| Approval | Authorized approval runs exact pinned version once | Rejection, timeout, altered inputs, wrong principal/node/version | Control-plane audit and exact child command lineage |

For every write action, verify `Apply=false` performs no intended mutation. Include privilege escalation and alternate-parameter negative tests: code-side guardrails alone are not the policy boundary.

## Recovery And Release

Exercise mistaken user disable/group membership/computer move, DNS prior-value restoration, GPO link restoration, WSUS cache restoration/SUSDB recovery and application binding rollback. Document operations that cannot be reversed, particularly unknown-old-password resets, cleanup deletions and certificate revocation.

Confirm serialized execution, failure/timeout behavior, encrypted logs/artifacts, retained backups, alerting and approval separation. Release only after the project owner signs the environment-specific test evidence and required recovery drills. Start production with read-only diagnostics and small canaries, then enable individually approved mutations.