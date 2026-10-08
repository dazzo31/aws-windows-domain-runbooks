# Wuu.Result.psm1
# Formats and writes structured WUU worker execution results.
# Maps outcomes to explicit exit codes (0, 3, 4, 5, 6, 7). Never uses counts as exit codes.
# PowerShell 5.1 native syntax.

$ErrorActionPreference = 'Stop'

function Get-WuuExitCode {
    param([string]$Status, [bool]$RebootRequired)
    if ($RebootRequired) { return 3 }
    switch ($Status) {
        'SUCCESS'         { return 0 }
        'NO_OP'           { return 0 }
        'PARTIAL'         { return 4 }
        'FAILED'          { return 5 }
        'TIMEOUT'         { return 6 }
        'REFUSED'         { return 7 }
        'REBOOT_REQUIRED' { return 3 }
        default           { return 5 }
    }
}

function New-WuuWorkerResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$OperationId,

        [Parameter(Mandatory=$true)]
        [string]$InstanceId,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Scan', 'Download', 'Install', 'Bootstrap', 'Inventory', 'Reboot', 'Verify')]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [ValidateSet('SUCCESS', 'NO_OP', 'PARTIAL', 'FAILED', 'SKIPPED', 'TIMEOUT', 'REFUSED', 'REBOOT_REQUIRED')]
        [string]$Status,

        [Parameter()]
        [bool]$RebootRequired = $false,

        [Parameter()]
        [array]$Updates = @(),

        [Parameter(Mandatory=$true)]
        [datetime]$StartTime,

        [Parameter()]
        [datetime]$EndTime = (Get-Date),

        [Parameter()]
        [string]$ErrorMessage = $null
    )

    $exitCode = Get-WuuExitCode -Status $Status -RebootRequired $RebootRequired

    $resultObj = [ordered]@{
        schemaVersion = "1.0.0"
        operationId = $OperationId
        instanceId = $InstanceId
        action = $Action
        status = $Status
        rebootRequired = $RebootRequired
        updates = $Updates
        startTime = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        endTime = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        exitCode = $exitCode
        errorMessage = $ErrorMessage
    }

    return $resultObj
}

function Write-WuuResultFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$ResultObject,

        [Parameter()]
        [string]$ResultsDirectory = 'C:\ProgramData\WUU\results'
    )

    if (-not (Test-Path $ResultsDirectory)) {
        $null = New-Item -ItemType Directory -Path $ResultsDirectory -Force
    }

    $filePath = Join-Path $ResultsDirectory "$($ResultObject.operationId)-$($ResultObject.action).result.json"
    $json = $ResultObject | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($filePath, $json, [System.Text.UTF8Encoding]::new($false))

    Write-Host "`n=== WUU Worker Result Summary ===" -ForegroundColor Cyan
    Write-Host "Action: $($ResultObject.action) | Status: $($ResultObject.status) | ExitCode: $($ResultObject.exitCode)" -ForegroundColor Green
    Write-Host "Updates Processed: $($ResultObject.updates.Count) | Reboot Required: $($ResultObject.rebootRequired)" -ForegroundColor Gray
    Write-Host "Result File: $filePath" -ForegroundColor Gray

    return $filePath
}

Export-ModuleMember -Function Get-WuuExitCode, New-WuuWorkerResult, Write-WuuResultFile

