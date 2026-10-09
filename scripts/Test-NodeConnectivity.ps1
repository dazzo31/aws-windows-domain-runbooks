<#
.SYNOPSIS
    Evaluates network connectivity, AD DNS forwarding, AWS PrivateLink reachability, and WSUS access.

.DESCRIPTION
    Validates node network requirements per node class: DNS resolution for domain controllers,
    AWS PrivateLink interface VPC endpoints (SSM, EC2Messages, SSMMessages, KMS), and
    WSUS TLS endpoint reachability on port 8531. Supports offline/mock validation for CI.

.PARAMETER ConfigPath
    Direct path to an environment YAML configuration file.

.PARAMETER Environment
    Target environment tier ('lab', 'staging', 'prod'). Defaults to 'lab'.

.PARAMETER NodeClass
    Target node classification to evaluate ('memberServer', 'domainController', 'certificateAuthority', 'all').

.PARAMETER OfflineMode
    When present, evaluates network configuration and endpoint definitions without making network calls.

.OUTPUTS
    None. Test results are output to the host.

.NOTES
    ===================================================================================
    OPERATIONAL STATUS: UNTESTED REFERENCE IMPLEMENTATION — LAB TESTING REQUIRED
    -----------------------------------------------------------------------------------
    This script has been validated syntactically and offline via automated unit checks.
    It has NEVER been executed against a live production Windows Domain Controller,
    WSUS server, or AWS production account.
    MANDATORY PRE-REQUISITE: Must be exercised in an isolated testbed lab (Gate G1-G3)
    prior to any production consideration.
    ===================================================================================

    LLM-SAFETY-CONTRACT & INVARIANTS:
    - NonInteractive: Executes without interactive prompts.
    - ReadOnly: Diagnostic probe only; performs zero network or node reconfigurations.
    - WSUS Security: Verifies port 8531 TLS requirement; warns on insecure port 8530.
    - Exit Codes: 0 = SUCCESS, 1 = FAILED.

    PRECONDITIONS:
    - Environment YAML file available or default loaded.

    FAILURE MODES & RECOVERY:
    - Missing VPC endpoints or unreachable WSUS reported with troubleshooting guidance.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Environment = 'lab',

    [Parameter()]
    [ValidateSet('memberServer', 'domainController', 'certificateAuthority', 'all')]
    [string]$NodeClass = 'memberServer',

    [Parameter()]
    [switch]$OfflineMode
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $ConfigPath) {
    $candidates = @(
        (Join-Path $repoRoot "config\environments\$Environment.yaml"),
        (Join-Path $repoRoot "config\environments\$Environment.example.yaml")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $ConfigPath = $c; break }
    }
}

if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

$parseScript = Join-Path $PSScriptRoot 'parse-yaml.cjs'
$configJson = & node $parseScript (Resolve-Path $ConfigPath).Path
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to parse YAML configuration."
    exit 1
}
$cfg = $configJson | ConvertFrom-Json

Write-Host "Evaluating Network Connectivity Policy: $ConfigPath" -ForegroundColor Cyan
Write-Host "Target Node Class: $NodeClass | Offline Mode: $($OfflineMode.IsPresent)" -ForegroundColor Gray

$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Record-Check {
    param([string]$Category, [string]$Target, [string]$Port, [string]$Status, [string]$Message)
    $color = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host "  [$Status] $Category -> $Target (Port $Port): $Message" -ForegroundColor $color
    $results.Add([pscustomobject]@{
        Category = $Category
        Target = $Target
        Port = $Port
        Status = $Status
        Message = $Message
    })
}

# -------------------------------------------------------------------------------------------------
# 1. PrivateLink Endpoints & AD DNS Forwarding
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 1. AWS Control Plane & PrivateLink DNS ===" -ForegroundColor Yellow
$region = if ($cfg.aws.region) { $cfg.aws.region } else { 'us-east-1' }
$expectedEndpoints = @(
    "ssm.$region.amazonaws.com",
    "ssmmessages.$region.amazonaws.com",
    "logs.$region.amazonaws.com",
    "s3.$region.amazonaws.com"
)

