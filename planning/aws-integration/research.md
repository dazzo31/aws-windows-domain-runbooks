# AWS Integration Decisions

Date: 2026-10-06. Scope: implementation decisions for the future project. No live AWS, WSUS, AD or certificate tests were performed. Environment-specific settings are adoption inputs, not guessed values.

## D1: Keep WSUS As Authority

Decision: explicitly use WUA's managed-server search and qualify the expected WSUS policy/endpoint before every update action. AWS Systems Manager supplies orchestration/transport only. AWS Patch Manager and Microsoft Update scan fallback are excluded.

Rationale: the user explicitly requires WUU to work alongside WSUS. The existing local WUU scripts use default searcher selection, which is insufficient evidence for an AWS worker's WSUS-only contract. Modern scan-source/WUfB/MDM interactions need exact-OS live validation.

Alternative rejected: replace WUU/WSUS policy with AWS patch baselines. This violates the requested source/approval model.

At G0 also distinguish scan/approval authority from payload download origins: a WSUS server configured not to store update files locally can still authorise clients whose content comes from external URLs. Choose and document the permitted content-hosting policy; default the lab to locally stored WSUS content and fail/report prohibited direct-download behavior. Never claim registry/source-selection checks prove the origin of every downloaded byte.

## D2: Decoupled Consumer Model (Zero Changes To WUU2-CLI, No Fork)

Decision: adopt a **decoupled consumer model**. Keep `WUU2-CLI` 100% untouched as an independent, zero-dependency on-premises tool. Build the local worker package (`workers/Wuu.LocalUpdate.psm1`) and cloud deployment client (`scripts/Invoke-WuuDeployment.ps1`) entirely within `aws-windows-domain-runbooks`. Do not dirty `WUU2-CLI` with cloud SDKs, SSM adapters or AWS dependencies, and do not fork `WUU2-CLI`.

Compatibility constraint: `WUU2-CLI` remains completely clean and independent at master. It requires zero cloud code, zero AWS dependencies and zero modified release gates. `aws-windows-domain-runbooks` consumes `WUU2-CLI`'s local WUA worker logic as an attributed upstream dependency, packaged into an immutable S3 artifact with full MIT/NOTICE preservation.

Rationale: injecting AWS SDKs, Step Functions handles and SSM adapters into `WUU2-CLI` contaminates a pristine, 187-check release-gated tool and complicates offline/air-gapped operations. A fork would create permanent dual-maintenance debt (backporting WUA/CBS servicing bugfixes). Decoupling allows both repositories to maintain clean single responsibilities.

Source findings: WUU.ps1 startup catch can Read-Host; the old download worker exits with the downloaded count and can report success with unsuccessful individual downloads; the install worker needs explicit partial-result treatment. These are integration requirements, not claims that wrapping the original CLI is safe.

Alternative rejected: execute the complete WUU menu/CLI or unchanged Download-Patches.ps1 inside a generic AWS-RunPowerShellScript mutation. It does not establish correct headless/result/source behavior. Forking WUU2-CLI is also rejected due to ongoing maintenance debt.

## D3: Durable Fleet Execution

Decision: SSM Automation handles fixed-principal approval; Step Functions Standard with small Node.js Lambda helpers manages phased dispatch, cutoff, reconciliation and closure. Use EventBridge SSM command invocation status change notifications with `Task.waitForTaskToken` callbacks to eliminate high Step Functions polling state transition costs and API throttling, retaining a low-frequency heartbeat timer as a safeguard. Operators use `scripts/Invoke-WuuDeployment.ps1` and `scripts/Get-DeploymentStatus.ps1` to track execution.

Rationale: five phases, long installs, restarts and disconnected consoles need durable cloud state. SSM Run Command is node execution, not proof that a complete deployment/application postcheck succeeded. EventBridge-driven task tokens minimize cloud state-transition costs while providing instant progression upon node completion.

Alternative: an Automation-only single-node proof of concept is valid at G2. Do not ship a client-owned polling loop as the full fleet coordinator. Do not introduce a web API/UI or Express state machine without a separately demonstrated requirement.

## D4: Frozen Approval Manifest

Decision: approve an exact S3 VersionId/digest manifest containing targets, update GUIDs/revisions or administrative action, parameters, worker/document versions, ticket, window and reboot policy. Server-side validation precedes approval and dispatch.

