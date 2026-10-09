---
title: "PKI Operations"
status: "UNTESTED_REFERENCE_SPECIFICATION"
offline_verified: true
lab_testing_required: true
target_audience:
  - "Human Systems Administrators"
  - "Autonomous LLM / AI Orchestration Agents"
last_updated: "2026-10-08"
---

# PKI Operations

> [!WARNING]
> **UNTESTED IN LIVE PRODUCTION ENVIRONMENT — LAB QUALIFICATION REQUIRED**  
> The procedures, commands, and architectural patterns in this runbook have been verified offline against simulated fixtures and syntax parsers. They have **never been executed against a live enterprise Active Directory forest or production WSUS hierarchy**.  
> Every procedure must be rehearsed and verified in an isolated testbed lab (Gates G1–G3) before considering live staging or production execution.

## LLM Execution Instructions
When an Autonomous Agent or LLM is reading or executing steps from this runbook:
1. **Safety Gate:** Verify caller possesses CA Manager or dedicated Certificate Enrollment privileges and an active `ChangeTicket`.
2. **Key Security Invariant:** Private keys must never be exported from target nodes or CA servers.
3. **Template Guardrails:** Never alter template settings or issue certificates from unapproved templates.
4. **CA Signing Keys:** Prohibit automatic renewal or revocation of root or subordinate CA signing certificates.

This pack assumes Microsoft AD CS, not AWS Private CA. Confirm the CA hierarchy, template policy, enrollment identities, certificate consumers, CA backups, CRL/OCSP locations and HSM/private-key requirements before deployment.

## Permission And Identity Boundaries

Separate enrollment permission from CA certificate-manager/administrator permission. The CA administration node uses its machine identity under SSM LocalSystem; the enrolling node uses its own machine identity and local machine key store. Do not grant every instance CA administration rights.

`CAConfig` is an explicit `host\CA-name` string. `Template` is the short/internal name, not the display name. Caller-supplied CA/template values are not allowlists: CA ACLs, template enrollment permissions, certificate-manager restrictions and controlled document variants must enforce permitted operations. Harden templates against unintended subject/SAN supply and enrollment-agent/privileged authentication issuance.

`certutil` is an administrative diagnostic utility, not a stable production programming API guaranteed across releases. The pack uses COM request/admin interfaces for submission/issuance/revocation and certutil for selected diagnostic/CRL operations. Validate CLI/COM availability and behavior on the exact Windows Server build before release.

## CA Health

Run `Inspect` with the intended CAConfig. It checks request-interface reachability, CA information and templates. This is not full PKI health certification. Also monitor CertSvc, CA/database/log disk capacity, issuer expiry, template permissions, CA audit events, backup integrity, external AIA/CDP/OCSP availability and chain building from relying-party networks.

An offline root CA must stay offline except during its approved ceremony. Do not make it an always-managed SSM node for convenience.

## Template-Based Machine Enrollment

On the intended key-owning member server:

1. `Inspect` the machine personal store and record existing thumbprints/expiry/bindings.
2. Preview `Request` with the approved template short name.
3. Approve and apply. Native `Get-Certificate` uses domain enrollment policy and writes to `Cert:\LocalMachine\My`.
4. Validate installed subject/SAN, template/EKU, issuer, validity, chain and private-key availability to the actual service identity.
5. Bind the new certificate through the consuming application's separately reviewed workflow and test it from a client.

This flow does not accept arbitrary subject/SAN strings. Templates requiring supplied subject information need the reviewed CSR route or a separately constrained request-generation document. No user-personal-store enrollment or enrollment-on-behalf-of workflow is implemented.

Pending enrollment is not reported as successful issuance. Preserve the request ID/artifact and inspect CA status instead of blindly repeating a request. Template key-export policy still applies: the document never exports a key, but it cannot make an exportable template/key policy safe.

## Reviewed CSR Submission And Issuance

