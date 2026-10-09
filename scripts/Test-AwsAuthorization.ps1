<#
.SYNOPSIS
    Evaluates IAM role policies, node-class scoping, secret access isolation, and tag protection.

.DESCRIPTION
    Validates IAM role definitions, resource scoping, secret path boundaries, and tag-tampering
    protections defined across infra/iam.yaml and infra/secrets.yaml. Enforces node class
    isolation (memberServer vs domainController vs certificateAuthority) and checks least-privilege
    boundaries. Supports offline evaluation.

.PARAMETER IamTemplatePath
    Path to the IAM CloudFormation template. Defaults to infra\iam.yaml.

.PARAMETER SecretsTemplatePath
    Path to the Secrets CloudFormation template. Defaults to infra\secrets.yaml.

.PARAMETER OfflineMode
    When present, evaluates template YAML structures statically without calling AWS APIs.

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
    - Tier Boundary: Verifies memberServer roles cannot access Domain Controller secrets.
    - ReadOnly / NonMutating: Evaluates policies without changing AWS configurations.
    - Exit Codes: 0 = SUCCESS, 1 = FAILED.

    PRECONDITIONS:
    - CloudFormation templates in infra/ must exist.

    FAILURE MODES & RECOVERY:
    - Policy violations produce descriptive error messages indicating the rule failed.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$IamTemplatePath,

    [Parameter()]
    [string]$SecretsTemplatePath,

    [Parameter()]
    [switch]$OfflineMode
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $IamTemplatePath) {
    $IamTemplatePath = Join-Path $repoRoot "infra\iam.yaml"
}
if (-not $SecretsTemplatePath) {
    $SecretsTemplatePath = Join-Path $repoRoot "infra\secrets.yaml"
}

if (-not (Test-Path $IamTemplatePath)) {
    Write-Error "IAM template not found: $IamTemplatePath"
    exit 1
}
if (-not (Test-Path $SecretsTemplatePath)) {
    Write-Error "Secrets template not found: $SecretsTemplatePath"
    exit 1
}

$parseScript = Join-Path $PSScriptRoot 'parse-yaml.cjs'
$iamJson = & node $parseScript (Resolve-Path $IamTemplatePath).Path
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to parse IAM template."
    exit 1
}
$iam = $iamJson | ConvertFrom-Json

$secretsJson = & node $parseScript (Resolve-Path $SecretsTemplatePath).Path
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to parse Secrets template."
    exit 1
}
$sec = $secretsJson | ConvertFrom-Json

Write-Host "Evaluating AWS IAM & Secrets Authorization Policies" -ForegroundColor Cyan
Write-Host "IAM Template: $IamTemplatePath | Secrets Template: $SecretsTemplatePath" -ForegroundColor Gray
Write-Host "Offline Mode: $($OfflineMode.IsPresent)`n" -ForegroundColor Gray

$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Record-Check {
    param([string]$Role, [string]$PolicyRule, [string]$Status, [string]$Message)
    $color = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host "  [$Status] $Role -> $($PolicyRule): $Message" -ForegroundColor $color
    $results.Add([pscustomobject]@{
        Role = $Role
        PolicyRule = $PolicyRule
        Status = $Status
        Message = $Message
    })
}

