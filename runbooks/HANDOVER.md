# Operational Handover & Production Maintenance Manual

## 1. Handover Overview

This document serves as the operational handover manual for the WUU2-CLI AWS Systems Manager integration. It transitions ownership from the engineering implementation team to the long-term infrastructure operations and platform engineering teams.

---

## 2. Operating Roles & Responsibilities

| Role | Primary Responsibility | Primary Tools & Interfaces |
| --- | --- | --- |
| **Deployment Operator** | Plans patch cycles, selects approved member servers, executes deployment submissions. | `scripts/Invoke-WuuDeployment.ps1`, AWS SSM Automation Console |
| **Change Approver** | Audits frozen change plans, verifies maintenance windows, signals approval. | AWS SSM Automation (`aws:approve`), Change Ticket System |
| **Incident Owner** | Triages quarantine alerts, CBS servicing errors, and restart timeouts. | `scripts/Get-DeploymentStatus.ps1`, `runbooks/REBOOT-AND-PATCH-RECOVERY.md` |
| **Platform Maintainer** | Updates WSUS upstream policies, publishes new worker packages and document revisions. | `scripts/Build-WorkerPackage.ps1`, `scripts/Publish-Documents.ps1` |

### Alert Routing
- **Alert Topic:** `arn:aws:sns:us-east-1:123456789012:wuu-alerts-${Environment}`
- **Subscribers:** Infrastructure Operations On-Call, Systems Engineering Distribution List.
- **Trigger Sources:** EventBridge State Machine failure events, SSM Automation aborts, CloudWatch Postcheck metric alarms.

---

## 3. Repository Architecture & File Map

```text
aws-windows-domain-runbooks/
├── cloud/                        # Cloud coordinator & Lambda handlers (ESM)
│   ├── build-plan.mjs            # Synthesizes frozen change plans with SHA-256 digest
│   ├── cancel.mjs                # Graceful cancellation & window cutoff enforcement
│   ├── deployment.asl.json       # Step Functions 5-phase sequencing state machine
│   ├── dispatch.mjs              # Node lock acquisition & SSM SendCommand dispatch
│   ├── reconcile.mjs             # Invocation polling, dual-envelope parsing & quarantine
│   ├── report.mjs                # Audit report generator with strict fleet compliance
│   ├── state.mjs                 # DynamoDB distributed locking & fencing tokens
│   └── validate-plan.mjs         # Post-approval plan revalidation
├── documents/                    # Pinned SSM Documents (schemaVersion 2.2 / 0.3)
│   ├── WinDomain-*.yaml          # 11 hardened domain pack documents
│   ├── Wuu-Bootstrap.yaml        # Pinned node prerequisite qualification
│   ├── Wuu-Inventory.yaml        # EC2 instance-to-host identity mapping
│   ├── Wuu-Scan.yaml             # Noninteractive WSUS scan
│   ├── Wuu-Download.yaml         # Noninteractive WSUS patch download
│   ├── Wuu-Install.yaml          # Noninteractive WSUS patch install
│   ├── Wuu-ApprovedDeployment    # Approval wrapper for Step Functions fleet execution
│   ├── Wuu-Reboot.yaml           # Controlled SSM exit 3010 reboot with 1-reboot max
│   └── Wuu-Verify.yaml           # Postcheck health, boot ID & service verification
├── infra/                        # CloudFormation infrastructure templates
│   ├── iam.yaml                  # Scoped least-privilege IAM roles
│   ├── network.yaml              # PrivateLink endpoints & S3 Gateway routing
│   ├── observability.yaml        # SNS alert topics & EventBridge failure rules
│   ├── orchestration.yaml        # Step Functions state machine & execution role
│   ├── secrets.yaml              # KMS-encrypted SSM SecureString secrets
│   ├── state.yaml                # DynamoDB operations & mutual exclusion table
│   └── storage.yaml              # S3 versioned buckets for packages & results
├── workers/                      # Noninteractive PowerShell 5.1 node modules
│   ├── Invoke-WuuWorker.ps1      # Central worker CLI entrypoint
│   ├── Wuu.Artifacts.psm1        # Hash verification & safe package extraction
│   ├── Wuu.LocalState.psm1       # Global\WUU_Servicing_Lock mutex & atomic journals
│   ├── Wuu.LocalUpdate.psm1      # Decoupled WUA COM search/download/install
│   ├── Wuu.Postcheck.psm1        # Post-reboot boot ID & service health checks
│   ├── Wuu.Reboot.psm1           # Pending reboot detection & checkpointing
│   ├── Wuu.Result.psm1           # Structured exit codes (0/3/4/5/6/7) & JSON envelopes
│   └── Wuu.WsusPolicy.psm1       # Strict ssManagedServer enforcement
├── scripts/                      # Client automation, deployment & rollback tools
│   ├── Deploy-Environment.ps1    # CloudFormation change set runner
│   ├── Export-DeploymentReport   # Exports correlated deployment audit report
│   ├── Get-DeploymentStatus.ps1  # Step Functions / SSM rollout query tool
│   ├── Invoke-LabQualification   # Automated end-to-end qualification test suite
│   ├── Invoke-WuuDeployment.ps1  # Submits frozen plan to Step Functions
│   └── Rollback-Release.ps1      # Restores prior document versions & packages
└── runbooks/                     # Operational runbooks & standard operating procedures
```

---

## 4. Known Limitations & Deferred Scope

The following items are deliberately deferred from this integration baseline:
1. **Tier 0 Domain Controllers:** Domain Controllers are strictly excluded from automated fleet patching and reboots (`eligibleForFleetPatching: false`). They must continue to be updated manually under direct administrator supervision.
2. **Active Directory Certificate Services (AD CS):** Automated reboot of Enterprise Root/Subordinate CAs is prohibited to prevent CRL publication gaps.
3. **Multi-Node Failover Clusters:** Clustered roles (SQL Server AlwaysOn, Hyper-V, Scale-Out File Server) require cluster-aware updating (CAU) and are excluded from concurrent multi-node execution.
4. **Multi-Region Orchestration:** The current baseline targets single-region AWS VPC architectures. Cross-region fleet synchronization is deferred to future releases.

---

## 5. Support & Emergency Handover

For critical escalation, consult the relevant operational runbooks:
- **Reboot hangs or boot loops:** `runbooks/REBOOT-AND-PATCH-RECOVERY.md`
- **Network or endpoint loss:** `runbooks/NETWORK.md`
- **State desynchronization or locks:** `runbooks/RECOVERY.md`
- **WSUS synchronization failures:** `runbooks/WSUS.md` and `runbooks/WSUS-INTEGRATION.md`
- **Emergency rollback:** `runbooks/RELEASE.md`