1. Generate a PEM PKCS10 CSR **on the final key-owning host** using the approved template/key/subject/SAN policy. Keep the private key there. Never place a PFX or private key in SSM inputs or source control.
2. Validate the CSR signature, identity, SANs, EKUs, key algorithm/size, requested template and intended consumer independently. A matching hash proves content identity, not entitlement or a safe CSR.
3. Stage only the public CSR on the CA administration node in the protected `C:\ProgramData\WinDomain\Requests` directory. Use a simple `.req` basename and record the SHA256 of its exact bytes.
4. Preview `Submit` with CAConfig, Template, RequestFile and RequestSha256. Approve that exact content hash and template; applied submission returns request ID/disposition. Issuance may be immediate or pending according to CA/template policy.
5. Use `InspectRequest` with the explicit request ID. Before `Issue`, the approver must inspect the CA record's requester, template, subject/SANs, hash/artifacts and intended recipient. A request ID alone is not proof of authorization.
6. `Issue` requires a pending disposition and uses the CA manager's permission. Record the issued request ID/serial/thumbprint. `Retrieve` saves the public certificate under Requests; it does not install a private key or bind an application.
7. Transfer the public certificate to the original host, verify provenance/content and accept it there using an approved native workflow, for example `certreq -accept -machine -q <issued-certificate.cer>`. Check for the matching private key and perform application binding separately.

Submit is not inherently idempotent. A timeout can occur after a request was created or issued. Consult the CA database/audit events before repeating it. Issued certificate retrieval can return a certificate whose operational trust/use still needs independent validation.

## Machine Certificate Renewal

Use `Renew` on the original host with the exact old machine thumbprint. It requires a private key, rejects detected CA certificates and expired certificates, and invokes the documented `certreq -enroll -machine -q -cert <thumbprint> Renew` flow. Expired leaf certificates require a fresh request.

The command checks for exactly one newly installed certificate with matching subject/issuer, later expiry and a private key. That check is deliberately conservative but not a complete proof of template/SAN/EKU/binding correctness; validate those independently. Do not run concurrent enrollments during this check.

Renewal does not update IIS/LDAPS/RDP/WSUS/service bindings, distribute certificates to load balancers, delete the old certificate or guarantee a new issuer chain works for clients. Record the old application binding and restore that binding if a new leaf certificate is unsuitable, provided the old certificate is still valid and not revoked.

## Revocation And CRL Publication

1. Establish the exact issuer and **serial number**, not the thumbprint, of the certificate to revoke. Confirm the incident/owner and relying services.
2. Preview `Revoke` with CAConfig, SerialNumber and an explicit appropriate RevocationReason. The default is key compromise (1); do not use it indiscriminately.
3. Approve/apply. Record the CA revocation audit entry and effective time. Revocation is not immediate session termination.
4. Approve/apply `PublishCRL`. Check base/delta CRL generation, NextUpdate, configured publication points and OCSP refresh.
5. From a relying-party network, verify that every advertised CDP/OCSP endpoint serves current signed information and that chain validation rejects the revoked certificate. SSM success is not evidence that external revocation distribution completed.

Ordinary revocation is not safely reversible. Do not expose a generic unrevoke operation. Certificate hold/removal or CA compromise recovery needs a separate PKI-owner-approved procedure; CA-compromise incidents must not be treated as a routine leaf-certificate toggle.

## CA Signing-Certificate Renewal And Disaster Recovery

CA signing-key/certificate renewal is deliberately **not** automated by the machine-renewal document. It can affect the entire hierarchy, trust distribution, CRL naming/publication, HSM backup and issuer overlap. Prepare a separate ceremony/runbook:

1. Inventory CA policy, certificate/key generations, HSM/export constraints, templates, AIA/CDP/OCSP, trust stores and dependent issuing CAs.
2. Verify encrypted recoverable CA database/log, certificate/private-key (or HSM), registry/configuration and publication backups using an isolated restore test.
3. Approve key reuse versus rotation, algorithm/validity, parent CA signing process, downtime, offline-root handling and rollback constraints.
4. Perform version-specific Microsoft/HSM-supported renewal, publish new chains and overlapping CRLs, and validate representative relying parties.
5. Preserve old issuer certificates/keys/CRLs for previously issued certificate validation for the required retention period.

Never run `certutil -renewCert`, key export or CA restore automatically as a generic WSUS/domain remediation. CA recovery and forest recovery require their own tested plans.

## Sources

- [certreq syntax, renewal and certificate acceptance](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1)
- [certutil administration, revocation and CRL reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certutil)