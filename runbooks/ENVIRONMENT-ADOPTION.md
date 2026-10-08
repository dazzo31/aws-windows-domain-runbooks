# Environment Adoption Guide (G0 Milestone Gate)

Date: 2026-10-07  
Status: G0 Pre-requisite Specification  
Scope: Environment parameterization, support matrix, placeholder refusal rules, and adoption signoff.

---

## 1. Overview and Purpose

Before any AWS infrastructure, Systems Manager documents, or worker packages are deployed to a target environment, the environment's operational parameters must be explicitly reviewed and accepted. This adoption process establishes the **G0 Adoption Gate**.

The adoption process ensures:
1. **WSUS is preserved as the sole update authority** — preventing accidental reliance on AWS Patch Baselines or direct Microsoft Update fallback.
2. **Upstream WUU2-CLI remains untouched** — establishing the **Decoupled Consumer Model** where `WUU2-CLI` serves as an independent upstream reference without modifying its working tree.
3. **Placeholder values are strictly refused** — preventing starter/sample account IDs (`123456789012`), domain names (`example.local`), or mock ARNs from being deployed to AWS.
4. **Role and scope segregation is enforced** — excluding Domain Controllers, CAs, and clustered nodes from generic automated fleet patching.

---

## 2. Upstream Lineage & Decoupled Consumer Model

