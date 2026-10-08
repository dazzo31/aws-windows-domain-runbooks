# Wuu.Reboot.psm1
# Manages pending reboot detection, boot checkpointing, and controlled SSM exit 3010 reboots.
# Enforces a strict one-reboot-per-operation limit to prevent restart loops.
# PowerShell 5.1 native syntax.

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

