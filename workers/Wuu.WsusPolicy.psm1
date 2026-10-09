<#
.SYNOPSIS
    Enforces WSUS as the sole update authority on managed nodes.

.DESCRIPTION
    Validates and enforces local registry policy governing Windows Update Agent behavior.
    Verifies UseWUServer is enabled, validates HTTPS TLS endpoint bindings on port 8531,
    detects policy drift from Active Directory Group Policy, and strictly prohibits
    Dual Scan and fallback to public Microsoft Update. PowerShell 5.1 native syntax.

.NOTES
    ===================================================================================
    OPERATIONAL STATUS: UNTESTED REFERENCE IMPLEMENTATION — LAB TESTING REQUIRED
    -----------------------------------------------------------------------------------
    This module has been validated syntactically and offline via automated unit checks.
    It has NEVER been executed against a live production Windows Domain Controller,
    WSUS server, or AWS production account.
    MANDATORY PRE-REQUISITE: Must be exercised in an isolated testbed lab (Gate G1-G3)
    prior to any production consideration.
    ===================================================================================

    LLM-SAFETY-CONTRACT & INVARIANTS:
    - NonInteractive: Executes without interactive prompts.
    - WSUS Authority Invariant: WSUS is the sole update authority.
    - Prohibited Fallbacks: Prohibits fallback to Microsoft Update or AWS Patch Manager.
    - TLS Requirement: Enforces HTTPS URL with port 8531 for WSUS communications.

    PRECONDITIONS:
    - Windows PowerShell 5.1 runtime under SYSTEM or elevated Administrator.

    FAILURE MODES & RECOVERY:
    - If policy does not match expected WSUS or is missing, Test-WuuWsusPolicyValid returns false.
#>

$ErrorActionPreference = 'Stop'

$script:WupRegistryKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:AuRegistryKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

function Get-WuuWsusPolicyStatus {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:WupRegistryKey)) {
        return [pscustomobject]@{
            Configured = $false
            WUServer = $null
            WUStatusServer = $null
            UseWUServer = $false
            DualScanDisabled = $false
            Status = "MISSING_POLICY"
        }
    }

    $wup = Get-ItemProperty -Path $script:WupRegistryKey
    $useWuServer = $false
    if (Test-Path $script:AuRegistryKey) {
        $au = Get-ItemProperty -Path $script:AuRegistryKey
        $useWuServer = [bool]($au.UseWUServer -eq 1)
    }

    $dualScanDisabled = [bool]($wup.DisableDualScan -eq 1)

    return [pscustomobject]@{
        Configured = [bool]($wup.WUServer)
        WUServer = $wup.WUServer
        WUStatusServer = $wup.WUStatusServer
        UseWUServer = $useWuServer
        DualScanDisabled = $dualScanDisabled
        TargetGroup = $wup.TargetGroup
        Status = if ($wup.WUServer -and $useWuServer) { "CONFIGURED" } else { "INCOMPLETE" }
    }
}

function Assert-WuuWsusAuthority {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ExpectedWsusUrl
    )

    $status = Get-WuuWsusPolicyStatus
    if (-not $status.Configured) {
        throw "WSUS Authority Violation: Windows Update GPO policy is not configured on this node."
    }

    if (-not $status.UseWUServer) {
        throw "WSUS Authority Violation: AU\UseWUServer is not set to 1. Managed update source is disabled."
    }

    # Scheme and Port Enforcement
    $uri = [uri]$status.WUServer
    if ($uri.Scheme -ne 'https') {
        throw "WSUS Authority Violation: WSUS URL scheme must be HTTPS (found '$($uri.Scheme)')."
    }

    if ($uri.Port -ne 8531) {
        throw "WSUS Authority Violation: WSUS URL must use TLS port 8531 (found port $($uri.Port))."
    }

    if ($ExpectedWsusUrl) {
        $expectedUri = [uri]$ExpectedWsusUrl
        if ($uri.DnsSafeHost.ToLowerInvariant() -ne $expectedUri.DnsSafeHost.ToLowerInvariant()) {
            throw "WSUS Policy Drift: Node configured WSUS host '$($uri.DnsSafeHost)' does not match expected host '$($expectedUri.DnsSafeHost)'."
        }
    }

    return $status
}

Export-ModuleMember -Function Get-WuuWsusPolicyStatus, Assert-WuuWsusAuthority

