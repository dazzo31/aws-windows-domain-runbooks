---
title: "AD Operations"
status: "UNTESTED_REFERENCE_SPECIFICATION"
offline_verified: true
lab_testing_required: true
target_audience:
  - "Human Systems Administrators"
  - "Autonomous LLM / AI Orchestration Agents"
last_updated: "2026-10-08"
---

# AD Operations

> [!WARNING]
> **UNTESTED IN LIVE PRODUCTION ENVIRONMENT — LAB QUALIFICATION REQUIRED**  
> The procedures, commands, and architectural patterns in this runbook have been verified offline against simulated fixtures and syntax parsers. They have **never been executed against a live enterprise Active Directory forest or production WSUS hierarchy**.  
> Every procedure must be rehearsed and verified in an isolated testbed lab (Gates G1–G3) before considering live staging or production execution.

## LLM Execution Instructions
When an Autonomous Agent or LLM is reading or executing steps from this runbook:
1. **Safety Gate:** Verify caller possesses delegated management permissions and an active `ChangeTicket`.
2. **Preview Mode:** Always execute inspection/diagnostic steps (`Apply=false`) before any mutation.
3. **Target Selection:** Always target the delegated management member server; never target Tier 0 Domain Controllers directly for ad-hoc user/group edits.
4. **Collision Avoidance:** Enforce exact `sAMAccountName` and verify no existing out-of-scope identity collisions exist.

## Before Every Change

Use the delegated management member server, not an arbitrary EC2 node or DC. Choose one explicit writable DC in `Server` and the intended `ManagedOU`. Confirm domain/OU identity from a read-only inspection, healthy replication and a verified system-state backup schedule. OU input checks do not replace AD ACL delegation.

All non-inspection actions need preview, change ticket and the approval workflow before `Apply=true`. Use exact sAMAccountName, not a wildcard. The user document searches for collisions across the selected domain and refuses existing out-of-scope identities.

## Users

| Action | Additional inputs | Expected result |
| --- | --- | --- |
| Inspect | Identity | Exact user state, DN, enabled/locked/password timestamp |
| Create | DisplayName, UserPrincipalName, PasswordParameter | New enabled user in ManagedOU, password change required at next logon |
| Disable | Identity | Account disabled on selected DC |
| Unlock | Identity | Lockout cleared on selected DC |
| ResetPassword | PasswordParameter | Password reset and change-at-next-logon set |

An approved worker's node role retrieves `PasswordParameter` directly as SecureString. Provision the parameter through a trusted secret-entry workflow outside command history, restrict KMS/parameter permissions, and remove or rotate it according to policy after use. Never print the value or put it in SSM input files. Password strength is enforced by domain/fine-grained password policy, not by the document.

Create is not an idempotent reconciliation command: an existing account produces an error rather than silently taking ownership. If a create/reset partially fails, inspect actual enabled state, `pwdLastSet`, password-policy events and replication before any retry.

Disabling an account does not immediately revoke every active Kerberos ticket, application session or cached logon. Include application/session containment in the offboarding incident plan. Unlock alone will not fix a scheduled task/service/device that repeatedly submits old credentials. Investigate lockout origin and fix the caller.

Protected accounts with `adminCount=1` are excluded. This flag can be stale and does not identify every privileged or sensitive identity; use dedicated OUs and delegated ACLs as the enforcement boundary. Do not use this pack for Domain Admins, break-glass accounts, service accounts or automation-worker identities.

Postcheck on a second DC after replication and, where appropriate, test the user's actual sign-in workflow. Password resets cannot be rolled back to an unknown old password. Resolve mistakes with an approved fresh reset, not secret disclosure. A mistaken disable can be reversed by an authorized administrator after review; there is deliberately no general enable-account operation in this first pack.

## Groups

`Create` produces a security group using `GroupScope` (Global by default). `AddMember`/`RemoveMember` accept one exact user/computer DN in `Member`, within the same ManagedOU subtree. The group must also be in scope.

Inspect captures direct membership and parent-group membership. Protected groups, any group already nested into another group, protected principals and adding groups as members are rejected. This conservative restriction avoids a generic path to nested privilege escalation; it is not a substitute for ACLs or a privileged-group inventory.

Membership changes are idempotent for an already-present/absent direct member. Capture before membership, verify the direct membership afterward and independently verify effective access after token refresh. To reverse, apply the inverse membership action through a fresh approval. Adding a member may affect application privileges even when the group has no privileged AD label.

## Computer Accounts

`Identity` is the computer name without a trailing dollar sign. `Create` prestages an enabled account in ManagedOU; it does not join the EC2 host. `Disable` blocks future machine authentication but can affect running services. `Move` requires `TargetOU` within the ManagedOU subtree and may change the machine's effective GPOs.

Domain controllers and protected computer accounts are excluded. This document does not reset AD machine passwords, repair a secure channel, delete stale computers or perform bulk cleanup. Resetting only the AD account password can break a healthy machine trust; use a separately designed host-coordinated repair.

Capture original DN/enabled state and OU-linked policy before a move/disable. Verify against the selected DC, after replication and from the actual machine. Reverse a move through a new approved move when the original OU remains in scope. Re-enabling/prestage cleanup remains an authorized manual action in this pack.

Modern domain-join account-reuse hardening and account owner restrictions must be tested independently; prestaging alone does not guarantee a join will be permitted.

## Domain Health And Remediation Routing

Run `WinDomain-Health` on each DNS-enabled DC, with `Server` naming that same DC. Local service/share/time checks and the explicit-DC replication checks must describe the same machine. It is read-only and fails the command if its detected checks fail.

| Finding | First response | Do not do automatically |
| --- | --- | --- |
| Replication failures | Inspect partner/error, DNS, network, site topology, clock skew and recent changes | Force forest-wide sync or seize FSMO |
| Missing SYSVOL/NETLOGON | Inspect DFSR events, replication state, disk and backlog; preserve evidence | Authoritative/non-authoritative DFSR restore |
| Advertising or LDAP discovery failure | Check DNS SRV data and DC services from another host | Delete/recreate infrastructure DNS records |
| Time/source issues | Validate PDC emulator upstream source and domain time hierarchy | Force an arbitrary public time source on every DC |
| Service stopped/disk full | Identify underlying cause and capacity before targeted repair | Restart every DC or delete AD logs |

This check is not exhaustive: separately monitor secure-channel health, DNS test results, event logs, backups, disk latency, replication convergence and authentication from member hosts. Major DC/forest recovery requires a dedicated tested recovery plan and trained operators, not a generic repair button.