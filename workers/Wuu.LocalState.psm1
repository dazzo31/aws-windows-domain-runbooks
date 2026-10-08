# Wuu.LocalState.psm1
# Manages system-scoped mutex, atomic ACL-protected per-operation journals,
# local boot identity tracking, and abandoned-operation inspection on managed nodes.
# PowerShell 5.1 native syntax.

$ErrorActionPreference = 'Stop'

$script:SystemMutexName = 'Global\WUU_Servicing_Lock'
$script:LocksDirectory = 'C:\ProgramData\WUU\locks'

function Get-WuuBootIdentity {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance Win32_OperatingSystem
    $lastBootTime = $os.LastBootUpTime
    $bootId = $lastBootTime.ToString("yyyyMMdd-HHmmss-fffffff")
    return [pscustomobject]@{
        BootId = $bootId
        LastBootUpTime = $lastBootTime
    }
}

function Test-WuuNativeServicingActive {
    [CmdletBinding()]
    param()

    # Check for active servicing processes (CBS / TrustedInstaller)
    $servicingProcesses = Get-Process -Name 'TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker' -ErrorAction SilentlyContinue
    if ($servicingProcesses -and $servicingProcesses.Count -gt 0) {
        return $true
    }
    return $false
}

function Enter-WuuServicingLock {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$TimeoutMilliseconds = 5000,

        [Parameter()]
        [switch]$SkipNativeCheck
    )

    # 1. Native servicing collision check (T037)
    if (-not $SkipNativeCheck -and (Test-WuuNativeServicingActive)) {
        throw "Native servicing collision: TrustedInstaller/TiWorker is currently active on this node. Mutex acquisition refused."
    }

    $mutexSecurity = New-Object System.Security.AccessControl.MutexSecurity
    $rule = New-Object System.Security.AccessControl.MutexAccessRule(
        [System.Security.Principal.SecurityIdentifier]'S-1-1-0', # Everyone (for inter-process wait)
        [System.Security.AccessControl.MutexRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $mutexSecurity.AddAccessRule($rule)

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, $script:SystemMutexName, [ref]$createdNew, $mutexSecurity)

    $acquired = $mutex.WaitOne($TimeoutMilliseconds)
    if (-not $acquired) {
        $mutex.Dispose()
        throw "Failed to acquire system mutex '$script:SystemMutexName' within $TimeoutMilliseconds ms. Another servicing operation is currently active."
    }

    return $mutex
}

function Exit-WuuServicingLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Threading.Mutex]$Mutex
    )

    try {
        $Mutex.ReleaseMutex()
    } finally {
        $Mutex.Dispose()
    }
}

function New-WuuOperationJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$OperationId,

        [Parameter(Mandatory=$true)]
        [string]$Action,

        [Parameter()]
        [string]$ChangeTicket = ''
    )

    if (-not (Test-Path $script:LocksDirectory)) {
        $null = New-Item -ItemType Directory -Path $script:LocksDirectory -Force
    }

    $boot = Get-WuuBootIdentity
    $journalFile = Join-Path $script:LocksDirectory "$OperationId.journal.json"

    $journalData = [ordered]@{
        operationId = $OperationId
        action = $Action
        changeTicket = $ChangeTicket
        bootId = $boot.BootId
        lastBootUpTime = $boot.LastBootUpTime.ToString("o")
        startTime = (Get-Date).ToUniversalTime().ToString("o")
        status = "ACTIVE"
        lastHeartbeat = (Get-Date).ToUniversalTime().ToString("o")
    }

    $json = $journalData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($journalFile, $json, [System.Text.UTF8Encoding]::new($false))

    # Secure ACL: SYSTEM + Administrators only
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544',
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]'S-1-5-18',
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    Set-Acl -Path $journalFile -AclObject $acl

    return $journalFile
}

function Complete-WuuOperationJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$OperationId,

        [Parameter(Mandatory=$true)]
        [ValidateSet('SUCCEEDED', 'FAILED', 'UNCERTAIN', 'CANCELLED')]
        [string]$FinalStatus,

        [Parameter()]
        [string]$Details = ''
    )

    $journalFile = Join-Path $script:LocksDirectory "$OperationId.journal.json"
    if (-not (Test-Path $journalFile)) {
        throw "Journal file not found for operation $OperationId"
    }

    $raw = [System.IO.File]::ReadAllText($journalFile)
    $journal = $raw | ConvertFrom-Json

    $journal.status = $FinalStatus
    $journal.completionTime = (Get-Date).ToUniversalTime().ToString("o")
    $journal.details = $Details

    $json = $journal | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($journalFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Find-WuuAbandonedOperations {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:LocksDirectory)) { return @() }

    $journals = Get-ChildItem -Path $script:LocksDirectory -Filter "*.journal.json" -File
    $abandoned = [System.Collections.Generic.List[pscustomobject]]::new()
    $currentBoot = Get-WuuBootIdentity

    foreach ($j in $journals) {
        $raw = [System.IO.File]::ReadAllText($j.FullName)
        $data = $raw | ConvertFrom-Json
        if ($data.status -eq 'ACTIVE') {
            # Check if boot ID changed since operation started
            $bootChanged = ($data.bootId -ne $currentBoot.BootId)
            $abandoned.Add([pscustomobject]@{
                OperationId = $data.operationId
                Action = $data.action
                StartTime = $data.startTime
                BootId = $data.bootId
                CurrentBootId = $currentBoot.BootId
                RebootDetected = $bootChanged
                JournalPath = $j.FullName
            })
        }
    }

    return $abandoned
}

Export-ModuleMember -Function Get-WuuBootIdentity, Enter-WuuServicingLock, Exit-WuuServicingLock, `
    New-WuuOperationJournal, Complete-WuuOperationJournal, Find-WuuAbandonedOperations, Test-WuuNativeServicingActive
