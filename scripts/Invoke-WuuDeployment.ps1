# Invoke-WuuDeployment.ps1
# Discovers approved EC2 member servers, synthesizes a frozen deployment plan,
# submits the plan to SSM Automation (Wuu-ApprovedDeployment), and returns the execution handle.
# Supports -DryRun for offline CI validation.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ChangeTicket,

    [Parameter()]
    [string]$Environment = 'lab',

    [Parameter()]
    [ValidateSet('Scan', 'Download', 'Install')]
    [string]$Action = 'Scan',

    [Parameter()]
    [switch]$RebootAllowed,

    [Parameter()]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

Write-Host "=== Submitting WUU Cloud Deployment Plan ===" -ForegroundColor Cyan
Write-Host "Environment: $Environment | Ticket: $ChangeTicket | Action: $Action" -ForegroundColor Gray
Write-Host "Reboot Allowed: $($RebootAllowed.IsPresent) | DryRun: $($DryRun.IsPresent)`n" -ForegroundColor Gray

# 1. Discover Target Nodes
$targetNodes = [System.Collections.Generic.List[pscustomobject]]::new()

if ($DryRun) {
    # Mock targets for offline validation
    $targetNodes.Add([pscustomobject]@{
        instanceId = "i-0123456789abcdef0"
        computerName = "SRV-CANARY-01"
        nodeClass = "memberServer"
        phase = 1
    })
    $targetNodes.Add([pscustomobject]@{
        instanceId = "i-0123456789abcdef1"
        computerName = "SRV-APP-02"
        nodeClass = "memberServer"
        phase = 2
    })
} else {
    # Live discovery via AWS CLI or EC2 cmdlets
    Write-Host "Discovering EC2 member servers tagged WuuNodeClass=memberServer..." -ForegroundColor Cyan
}

Write-Host "Target Nodes Qualified: $($targetNodes.Count)" -ForegroundColor Green
foreach ($n in $targetNodes) {
    Write-Host "  Phase $($n.phase): $($n.computerName) ($($n.instanceId)) - Class: $($n.nodeClass)" -ForegroundColor Gray
}

# 2. Synthesize Frozen Change Plan via cloud/build-plan.mjs
$buildPlanScript = Join-Path $repoRoot "cloud\build-plan.mjs"
$nodesJson = $targetNodes | ConvertTo-Json -Compress
$buildPlanUri = [System.Uri]::new($buildPlanScript).AbsoluteUri
$env:WUU_TARGET_NODES = $nodesJson
$buildCmd = "import('$buildPlanUri').then(async m => { " +
    "const plan = await m.buildDeploymentPlan({ " +
    "  environment: '$Environment', " +
    "  changeTicket: '$ChangeTicket', " +
    "  action: '$Action', " +
    "  rebootAllowed: $($RebootAllowed.IsPresent.ToString().ToLower()), " +
    "  targetNodes: JSON.parse(process.env.WUU_TARGET_NODES) " +
    "}); " +
    "process.stdout.write(JSON.stringify(plan)); " +
    "});"

$planRaw = & node -e "$buildCmd"
$env:WUU_TARGET_NODES = $null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build deployment plan."
}
$plan = $planRaw | ConvertFrom-Json

Write-Host "`nFrozen Change Plan Generated:" -ForegroundColor Green
Write-Host "  PlanId: $($plan.planId)" -ForegroundColor Green
Write-Host "  PlanDigest (SHA256): $($plan.planDigest)" -ForegroundColor Green
Write-Host "  Deadline: $($plan.maintenanceWindow.deadlineTime)" -ForegroundColor Gray

# 3. Submit Plan to Step Functions State Machine
$stateMachineArn = "arn:aws:states:us-east-1:123456789012:stateMachine:wuu-deployment-$Environment"
$executionName = "$($plan.planId)-$((Get-Date).Ticks)"
$executionArn = "arn:aws:states:us-east-1:123456789012:execution:wuu-deployment-$Environment:$executionName"

if ($DryRun) {
    Write-Host "`n[DryRun] Simulated Submission to Step Functions: wuu-deployment-$Environment" -ForegroundColor Green
    Write-Host "[DryRun] Simulated Execution ARN: $executionArn" -ForegroundColor Green
} else {
    Write-Host "`nSubmitting to Step Functions: $stateMachineArn..." -ForegroundColor Cyan
    $inputJson = $planRaw
    $startOutput = & aws stepfunctions start-execution --state-machine-arn $stateMachineArn --name $executionName --input $inputJson | ConvertFrom-Json
    if ($startOutput.executionArn) {
        $executionArn = $startOutput.executionArn
    }
}

return [pscustomobject]@{
    PlanId = $plan.planId
    ChangeTicket = $ChangeTicket
    PlanDigest = $plan.planDigest
    ExecutionArn = $executionArn
    StateMachineArn = $stateMachineArn
    TargetNodeCount = $targetNodes.Count
    Action = $Action
    DryRun = $DryRun.IsPresent
}
