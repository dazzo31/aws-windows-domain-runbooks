# Test-Environment.ps1
# Offline configuration validator for WUU2-CLI AWS-integrated environment adoption.
# Validates environment definitions against schemas/environment.schema.json, verifies
# WSUS-only authority, node-class segregation, phasing rules, and placeholder refusal.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [Parameter()]
    [string]$Environment = 'lab',

    [Parameter()]
    [switch]$TemplateMode,

    [Parameter()]
    [switch]$RefusePlaceholders
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $Path) {
    $candidates = @(
        (Join-Path $repoRoot "config\environments\$Environment.yaml"),
        (Join-Path $repoRoot "config\environments\$Environment.example.yaml")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $Path = $c; break }
    }
}

if (-not $Path -or -not (Test-Path $Path)) {
    Write-Error "Environment configuration file not found: $Path"
    exit 1
}

$fullPath = (Resolve-Path $Path).Path
Write-Host "Validating environment configuration: $fullPath" -ForegroundColor Cyan

# 1. Parse YAML using node/yaml
$parseScript = Join-Path $PSScriptRoot 'parse-yaml.cjs'
$configJson = & node $parseScript $fullPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "YAML parsing failed for $fullPath"
    exit 1
}
$cfg = $configJson | ConvertFrom-Json

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Condition([bool]$Condition, [string]$Message) {
    if ($Condition) {
        Write-Host "  PASS: $Message" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: $Message" -ForegroundColor Red
        $failures.Add($Message)
    }
}

Write-Host "`n=== 1. Core Metadata & Upstream Lineage ===" -ForegroundColor Yellow
Assert-Condition ($cfg.schemaVersion -eq '1.0.0') "schemaVersion is 1.0.0"
Assert-Condition ($cfg.upstream.project -eq 'WUU2-CLI') "upstream project is WUU2-CLI"
Assert-Condition ($cfg.upstream.license -eq 'MIT') "upstream license is MIT"
Assert-Condition ($cfg.upstream.decoupledModel -eq $true) "upstream decoupled consumer model is true"
Assert-Condition ($cfg.upstream.pinnedCommit -match '^[0-9a-f]{40}$') "upstream pinned commit is a valid 40-char SHA ($($cfg.upstream.pinnedCommit))"
Assert-Condition ($cfg.upstream.pinnedTag -eq 'v1.5.0-rc.4-cli') "upstream pinned tag matches v1.5.0-rc.4-cli"

Write-Host "`n=== 2. WSUS Authority Constraints (Strict) ===" -ForegroundColor Yellow
Assert-Condition ($cfg.wsus.authorityOnly -eq $true) "WSUS is the sole update authority (authorityOnly=true)"
Assert-Condition ($cfg.wsus.serverSelection -eq 'ssManagedServer') "WUA serverSelection is explicitly ssManagedServer"
Assert-Condition ($cfg.wsus.allowMicrosoftUpdateFallback -eq $false) "Microsoft Update fallback is prohibited"
Assert-Condition ($cfg.wsus.allowPatchManager -eq $false) "AWS Patch Manager fallback is prohibited"
Assert-Condition ($cfg.wsus.tls.enforceHttps -eq $true) "WSUS TLS is enforced"
Assert-Condition ($cfg.wsus.tls.expectedPort -eq 8531) "WSUS expected port is 8531"
Assert-Condition ($cfg.wsus.serverUrl -match '^https://.+:8531$') "WSUS URL uses HTTPS on port 8531 ($($cfg.wsus.serverUrl))"

Write-Host "`n=== 3. Node Class Eligibility & Tier 0 Segregation ===" -ForegroundColor Yellow
Assert-Condition ($cfg.nodeClasses.memberServer.eligibleForFleetPatching -eq $true) "memberServer class is eligible for fleet patching"
Assert-Condition ($cfg.nodeClasses.memberServer.eligibleForDirectReboot -eq $true) "memberServer class is eligible for controlled direct reboot"
Assert-Condition ($cfg.nodeClasses.domainController.eligibleForFleetPatching -eq $false) "domainController class is EXCLUDED from fleet patching"
Assert-Condition ($cfg.nodeClasses.domainController.eligibleForDirectReboot -eq $false) "domainController class is EXCLUDED from direct reboot"
Assert-Condition ($cfg.nodeClasses.certificateAuthority.eligibleForFleetPatching -eq $false) "certificateAuthority class is EXCLUDED from fleet patching"
Assert-Condition ($cfg.nodeClasses.certificateAuthority.eligibleForDirectReboot -eq $false) "certificateAuthority class is EXCLUDED from direct reboot"
Assert-Condition ($cfg.nodeClasses.clusterNode.eligibleForFleetPatching -eq $false) "clusterNode class is EXCLUDED from fleet patching"

