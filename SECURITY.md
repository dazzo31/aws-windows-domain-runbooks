# Security Policy

`aws-windows-domain-runbooks` provides AWS Systems Manager (SSM) automation documents, CloudFormation infrastructure templates, and operational runbooks for managing Active Directory, WSUS, PKI, and Windows Server infrastructure on EC2.

Security, least privilege, and administrative boundary protection are foundational invariants of this repository.

## Operational & Lab Safety Notice

> [!WARNING]
> All code, automation documents, and runbooks in this repository represent **offline-verified reference specifications**. They must be validated in an isolated lab testbed before staging or production deployment.

## Reporting a Vulnerability

**Please do not open a public issue, discussion, or pull request for a security vulnerability.**

Report vulnerabilities privately via GitHub's **Private Vulnerability Reporting**:
1. Go to the repository's **Security** tab → **Advisories** → **Report a vulnerability**
   (direct link: [Report a vulnerability](https://github.com/dazzo31/aws-windows-domain-runbooks/security/advisories/new)).
2. Provide a clear description of the vulnerability, including:
   - Affected document, CloudFormation template, or runbook procedure.
   - Attack vector, required privileges, and security implications (e.g., privilege escalation, boundary bypass, credential disclosure).
   - Minimal proof of concept or reproduction steps.

**Never include live AWS credentials, actual account IDs, Active Directory password hashes, private keys, or internal network topology in any report.**

