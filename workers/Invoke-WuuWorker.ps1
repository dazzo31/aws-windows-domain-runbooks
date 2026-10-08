# Invoke-WuuWorker.ps1
# Master local entrypoint for noninteractive WUU worker execution on managed nodes.
# Runs under SSM Agent (SYSTEM) in Windows PowerShell 5.1 -STA -NonInteractive.
# Enforces mutual exclusion, journal persistence, WSUS authority, and structured result writing.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$OperationId,

    [Parameter(Mandatory=$true)]
    [ValidateSet('Scan', 'Download', 'Install', 'Reboot', 'Verify')]
    [string]$Action,

    [Parameter()]
    [string]$SelectionManifestJson = '[]',

    [Parameter()]
    [string]$ExpectedWsusUrl,

    [Parameter()]
    [bool]$AllowEulaAcceptance = $false,

    [Parameter()]
    [string]$ChangeTicket = '',

    [Parameter()]
    [string]$PriorBootId = ''
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date
$instanceId = $env:COMPUTERNAME

# Import local worker modules
$scriptRoot = $PSScriptRoot
Import-Module (Join-Path $scriptRoot 'Wuu.LocalState.psm1') -Force
Import-Module (Join-Path $scriptRoot 'Wuu.WsusPolicy.psm1') -Force
Import-Module (Join-Path $scriptRoot 'Wuu.LocalUpdate.psm1') -Force
Import-Module (Join-Path $scriptRoot 'Wuu.Result.psm1') -Force
Import-Module (Join-Path $scriptRoot 'Wuu.Reboot.psm1') -Force
Import-Module (Join-Path $scriptRoot 'Wuu.Postcheck.psm1') -Force

Write-Host "=== Invoking WUU Local Worker ===" -ForegroundColor Cyan
Write-Host "OperationId: $OperationId | Action: $Action | Node: $instanceId" -ForegroundColor Gray
Write-Host "StartTime: $($startTime.ToString('o'))" -ForegroundColor Gray

