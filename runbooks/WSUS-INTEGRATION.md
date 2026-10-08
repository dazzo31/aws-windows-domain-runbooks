# WSUS Integration And Authority Qualification Runbook

Date: 2026-10-07  
Status: G1/G2 Operational Runbook  
Scope: Verification of WSUS as sole update authority, policy drift qualification, unapproved update prevention, and client/server evidence collection.

---

## 1. Overview and Core Invariant

The WUU2-CLI AWS integration strictly adheres to [REQ-001](../planning/aws-integration/plan.md#L29):
> **WSUS IS THE SOLE UPDATE AUTHORITY:**  
> Windows Update Agent (WUA) on managed nodes must communicate exclusively with the dedicated internal WSUS server over HTTPS on port 8531. AWS Patch Manager, default Patch Baselines, and automatic fallback to Microsoft Update are strictly prohibited.

Merely possessing a registry key (`UseWUServer = 1`) is insufficient proof of authority. This runbook establishes qualification procedures that produce empirical evidence of managed-source behavior.

---

## 2. Qualification Scenarios

### Scenario 1: Actual-Source Verification (Zero Public Egress)
* **Objective:** Prove that WUA queries originate from the node and terminate exclusively at the internal WSUS endpoint (`https://<wsus-fqdn>:8531`).
* **Verification Procedure:**
  1. Inspect client-side connection during scan:
     ```powershell
     Test-NetConnection -ComputerName wsus.example.local -Port 8531
     ```
  2. Inspect WSUS IIS logs (`C:\inetpub\logs\LogFiles\W3SVC*`) on the WSUS server for `POST /ClientWebService/client.asmx` from the node's private IP.
  3. Verify VPC Flow Logs show zero outbound packets from the node's private IP to public IP addresses on port 80/443.

### Scenario 2: Unapproved Update Rejection
* **Objective:** Prove that unapproved updates on WSUS or Microsoft Update cannot be discovered or installed by managed nodes.
* **Verification Procedure:**
  1. On the WSUS server, leave a specific KB unapproved.
  2. Dispatch [`documents/Wuu-Scan.yaml`](../documents/Wuu-Scan.yaml) to the managed node.
  3. Confirm that the unapproved KB does not appear in the scan results.
  4. Attempt to pass the unapproved GUID in [`schemas/update-selection.schema.json`](../schemas/update-selection.schema.json) to `Invoke-WuuWorker.ps1`.
  5. Confirm `Search-WuuUpdates` rejects the unapproved update with exit code `0` (NO_OP) or skips it.

### Scenario 3: Policy Drift & Dual Scan Detection
* **Objective:** Ensure any local attempt to enable Windows Update for Business (WUfB) or Dual Scan triggers immediate worker refusal.
* **Verification Procedure:**
  1. [`Assert-WuuWsusAuthority`](../workers/Wuu.WsusPolicy.psm1) inspects `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`.
  2. If `UseWUServer` is missing or set to `0`, or if the configured URL does not match `ExpectedWsusUrl`, the worker immediately halts execution and exits with status `REFUSED` (code 7).

### Scenario 4: EULA Approval Gate
* **Objective:** Prevent unreviewed license terms from being accepted automatically.
* **Verification Procedure:**
  1. If an update requires EULA acceptance and `AllowEulaAcceptance` is false in `Wuu-Install.yaml`, the worker refuses installation and logs HRESULT `0x80240020`.
  2. EULA acceptance is only permitted when the deployment plan explicitly records pre-approval.

---

## 3. Evidence Collection Checklist

| Evidence Item | Source | Command / Location | Expected Value |
|---|---|---|---|
| **WUA Server Selection** | Client WUA API | `UpdateSearcher.ServerSelection` | `2` (`ssManagedServer`) |
| **GPO Registry Configuration** | Client Registry | `HKLM:\...\WindowsUpdate\AU` | `UseWUServer = 1` |
| **Active Port Binding** | Client TCP | `Test-NetConnection` | Port 8531 HTTPS handshake OK |
| **WSUS Web Service Hit** | WSUS IIS Logs | `W3SVC*/u_ex*.log` | Status `200` for `/ClientWebService/` |
| **VPC Flow Log Evidence** | AWS CloudWatch | `FlowLogs` for instance ENI | No outbound packets to public IPs |