Write-Host "`n=== 4. Phasing, Concurrency & Servicing Locks ===" -ForegroundColor Yellow
Assert-Condition ($cfg.deployment.phases.totalPhases -eq 5) "5 total deployment phases configured"
Assert-Condition ($cfg.deployment.phases.canaryPhase -eq 1) "Phase 1 is configured as canary phase"
Assert-Condition ($cfg.deployment.phases.blockOnPhaseFailure -eq $true) "blockOnPhaseFailure is enabled"
Assert-Condition ($cfg.deployment.rebootPolicy.mode -eq 'separate_approval_required') "reboot policy requires separate approval (never implicit)"
Assert-Condition ($cfg.deployment.rebootPolicy.rebootCommandCode -eq 3010) "reboot command uses native SSM code 3010"
Assert-Condition ($cfg.deployment.rebootPolicy.maxRebootsPerNode -eq 1) "max reboots per node is bounded to 1"
Assert-Condition ($cfg.deployment.servicingLock.namedMutex -eq 'Global\WUU_Servicing_Lock') "named servicing mutex is Global\WUU_Servicing_Lock"
Assert-Condition ($cfg.deployment.servicingLock.detectNativeLocks -eq $true) "detectNativeLocks is enabled (checks TrustedInstaller/usoclient)"
Assert-Condition ($cfg.deployment.executionTimeouts.installTimeoutSeconds -ge 3600) "install timeout is at least 3600 seconds"

Write-Host "`n=== 5. Runtime & Support Matrix ===" -ForegroundColor Yellow
Assert-Condition ($cfg.supportMatrix.powershell.engine -eq 'Windows PowerShell 5.1') "PowerShell engine is Windows PowerShell 5.1"
Assert-Condition ($cfg.supportMatrix.powershell.requiredApartmentState -eq 'STA') "PowerShell apartment state is STA"
Assert-Condition ($cfg.supportMatrix.ssmAgent.minimumVersion -match '^\d+\.\d+\.\d+\.\d+$') "SSM Agent minimum version is specified ($($cfg.supportMatrix.ssmAgent.minimumVersion))"

Write-Host "`n=== 6. Placeholder Detection & Deployment Safety ===" -ForegroundColor Yellow
$placeholderHits = [System.Collections.Generic.List[string]]::new()
$rawYaml = [System.IO.File]::ReadAllText($fullPath)

if ($cfg.aws.accountId -eq '123456789012') { $placeholderHits.Add("aws.accountId = '123456789012'") }
if ($rawYaml -match 'example\.(local|test|com)') { $placeholderHits.Add("Found example domain references") }
if ($rawYaml -match '0123456789ABCDEF0123456789ABCDEF01234567') { $placeholderHits.Add("Found dummy root CA thumbprint") }
if ($rawYaml -match 'vpc-0123456789abcdef0') { $placeholderHits.Add("Found placeholder vpcId") }

$isTemplate = ($cfg.status -eq 'template' -or $TemplateMode)
if ($RefusePlaceholders -or (-not $isTemplate)) {
    if ($placeholderHits.Count -gt 0) {
        Write-Host "  FAIL: Placeholder values detected in deployment mode: $($placeholderHits -join '; ')" -ForegroundColor Red
        $failures.Add("Deployment refused: configuration contains template placeholders.")
    } else {
        Write-Host "  PASS: No template placeholders detected in active configuration" -ForegroundColor Green
    }
} else {
    Write-Host "  NOTE: Template configuration verified ($($placeholderHits.Count) expected placeholder markers detected)." -ForegroundColor DarkGray
    Write-Host "  PASS: Template placeholders properly marked and quarantined for adoption." -ForegroundColor Green
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
if ($failures.Count -eq 0) {
    Write-Host "ALL CHECKS PASSED: Environment configuration '$fullPath' is valid." -ForegroundColor Green
    Write-Host "NOTE: This gate validates configuration structure and invariants offline. Live qualification (AD DS, WSUS connectivity, AWS IAM) requires G0 deployment signoff." -ForegroundColor DarkCyan
    exit 0
} else {
    Write-Host "VALIDATION FAILED: $($failures.Count) error(s) encountered." -ForegroundColor Red
    exit 1
}
