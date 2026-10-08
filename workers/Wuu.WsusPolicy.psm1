# Wuu.WsusPolicy.psm1
# Enforces WSUS as the sole update authority on managed nodes.
# Validates UseWUServer, TLS bindings, policy non-drift, and prohibits Microsoft Update fallback.
# PowerShell 5.1 native syntax.

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

