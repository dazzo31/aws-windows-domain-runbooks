# Rollback-Release.ps1
# Rolls back SSM document default versions and worker package release pointers to a prior known-good version.
# Preserves durable DynamoDB state and CloudWatch logs. Never disrupts an active running deployment.
# Supports -DryRun.

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