# 1. Acquire Local System Servicing Mutex (Mutual Exclusion)
$mutex = $null
try {
    $mutex = Enter-WuuServicingLock -TimeoutMilliseconds 10000
} catch {
    Write-Error "Failed to acquire servicing lock: $($_.Exception.Message)"
    $res = New-WuuWorkerResult -OperationId $OperationId -InstanceId $instanceId -Action $Action `
        -Status "REFUSED" -StartTime $startTime -ErrorMessage $_.Exception.Message
    $null = Write-WuuResultFile -ResultObject $res
    exit 7
}

try {
    # 2. Initialize Atomic Operation Journal
    $journalFile = New-WuuOperationJournal -OperationId $OperationId -Action $Action -ChangeTicket $ChangeTicket

    # 3. Assert WSUS Authority & Policy Invariants
    try {
        $null = Assert-WuuWsusAuthority -ExpectedWsusUrl $ExpectedWsusUrl
    } catch {
        Write-Error "WSUS Authority Check Failed: $($_.Exception.Message)"
        Complete-WuuOperationJournal -OperationId $OperationId -FinalStatus "FAILED" -Details $_.Exception.Message
        $res = New-WuuWorkerResult -OperationId $OperationId -InstanceId $instanceId -Action $Action `
            -Status "FAILED" -StartTime $startTime -ErrorMessage $_.Exception.Message
        $null = Write-WuuResultFile -ResultObject $res
        exit 5
    }

    # 4. Parse Approved Selection Manifest
    $approvedSelection = @()
    if ($SelectionManifestJson -and $SelectionManifestJson -ne '[]') {
        try {
            $parsed = $SelectionManifestJson | ConvertFrom-Json
            if ($parsed -is [array]) { $approvedSelection = $parsed }
            elseif ($parsed.approvedUpdates) { $approvedSelection = $parsed.approvedUpdates }
        } catch {
            Write-Warning "Failed to parse SelectionManifestJson: $($_.Exception.Message). Continuing without selection filter."
        }
    }

    # 5. Execute Requested Action
    $updatesProcessed = @()
    $rebootReq = $false
    $overallStatus = "SUCCESS"

    switch ($Action) {
        'Scan' {
            $found = Search-WuuUpdates -ApprovedSelection $approvedSelection
            Write-Host "Scan completed: $($found.Count) applicable update(s) found." -ForegroundColor Green
            foreach ($u in $found) {
                $updatesProcessed += [pscustomobject]@{
                    updateId = $u.UpdateId
                    revisionNumber = $u.RevisionNumber
                    title = $u.Title
                    kbArticleId = $u.KbArticleId
                    resultCode = 0
                    hresult = "0x00000000"
                    status = if ($u.IsDownloaded) { "ALREADY_DOWNLOADED" } else { "PENDING" }
                }
            }
            if ($updatesProcessed.Count -eq 0) { $overallStatus = "NO_OP" }
        }

        'Download' {
            $found = Search-WuuUpdates -ApprovedSelection $approvedSelection
            $toDownload = @($found | Where-Object { -not $_.IsDownloaded })
            if ($toDownload.Count -eq 0) {
                Write-Host "Download completed: No pending downloads required (NO_OP)." -ForegroundColor Green
                $overallStatus = "NO_OP"
            } else {
                $dlResults = Download-WuuUpdates -UpdatesToDownload $toDownload
                $updatesProcessed = $dlResults
                $failed = @($dlResults | Where-Object { $_.status -eq 'FAILED' })
                $partial = @($dlResults | Where-Object { $_.status -eq 'PARTIAL' })
                if ($failed.Count -gt 0) { $overallStatus = "FAILED" }
                elseif ($partial.Count -gt 0) { $overallStatus = "PARTIAL" }
                else { $overallStatus = "SUCCESS" }
            }
        }

        'Install' {
            $found = Search-WuuUpdates -ApprovedSelection $approvedSelection
            $toInstall = @($found | Where-Object { $_.IsDownloaded })
            if ($toInstall.Count -eq 0) {
                Write-Host "Install completed: No downloaded updates available to install (NO_OP)." -ForegroundColor Green
                $overallStatus = "NO_OP"
            } else {
                $instOutcome = Install-WuuUpdates -UpdatesToInstall $toInstall -AllowEulaAcceptance $AllowEulaAcceptance
                $updatesProcessed = $instOutcome.UpdateOutcomes
                $rebootReq = $instOutcome.RebootRequired
                $failed = @($instOutcome.UpdateOutcomes | Where-Object { $_.status -eq 'FAILED' })
                $partial = @($instOutcome.UpdateOutcomes | Where-Object { $_.status -eq 'PARTIAL' })
                if ($failed.Count -gt 0) { $overallStatus = "FAILED" }
                elseif ($partial.Count -gt 0) { $overallStatus = "PARTIAL" }
                else { $overallStatus = "SUCCESS" }
            }
        }

        'Reboot' {
            $null = Set-WuuRebootCheckpoint -OperationId $OperationId -ChangeTicket $ChangeTicket
            $rebootReq = $true
            $overallStatus = "REBOOT_REQUIRED"
        }

        'Verify' {
            $bootCheck = $true
            if ($PriorBootId) {
                $bootCheck = Test-WuuBootIdChanged -PriorBootId $PriorBootId
            }
            $servicesOk = Test-WuuNodeClassServices -NodeClass 'memberServer'
            $ssmOk = Test-WuuSsmAgentHealthy
            if ($bootCheck -and $servicesOk -and $ssmOk) {
                $overallStatus = "SUCCESS"
            } else {
                $overallStatus = "FAILED"
            }
        }
    }

    # 6. Settle Operation Journal & Result
    Complete-WuuOperationJournal -OperationId $OperationId -FinalStatus $overallStatus -Details "Processed $($updatesProcessed.Count) updates"

    $finalResult = New-WuuWorkerResult -OperationId $OperationId -InstanceId $instanceId -Action $Action `
        -Status $overallStatus -RebootRequired $rebootReq -Updates $updatesProcessed -StartTime $startTime

    $null = Write-WuuResultFile -ResultObject $finalResult
    exit $finalResult.exitCode

} finally {
    if ($mutex) {
        Exit-WuuServicingLock -Mutex $mutex
    }
}
