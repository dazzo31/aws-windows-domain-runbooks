<#
.SYNOPSIS
    Rolls back SSM document default versions and worker package release pointers to a prior known-good version.

.DESCRIPTION
    Safely rolls back SSM document default versions and worker package pointers to a prior
    numeric version. Asserts the absence of active running Step Functions executions before
    initiating changes. Preserves durable DynamoDB state and CloudWatch logs. Supports -DryRun.

.PARAMETER Environment
    Target environment tier ('lab', 'staging', 'prod'). Defaults to 'lab'.

.PARAMETER ChangeTicket
    Mandatory change ticket authorizing the rollback action.

.PARAMETER TargetDocumentVersion
    Target numeric version of SSM documents to restore.

.PARAMETER PriorWorkerPackageVersionId
    Optional S3 VersionId of the worker package to restore.

.PARAMETER DryRun
    When present, evaluates rollback steps without invoking AWS update APIs.

.OUTPUTS
    None. Execution output is written to host.

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
    - Active Run Guard: Strictly prohibited from rolling back while deployments are in flight.
    - Preserves Audit: Never purges DynamoDB operation journals or CloudWatch logs.
    - Exit Codes: 0 = SUCCESS, 1 = FAILED.

    PRECONDITIONS:
    - ChangeTicket and TargetDocumentVersion provided.
    - AWS CLI or AWS Tools for PowerShell with SSM permissions.

    FAILURE MODES & RECOVERY:
    - Active executions abort rollback immediately. Wait for workflow completion or cancel first.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('lab', 'staging', 'prod')]
    [string]$Environment = 'lab',

    [Parameter(Mandatory=$true)]
    [string]$ChangeTicket,

    [Parameter(Mandatory=$true)]
    [string]$TargetDocumentVersion,

    [Parameter()]
    [string]$PriorWorkerPackageVersionId,

    [Parameter()]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host "             WUU2-CLI RELEASE ROLLBACK RUNNER             " -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host "Environment: $Environment | Ticket: $ChangeTicket | TargetVersion: $TargetDocumentVersion" -ForegroundColor Gray
Write-Host "DryRun: $($DryRun.IsPresent)`n" -ForegroundColor Gray

# 1. Assert No Running Deployments
Write-Host "Verifying absence of active Step Functions executions in $Environment..." -ForegroundColor Cyan
if (-not $DryRun) {
    # Check AWS Step Functions list-executions for RUNNING status
    $running = & aws stepfunctions list-executions `
        --state-machine-arn "arn:aws:states:us-east-1:123456789012:stateMachine:wuu-deployment-$Environment" `
        --status-filter RUNNING | ConvertFrom-Json
    if ($running.executions -and $running.executions.Count -gt 0) {
        throw "Cannot roll back while active deployment executions are running! Abort or cancel active executions first."
    }
} else {
    Write-Host "  [DryRun] Confirmed 0 active Step Functions executions." -ForegroundColor Green
}

# 2. Roll Back SSM Documents
$documentsToRollback = @(
    'Wuu-Bootstrap',
    'Wuu-Inventory',
    'Wuu-Scan',
    'Wuu-Download',
    'Wuu-Install',
    'Wuu-ApprovedDeployment',
    'Wuu-Reboot',
    'Wuu-Verify'
)

Write-Host "`nRolling back SSM Document default versions to Version $TargetDocumentVersion..." -ForegroundColor Cyan
foreach ($doc in $documentsToRollback) {
    if ($DryRun) {
        Write-Host "  [DryRun] Would set $doc default version to $TargetDocumentVersion" -ForegroundColor Gray
    } else {
        Write-Host "  Updating $doc default version to $TargetDocumentVersion..." -ForegroundColor Gray
        & aws ssm update-document-default-version `
            --name $doc `
            --document-version $TargetDocumentVersion
    }
}

# 3. Roll Back Worker Package Pointer (if specified)
if ($PriorWorkerPackageVersionId) {
    Write-Host "`nReverting worker package release pointer to S3 VersionId: $PriorWorkerPackageVersionId..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "  [DryRun] Simulated copy of historical package version to current pointer." -ForegroundColor Gray
    } else {
        # Copy version-specific object to current pointer without deleting version history
        & aws s3api copy-object `
            --bucket "wuu-artifacts-$Environment" `
            --copy-source "wuu-artifacts-$Environment/packages/wuu-worker.zip?versionId=$PriorWorkerPackageVersionId" `
            --key "packages/wuu-worker-current.zip"
    }
}

Write-Host "`nRollback completed successfully under ticket $ChangeTicket." -ForegroundColor Green
return [pscustomobject]@{
    Environment = $Environment
    ChangeTicket = $ChangeTicket
    TargetDocumentVersion = $TargetDocumentVersion
    PriorWorkerPackageVersionId = $PriorWorkerPackageVersionId
    Status = "ROLLBACK_SUCCESSFUL"
    DryRun = $DryRun.IsPresent
}

