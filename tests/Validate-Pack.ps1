$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$json = & node (Join-Path $PSScriptRoot 'read-documents.cjs')
if ($LASTEXITCODE -ne 0) { throw 'YAML/schema safety checks failed.' }
$documents = $json | ConvertFrom-Json

# Planning and environment template validation gate (Task T002)
$planningJson = & node (Join-Path $PSScriptRoot 'validate-planning.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Planning checkpoints or environment validation failed.' }
$planning = $planningJson | ConvertFrom-Json
$scriptCount = 0
foreach ($document in $documents) {
    foreach ($script in $document.scripts) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "$($document.name): $($parseErrors.Message -join '; ')" }
        $scriptCount++
    }
}
$savedEnvironment = @{}
foreach ($entry in Get-ChildItem Env: | Where-Object Name -like 'SSM_*') {
    $savedEnvironment[$entry.Name] = $entry.Value
    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
}
$guardChecks = 0
try {
    foreach ($document in $documents) {
        foreach ($code in $document.scripts) {
            $pipeline = [PowerShell]::Create()
            try {
                $null = $pipeline.AddScript($code)
                $invocationError = ''
                try { $null = $pipeline.Invoke() }
                catch { $invocationError = $_.Exception.Message; if ($invocationError -notmatch 'Missing ENV_VAR') { throw } }
                $errors = $invocationError + ($pipeline.Streams.Error | Out-String)
                if ($errors -notmatch 'Missing ENV_VAR') { throw "$($document.name): missing-input guard failed." }
                $guardChecks++
            } finally { $pipeline.Dispose() }
        }
    }
    $env:SSM_Action = 'Create'
    $env:SSM_Server = 'dc.example.test'
    $env:SSM_ManagedOU = 'OU=Managed,DC=example,DC=test'
    $env:SSM_Identity = 'test.user'
    $env:SSM_DisplayName = 'Test User'
    $env:SSM_UserPrincipalName = 'test.user@example.test'
    $env:SSM_PasswordParameter = '/test/password'
    $env:SSM_ChangeTicket = ''
    $userCode = ($documents | Where-Object name -eq 'WinDomain-Users.yaml').scripts[0]
    $mocks = @'
function Import-Module { param($Name) }
function Get-ADOrganizationalUnit { param($Identity,$Server) [pscustomobject]@{ DistinguishedName = $Identity } }
function Get-ADUser { param($Filter,$Server,$Properties) }
function Get-SSMParameter { $global:WriteAttempted = $true; throw 'Secret fetch must not occur.' }
function New-ADUser { $global:WriteAttempted = $true; throw 'Mutation must not occur.' }
$global:WriteAttempted = $false
'@
    foreach ($apply in @('false','true')) {
        $env:SSM_Apply = $apply
        $pipeline = [PowerShell]::Create()
        try {
            $null = $pipeline.AddScript($mocks + [Environment]::NewLine + $userCode)
            $output = ''
            $invocationError = ''
            try { $output = $pipeline.Invoke() | Out-String }
            catch { $invocationError = $_.Exception.Message; if ($apply -ne 'true' -or $invocationError -notmatch 'Apply requires ChangeTicket') { throw } }
            $errors = $invocationError + ($pipeline.Streams.Error | Out-String)
            if ($pipeline.Runspace.SessionStateProxy.GetVariable('WriteAttempted')) { throw 'User safety gate allowed a secret fetch or mutation.' }
            if ($apply -eq 'false' -and ($errors -or $output -notmatch 'PREVIEW')) { throw "User preview test failed: $errors" }
            if ($apply -eq 'true' -and $errors -notmatch 'Apply requires ChangeTicket') { throw 'User missing-ticket test failed.' }
            $guardChecks++
        } finally { $pipeline.Dispose() }
    }
} finally {
    foreach ($entry in Get-ChildItem Env: | Where-Object Name -like 'SSM_*') { [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process') }
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
Write-Output ("PASS: {0} YAML documents; {1} scripts parsed by PowerShell {2}; {3} safety checks; planning gate verified ({4} requirements, {5} tasks). No server operations executed." -f `
    $documents.Count, $scriptCount, $PSVersionTable.PSVersion, $guardChecks, $planning.requirementsCovered, $planning.tasksTracked)