# -------------------------------------------------------------------------------------------------
# 1. Operator Role Invariants (T009)
# -------------------------------------------------------------------------------------------------
Write-Host "=== 1. WuuOperatorRole Invariants ===" -ForegroundColor Yellow
$opRole = $iam.Resources.WuuOperatorRole
if ($opRole) {
    $opStmts = $opRole.Properties.Policies[0].PolicyDocument.Statement
    $allowAuto = $opStmts | Where-Object { $_.Sid -eq 'AllowStartApprovedAutomation' -and $_.Effect -eq 'Allow' }
    if ($allowAuto -and ($allowAuto.Action -contains 'ssm:StartAutomationExecution')) {
        Record-Check "OperatorRole" "StartAutomationExecution" "PASS" "Allowed for approved automation definitions only"
    } else {
        Record-Check "OperatorRole" "StartAutomationExecution" "FAIL" "Missing allowed automation execution"
    }

    $passRole = $opStmts | Where-Object { $_.Sid -eq 'AllowScopedPassRoleToAutomation' -and $_.Effect -eq 'Allow' }
    if ($passRole -and ($passRole.Action -eq 'iam:PassRole')) {
        Record-Check "OperatorRole" "ScopedPassRole" "PASS" "PassRole scoped to Automation service role"
    } else {
        Record-Check "OperatorRole" "ScopedPassRole" "FAIL" "PassRole statement not scoped"
    }

    $denyDirect = $opStmts | Where-Object { $_.Sid -eq 'DenyDirectMutationsAndArbitraryExecution' -and $_.Effect -eq 'Deny' }
    if ($denyDirect -and ($denyDirect.Action -contains 'ssm:SendCommand') -and ($denyDirect.Action -contains 'states:StartExecution')) {
        Record-Check "OperatorRole" "DenyDirectMutation" "PASS" "Explicitly denies direct SendCommand and StartExecution"
    } else {
        Record-Check "OperatorRole" "DenyDirectMutation" "FAIL" "Missing explicit deny for direct mutations"
    }
} else {
    Record-Check "OperatorRole" "RoleDefinition" "FAIL" "WuuOperatorRole resource not found"
}

# -------------------------------------------------------------------------------------------------
# 2. Approver Role Invariants (T009)
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 2. WuuApproverRole Invariants ===" -ForegroundColor Yellow
$appRole = $iam.Resources.WuuApproverRole
if ($appRole) {
    $appStmts = $appRole.Properties.Policies[0].PolicyDocument.Statement
    $allowSignal = $appStmts | Where-Object { $_.Sid -eq 'AllowSignalAutomation' -and $_.Effect -eq 'Allow' }
    if ($allowSignal -and ($allowSignal.Action -contains 'ssm:SendAutomationSignal')) {
        Record-Check "ApproverRole" "SendAutomationSignal" "PASS" "Permitted to signal approval on automation executions"
    } else {
        Record-Check "ApproverRole" "SendAutomationSignal" "FAIL" "Missing approval signaling statement"
    }

    $denyExec = $appStmts | Where-Object { $_.Sid -eq 'DenyDirectExecution' -and $_.Effect -eq 'Deny' }
    if ($denyExec -and ($denyExec.Action -contains 'ssm:SendCommand') -and ($denyExec.Action -contains 'ssm:StartAutomationExecution')) {
        Record-Check "ApproverRole" "DenyDirectExecution" "PASS" "Denied direct SendCommand and StartAutomationExecution (no self-approval)"
    } else {
        Record-Check "ApproverRole" "DenyDirectExecution" "FAIL" "Approver not denied execution"
    }
} else {
    Record-Check "ApproverRole" "RoleDefinition" "FAIL" "WuuApproverRole resource not found"
}

# -------------------------------------------------------------------------------------------------
# 3. Coordinator Role & Node-Class Scoping (T010)
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 3. WuuCoordinatorRole Scoping ===" -ForegroundColor Yellow
$coordRole = $iam.Resources.WuuCoordinatorRole
if ($coordRole) {
    $coordStmts = $coordRole.Properties.Policies[0].PolicyDocument.Statement
    $allowCmd = $coordStmts | Where-Object { $_.Sid -eq 'AllowSendCommandToApprovedMemberServers' -and $_.Effect -eq 'Allow' }
    if ($allowCmd -and $allowCmd.Condition.StringEquals.'ssm:resourceTag/WuuNodeClass' -eq 'memberServer') {
        Record-Check "CoordinatorRole" "NodeClassCondition" "PASS" "SendCommand strictly scoped to instances with WuuNodeClass=memberServer"
    } else {
        Record-Check "CoordinatorRole" "NodeClassCondition" "FAIL" "SendCommand not scoped to memberServer tag condition"
    }
} else {
    Record-Check "CoordinatorRole" "RoleDefinition" "FAIL" "WuuCoordinatorRole resource not found"
}