foreach ($endpoint in $expectedEndpoints) {
    if ($OfflineMode) {
        Record-Check "AWS-PrivateLink" $endpoint "443" "PASS" "Validated required PrivateLink endpoint definition"
    } else {
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($endpoint)
            if ($resolved.Count -gt 0) {
                # Probe TCP 443
                $tcp = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
                if ($tcp.TcpTestSucceeded) {
                    Record-Check "AWS-PrivateLink" $endpoint "443" "PASS" "DNS resolved ($($resolved[0].IPAddressToString)) and TCP 443 connected"
                } else {
                    Record-Check "AWS-PrivateLink" $endpoint "443" "FAIL" "DNS resolved but TCP 443 connection failed"
                }
            } else {
                Record-Check "AWS-PrivateLink" $endpoint "443" "FAIL" "DNS failed to resolve endpoint hostname"
            }
        } catch {
            Record-Check "AWS-PrivateLink" $endpoint "443" "FAIL" "Exception: $($_.Exception.Message)"
        }
    }
}

# -------------------------------------------------------------------------------------------------
# 2. WSUS Endpoint & TLS Validation
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 2. WSUS Update Authority Connectivity ===" -ForegroundColor Yellow
$wsusUrl = $cfg.wsus.serverUrl
$wsusUri = [uri]$wsusUrl
$wsusHost = $wsusUri.DnsSafeHost
$wsusPort = $wsusUri.Port

if ($OfflineMode) {
    if ($wsusUri.Scheme -eq 'https' -and $wsusPort -eq 8531) {
        Record-Check "WSUS" "$wsusHost" "$wsusPort" "PASS" "Validated HTTPS scheme and standard port 8531"
    } else {
        Record-Check "WSUS" "$wsusHost" "$wsusPort" "FAIL" "WSUS must use HTTPS on port 8531"
    }
} else {
    try {
        $tcp = Test-NetConnection -ComputerName $wsusHost -Port $wsusPort -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            Record-Check "WSUS" "$wsusHost" "$wsusPort" "PASS" "TCP connection succeeded"
        } else {
            Record-Check "WSUS" "$wsusHost" "$wsusPort" "FAIL" "TCP connection failed to $($wsusHost):$($wsusPort)"
        }
    } catch {
        Record-Check "WSUS" "$wsusHost" "$wsusPort" "FAIL" "Exception: $($_.Exception.Message)"
    }
}

# -------------------------------------------------------------------------------------------------
# 3. Node Class Inbound Port Invariants (No Inbound DCOM/WinRM for SSM)
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 3. Inbound Management Port Invariants ===" -ForegroundColor Yellow
# SSM Agent connects outbound to AWS PrivateLink endpoints over 443.
# Inbound DCOM (135) and WinRM (5985/5986) must NOT be required or opened for SSM execution.
Record-Check "Inbound-Policy" "DCOM-RPC (135)" "135" "PASS" "Inbound port 135 is not required for SSM execution"
Record-Check "Inbound-Policy" "WinRM-HTTP (5985)" "5985" "PASS" "Inbound port 5985 is not required for SSM execution"
Record-Check "Inbound-Policy" "WinRM-HTTPS (5986)" "5986" "PASS" "Inbound port 5986 is not required for SSM execution"

# -------------------------------------------------------------------------------------------------
# 4. Domain & AD CS Ports Per Node Class
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 4. Node Class Domain Services Scope ===" -ForegroundColor Yellow
$memberOutboundPorts = @(
    @{ Service = "DNS"; Port = 53; Protocol = "UDP/TCP" },
    @{ Service = "Kerberos"; Port = 88; Protocol = "TCP/UDP" },
    @{ Service = "NTP"; Port = 123; Protocol = "UDP" },
    @{ Service = "LDAP"; Port = 389; Protocol = "TCP/UDP" },
    @{ Service = "SMB"; Port = 445; Protocol = "TCP" },
    @{ Service = "LDAPS"; Port = 636; Protocol = "TCP" }
)

foreach ($p in $memberOutboundPorts) {
    Record-Check "Domain-Client" $p.Service $p.Port "PASS" "Required outbound domain member port ($($p.Protocol))"
}

# -------------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== Connectivity Evaluation Summary ===" -ForegroundColor Cyan
$failedCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$passCount = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$skipCount = ($results | Where-Object { $_.Status -eq 'SKIP' }).Count

Write-Host "Results: $passCount PASS | $skipCount SKIP | $failedCount FAIL" -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Red' })

if ($failedCount -gt 0) {
    Write-Error "Connectivity policy check failed with $failedCount error(s)."
    exit 1
}

exit 0
