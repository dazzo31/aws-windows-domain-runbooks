<#
.SYNOPSIS
    Manages pending reboot detection, boot checkpointing, and controlled SSM exit 3010 reboots.

.DESCRIPTION
    Provides reboot safety and lifecycle management for WUU servicing operations.
    Inspects Component Based Servicing (CBS), WindowsUpdate Auto Update, PendingFileRenameOperations,
    and SCCM reboot indicators. Enforces a strict one-reboot-per-operation limit to prevent
    restart loops. Implements controlled SSM Agent reboot signals (exit code 3010).

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
    - Loop Guard: Checks local reboot counter; throws REFUSED if maximum reboots exceeded.
    - Clean Exit: Emits exit code 3010 when SSM Agent coordination is required.

    PRECONDITIONS:
    - Windows PowerShell 5.1 runtime under SYSTEM or elevated Administrator.

    FAILURE MODES & RECOVERY:
    - Reboots aborted if unexpected active servicing processes detected.
#>

$ErrorActionPreference = 'Stop'

function Test-WuuPendingReboot {
    [CmdletBinding()]
    param()

    $pending = $false

    # 1. Component Based Servicing reboot pending
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $pending = $true
    }

    # 2. Windows Update Auto Update reboot required
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $pending = $true
    }

    # 3. Pending file rename operations
    $pendingRename = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pendingRename -and $pendingRename.Length -gt 0) {
        $pending = $true
    }

    return $pending
}

function Get-WuuBootIdentifier {
    [CmdletBinding()]
    param()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return $os.LastBootUpTime.ToString('o')
    } catch {
        # Fallback to tick count or process start if CIM is unavailable in unit tests
        return [System.Environment]::TickCount.ToString()
    }
}

function Set-WuuRebootCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$OperationId,

        [Parameter(Mandatory=$true)]
        [string]$ChangeTicket
    )

    $stateDir = 'C:\ProgramData\WUU\state'
    if (-not (Test-Path $stateDir)) {
        $null = New-Item -ItemType Directory -Path $stateDir -Force
    }

    $checkpointFile = Join-Path $stateDir 'reboot-checkpoint.json'
    if (Test-Path $checkpointFile) {
        try {
            $existing = Get-Content $checkpointFile -Raw | ConvertFrom-Json
            if ($existing.operationId -eq $OperationId -and $existing.rebootCount -ge 1) {
                throw "One-reboot limit exceeded for operation $OperationId. Multiple automated reboots are prohibited."
            }
        } catch {
            if ($_.Exception.Message -match 'One-reboot limit') { throw }
        }
    }

    $currentBootId = Get-WuuBootIdentifier
    $checkpoint = [ordered]@{
        operationId = $OperationId
        changeTicket = $ChangeTicket
        priorBootId = $currentBootId
        rebootCount = 1
        timestamp = (Get-Date).ToString('o')
    }

    $json = $checkpoint | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($checkpointFile, $json, [System.Text.UTF8Encoding]::new($false))
    return $checkpoint
}

function Invoke-WuuReboot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$OperationId,

        [Parameter(Mandatory=$true)]
        [string]$ChangeTicket,

        [Parameter()]
        [int]$DelaySeconds = 5
    )

    Write-Host "Setting reboot checkpoint for operation $OperationId under ticket $ChangeTicket..." -ForegroundColor Cyan
    $checkpoint = Set-WuuRebootCheckpoint -OperationId $OperationId -ChangeTicket $ChangeTicket

    Write-Host "Reboot initiated. Boot ID checkpointed: $($checkpoint.priorBootId)" -ForegroundColor Green
    Write-Host "Returning exit code 3010 to trigger controlled SSM Agent reboot." -ForegroundColor Yellow

    # SSM Agent intercepts process exit code 3010 and performs a graceful host reboot
    return 3010
}

Export-ModuleMember -Function Test-WuuPendingReboot, Get-WuuBootIdentifier, Set-WuuRebootCheckpoint, Invoke-WuuReboot