This repository consumes worker logic from [`WUU2-CLI`](https://github.com/dazzo31/WUU2-CLI):

* **Pinned Release Candidate:** `v1.5.0-rc.4-cli`
* **Pinned Commit:** `e81b620905d549783d7e17498a0b3cbbcf5f4095`
* **Licensing:** MIT License (Boe Prox / Tyler Siegrist / HanSolo71 / dazzo31). All attribution notices are retained.
* **Zero-Touch Policy:** The `WUU2-CLI` repository must **never** be dirtied or modified for AWS integration. Local worker logic (`Wuu.LocalUpdate.psm1`) is packaged into an immutable S3 ZIP artifact by `scripts/Build-WorkerPackage.ps1` and delivered to nodes via Systems Manager. All cloud deployment client tools live exclusively in this repository.

---

## 3. Support Matrix

Target managed instances must comply with the following runtime matrix:

| Component | Requirement | Notes |
|---|---|---|
| **Operating Systems** | Windows Server 2022 (Build 20348)<br>Windows Server 2019 (Build 17763)<br>Windows Server 2025 (Build 26100) | Datacenter or Standard editions. Desktop experience or Server Core. Windows Server 2016 and Windows Clients are unsupported. |
| **PowerShell Host** | Windows PowerShell 5.1 | Must execute with `-STA -NonInteractive -ExecutionPolicy Bypass`. PowerShell 7+ is not supported for WUA COM interop. |
| **SSM Agent** | `>= 3.3.2746.0` | Required for native Windows exit code 3010 reboot-and-resume support and channel reliability. |
| **Cloud Runtime** | Node.js 20.x (LTS) | Used for Step Functions dispatch, reconciliation, and validation Lambda handlers. AWS SDK v3 pinned. |

---

## 4. Scope and Node Class Segregation

Instances in the environment must be tagged and partitioned into distinct node classes:

### 4.1 Member Servers (`memberServer`) — ELIGIBLE
* **Definition:** General domain member servers hosting non-clustered, stateless, or redundant application tiers.
* **Fleet Patching:** **Eligible** across 5 sequential rollout phases with canary protection (Phase 1 = canary).
* **Direct Reboot:** **Eligible** (up to 1 controlled reboot per deployment, requiring separate approval).

### 4.2 Domain Controllers (`domainController`) — EXCLUDED
* **Definition:** Tier 0 Active Directory Domain Controllers holding FSMO roles or global catalog databases.
* **Fleet Patching:** **Strictly Excluded**. AD replication health, SYSVOL replication, and directory service quorum must not be subjected to generic fleet patching.
* **Direct Reboot:** **Strictly Excluded**.

### 4.3 Active Directory Certificate Services (`certificateAuthority`) — EXCLUDED
* **Definition:** Enterprise Root and Subordinate Issuing Certificate Authorities.
* **Fleet Patching:** **Strictly Excluded**. CA signing key integrity, CRL publishing, and OCSP responder availability require dedicated maintenance procedures.
* **Direct Reboot:** **Strictly Excluded**.

### 4.4 Failover Cluster Nodes (`clusterNode`) — EXCLUDED
* **Definition:** Windows Server Failover Clustering (WSFC), SQL Server AlwaysOn, or Exchange DAG nodes.
* **Fleet Patching:** **Strictly Excluded**. Requires pre-drain, role failover, and post-resume cluster health ceremonies.

---

## 5. WSUS Authority & Network Connectivity Prerequisites

Managed nodes must have verified network access to internal and AWS control planes without opening inbound administration ports:

1. **WSUS Port & TLS:**
   * Nodes must connect to WSUS over HTTPS on port `8531`.
   * The enterprise root CA certificate must be pre-installed in `Cert:\LocalMachine\Root`.
   * WSUS content hosting must be set to `locally_stored` in lab environments to guarantee updates originate from the WSUS server rather than external internet endpoints.
2. **PrivateLink VPC Endpoints:**
   * The VPC must host interface endpoints for `ssm`, `ssmmessages`, and `logs`.
   * An S3 Gateway endpoint must be routed to private subnets to allow artifact download and result uploads without internet egress.
3. **AD DNS Forwarding:**
   * Active Directory DNS servers must forward AWS PrivateLink domains (`*.ssm.<region>.amazonaws.com`, `*.s3.<region>.amazonaws.com`) to the VPC resolver (`AmazonProvidedDNS` at VPC base + 2) so private IP addresses resolve correctly on domain members.
4. **No Inbound Management Ports Required:**
   * Inbound DCOM (`135`), SMB (`445`), and WinRM (`5985/5986`) must **not** be opened for SSM patch operations. The SSM Agent connects outbound to AWS endpoints over port `443`.

---

## 6. Placeholder Refusal Rules

The configuration file `config/environments/lab.example.yaml` contains sample placeholder values. When preparing an active environment configuration (`lab.yaml`, `prod.yaml`), the adoption validator (`scripts/Test-Environment.ps1`) enforces that:

1. **AWS Account ID:** Must be a valid 12-digit number and must **not** match `123456789012`.
2. **Domain Names:** Must not match `example.local`, `example.test`, or `example.com`.
3. **Subnet / VPC IDs:** Must match active AWS resource ID patterns (`vpc-[0-9a-f]{17}`, `subnet-[0-9a-f]{17}`) and not contain mock strings.
4. **Certificate Thumbprints:** Must match a valid 40-character hexadecimal SHA-1 thumbprint and not match the dummy string `0123456789ABCDEF0123456789ABCDEF01234567`.
5. **IAM Role ARNs:** Must be fully qualified ARNs belonging to the target account ID.

Any deployment attempt against a configuration file containing placeholder values will be aborted immediately with an exit code of `1`.

---

## 7. Step-by-Step Environment Adoption Workflow

To onboard a new environment:

### Step 1: Copy the Template
```powershell
Copy-Item "config/environments/lab.example.yaml" "config/environments/lab.yaml"
```

### Step 2: Populate Verified Environment Values
Open `config/environments/lab.yaml` and update:
* Target AWS `accountId`, `region`, and `vpcId`.
* Private subnet and VPC endpoint IDs.
* Contact emails and cost center.
* Real WSUS server URL (`https://<real-wsus-fqdn>:8531`) and root CA thumbprint.
* Target IAM role ARNs (Operator, Approver, Automation Execution).

### Step 3: Run the Environment Validator
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts/Test-Environment.ps1" -Environment lab
```
Verify that all schema checks and placeholder-refusal assertions report **PASS**.

### Step 4: G0 Signoff
Once validation passes, record signoff in the environment adoption record. Infrastructure provisioning (Plan 1.2: `infra/network.yaml`, `Wuu-Bootstrap.yaml`) is authorized to proceed only after G0 signoff.