Rationale: the starter generic wrapper forwards a caller-supplied StringMap and does not automatically ensure outer/inner ticket consistency or freeze all scope. Approval must not permit changing target tags, packages or update selection behind an unchanged ticket.

Alternative rejected: trust Apply=true, a caller username, arbitrary approver/role input or an S3 key without immutable version binding. IAM/Windows ACLs remain the true authorisation boundaries even with a manifest.

Requester attribution must use trusted Automation execution metadata/CloudTrail. Calling STS GetCallerIdentity from a Lambda returns the Lambda role, not the initiating operator. Caller-provided display identities are informational only.

## D5: State And Admission

Decision: DynamoDB conditional intent/ownership records plus a machine-local named mutex (`Global\WUU_Servicing_Lock`) and journal; detect native Windows servicing locks (`TrustedInstaller`, `tiworker.exe`, `usoclient.exe`) and handle `0x8024001E` (`WU_E_SERVICE_STOP`) backoff before dispatch.

Rationale: cloud locks cannot stop a manual/DCOM Windows installer or native background update orchestrator, and a new lease/fence token cannot terminate an old native installer. TTL cleanup and lease expiry are not permission to rerun a mutation. Windows servicing does not provide a generic exactly-once transaction.

Alternative rejected: automatically retry all nonzero SSM/WUU results, free locks solely by elapsed time, or abort servicing when a console closes.

## D6: Controlled SSM Reboot

Decision: a separately authorised direct SSM Command uses exit 3010 with durable boot checkpoints; it is restart-safe and initially limited to one reboot of a qualified member server. Install never automatically reboots. On reboot timeout, automatically trigger `ec2:GetConsoleOutput` and serial console diagnostics to detect OS boot hangs before raising alerts.

Rationale: AWS documents that SSM restarts the script after the reboot and does not support this reboot behavior through an aws:runDocument wrapper. A plain Restart-Computer call or an unjournalled exit 3010 cannot prove lifecycle completion and risks duplicate reboot behavior. An automated console screenshot/output capture diagnoses Windows update boot loops without manual intervention.

Alternative rejected: assume RebootRequired means reboot happened, treat EC2 running/SSM online as application readiness, or include DC/CA/cluster nodes in generic reboot phases.

## D7: Infrastructure And Release Ownership

Decision: use CloudFormation YAML with explicit environment adoption, versioned packages/documents, GitHub OIDC for separately approved publishing and per-service IAM/Windows roles. Consume existing VPC/domain/WSUS resources; do not automatically provision or replace the domain/CA.

Rationale: this aligns with the YAML document pack and avoids new Terraform/CDK toolchains without a stated need. Region, account, supported OS versions, network topology, WSUS storage/TLS, service ACLs and retention/budget must be signed off at G0.

Alternatives: an existing organisation-required IaC system can replace CloudFormation at adoption through an explicit plan amendment; this is not permission to generate conflicting infrastructure in parallel.

## D8: Honest Verification

Decision: preserve existing offline validators and WUU release commands; add module-level checks during implementation and require real AWS/Windows/WSUS/AD CS qualification before production. No mock/emulator can certify the live authorisation/source/reboot boundary.

Rationale: this session establishes planning traceability and runs the existing offline checks only. All live integration, delegation, service-side document acceptance, OIDC, cancellation and recovery evidence is future work.

## Adoption Inputs

Required before provisioning: account/region and AWS partition, VPC/subnets/DNS routing, supported Windows versions, named lab/WSUS/domain/CA nodes, instance/tag ownership, IAM/AD approver separation, WSUS URL/TLS and content hosting, permitted OU/DNS/GPO/template scopes, update/EULA selection policy, maintenance budgets/postchecks, log/artifact retention and cost owner.

These values are intentionally not filled from this computer or the sample document ARNs. Missing values block G0/deployment; they do not justify using a sample account or modifying current infrastructure.

## References

- https://docs.aws.amazon.com/systems-manager/latest/userguide/send-commands-reboot.html
- https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html
- https://docs.aws.amazon.com/systems-manager/latest/userguide/documents-schemas-features.html
- https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-put_serverselection
- https://github.com/dazzo31/WUU2-CLI