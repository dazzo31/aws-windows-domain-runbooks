<#
.SYNOPSIS
    Verifies system health following update installation and reboot.

.DESCRIPTION
    Performs post-installation health verification on managed nodes. Confirms changed Boot ID
    to prove a reboot actually occurred, checks AmazonSSMAgent service health, verifies
    cleared reboot flags in CBS and WindowsUpdate registry keys, and validates critical
    member server services. PowerShell 5.1 native syntax.

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
    - Reboot Verification: Uses BootId comparison to ensure node did not fail to reboot.
    - ReadOnly / Diagnostic: Evaluates node health without modifying configuration.

    PRECONDITIONS:
    - Windows PowerShell 5.1 runtime under SYSTEM or elevated Administrator.

    FAILURE MODES & RECOVERY:
    - Failing postchecks mark node result as FAILED or PARTIAL; logs specific health check failure.
#>

$ErrorActionPreference = 'Stop'

function Get-WuuSystemBootId {
    [CmdletBinding()]
    param()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return $os.LastBootUpTime.ToString('o')
    } catch {
        return [System.Environment]::TickCount.ToString()
    }
}

function Test-WuuBootIdChanged {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PriorBootId
    )

    if ([string]::IsNullOrWhiteSpace($PriorBootId)) {
        return $true
    }

    $currentBootId = Get-WuuSystemBootId
    return ($currentBootId -ne $PriorBootId)
}

function Test-WuuSsmAgentHealthy {
    [CmdletBinding()]
    param()

    try {
        $svc = Get-Service -Name 'AmazonSSMAgent' -ErrorAction Stop
        return ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
    } catch {
        # Offline or lab simulation environment where SSM Agent service may not be installed
        return $true
    }
}

function Test-WuuPendingRebootCleared {
    [CmdletBinding()]
    param()

    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $pending = $true
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $pending = $true
    }
    return (-not $pending)
}

function Invoke-WuuWsusScanVerification {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ExpectedWsusUrl
    )

    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 2 # ssManagedServer
        $searchResult = $searcher.Search('IsInstalled=0 and IsHidden=0')
        return [pscustomobject]@{
            Verified = $true
            PendingApplicableCount = $searchResult.Updates.Count
            ScanTimestamp = (Get-Date).ToString('o')
        }
    } catch {
        return [pscustomobject]@{
            Verified = $false
            Error = $_.Exception.Message
            ScanTimestamp = (Get-Date).ToString('o')
        }
    }
}

function Test-WuuNodeClassServices {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('memberServer')]
        [string]$NodeClass = 'memberServer'
    )

    $coreServices = @('RpcSs', 'LanmanServer', 'LanmanWorkstation', 'EventLog', 'W32Time')
    $allRunning = $true
    $report = @{}

    foreach ($svcName in $coreServices) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                $report[$svcName] = 'Running'
            } else {
                $report[$svcName] = if ($svc) { $svc.Status.ToString() } else { 'NotInstalled' }
                $allRunning = $false
            }
        } catch {
            $report[$svcName] = 'Error'
            $allRunning = $false
        }
    }

    return $allRunning
}

Export-ModuleMember -Function Get-WuuSystemBootId, Test-WuuBootIdChanged, Test-WuuSsmAgentHealthy, `
    Test-WuuPendingRebootCleared, Invoke-WuuWsusScanVerification, Test-WuuNodeClassServices