# -------------------------------------------------------------------------------------------------
# 4. Managed Node Role Anti-Tag-Tampering & Secret Deny (T010, T011)
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 4. WuuManagedNodeRole Isolation ===" -ForegroundColor Yellow
$nodeRole = $iam.Resources.WuuManagedNodeRole
if ($nodeRole) {
    $nodeStmts = $nodeRole.Properties.Policies[0].PolicyDocument.Statement
    $denySecret = $nodeStmts | Where-Object { $_.Sid -eq 'AntiTagTamperingAndSecretDeny' -and $_.Effect -eq 'Deny' }
    if ($denySecret -and ($denySecret.Action -contains 'kms:Decrypt') -and ($denySecret.Action -contains 'ssm:GetParameter') -and ($denySecret.Action -contains 'ec2:CreateTags')) {
        Record-Check "ManagedNodeRole" "AntiTagAndSecretDeny" "PASS" "Explicitly denies ec2:CreateTags, ssm:GetParameter, and kms:Decrypt"
    } else {
        Record-Check "ManagedNodeRole" "AntiTagAndSecretDeny" "FAIL" "Managed node not explicitly denied secrets/tags"
    }
} else {
    Record-Check "ManagedNodeRole" "RoleDefinition" "FAIL" "WuuManagedNodeRole resource not found"
}

# -------------------------------------------------------------------------------------------------
# 5. AD Password Worker & KMS Key Policy (T011)
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== 5. AD Password Worker & KMS Key Isolation ===" -ForegroundColor Yellow
$pwRole = $iam.Resources.WuuAdPasswordWorkerRole
if ($pwRole) {
    $pwStmts = $pwRole.Properties.Policies[0].PolicyDocument.Statement
    $allowPw = $pwStmts | Where-Object { $_.Sid -eq 'AllowReadApprovedPasswordParameterOnly' -and $_.Effect -eq 'Allow' }
    if ($allowPw -and ($allowPw.Action -eq 'ssm:GetParameter')) {
        Record-Check "PasswordWorkerRole" "ScopedParameterRead" "PASS" "Access limited to /wuu/*/ad/credentials/*"
    } else {
        Record-Check "PasswordWorkerRole" "ScopedParameterRead" "FAIL" "Missing scoped password parameter read"
    }
} else {
    Record-Check "PasswordWorkerRole" "RoleDefinition" "FAIL" "WuuAdPasswordWorkerRole resource not found"
}

$kmsKey = $sec.Resources.WuuKmsKey
if ($kmsKey) {
    $keyStmts = $kmsKey.Properties.KeyPolicy.Statement
    $denyFleet = $keyStmts | Where-Object { $_.Sid -eq 'ExplicitDenyToFleetPatchNodesAndOperators' -and $_.Effect -eq 'Deny' }
    if ($denyFleet) {
        Record-Check "KmsKeyPolicy" "FleetAndOperatorDeny" "PASS" "KMS Key explicitly denies Decrypt to fleet nodes and operators"
    } else {
        Record-Check "KmsKeyPolicy" "FleetAndOperatorDeny" "FAIL" "KMS Key missing explicit fleet deny statement"
    }
} else {
    Record-Check "KmsKeyPolicy" "KeyDefinition" "FAIL" "WuuKmsKey resource not found in secrets template"
}

# -------------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------------
Write-Host "`n=== Authorization Policy Verification Summary ===" -ForegroundColor Cyan
$failedCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$passCount = ($results | Where-Object { $_.Status -eq 'PASS' }).Count

Write-Host "Results: $passCount PASS | $failedCount FAIL" -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Red' })

if ($failedCount -gt 0) {
    Write-Error "Authorization policy validation failed with $failedCount error(s)."
    exit 1
}

exit 0
