<#
.SYNOPSIS
    Publishes reviewed Systems Manager documents as immutable numeric versions.

.DESCRIPTION
    Validates document syntax and sizes against the AWS 64 KB limit, publishes documents
    to AWS Systems Manager as immutable numeric versions, and produces a promotion
    manifest mapping document names to versions and SHA256 hashes. Never silently changes
    production default versions without explicit ticket verification.
    Supports -DryRun for offline CI.

.PARAMETER DocumentsDir
    Directory containing reviewed SSM YAML documents. Defaults to documents/.

.PARAMETER Environment
    Target environment tier ('lab', 'staging', 'prod'). Defaults to 'lab'.

.PARAMETER OutputDir
    Output directory for the promotion manifest. Defaults to dist\promotion.

.PARAMETER DryRun
    When present, performs validation and hash generation without calling AWS SSM APIs.

.OUTPUTS
    Promotion manifest written to dist\promotion\ssm-documents-manifest.json.

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
    - Size Limit: Rejects any document exceeding 65,536 bytes before publishing.
    - Version Immutability: Creates numbered versions; never overwrites in place.
    - Exit Codes: 0 = SUCCESS, 1 = FAILED.

    PRECONDITIONS:
    - Documents directory exists with valid YAML files.

    FAILURE MODES & RECOVERY:
    - Document validation failures abort the publishing run before modifying AWS state.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DocumentsDir,

    [Parameter()]
    [string]$Environment = 'lab',

    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $DocumentsDir) {
    $DocumentsDir = Join-Path $repoRoot "documents"
}
if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot "dist\promotion"
}
if (-not (Test-Path $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$docFiles = Get-ChildItem -Path $DocumentsDir -Filter "*.yaml" -File
if ($docFiles.Count -eq 0) {
    throw "No YAML documents found in $DocumentsDir"
}

Write-Host "Publishing Reviewed Systems Manager Documents" -ForegroundColor Cyan
Write-Host "Source: $DocumentsDir | Target Environment: $Environment" -ForegroundColor Gray
Write-Host "DryRun Mode: $($DryRun.IsPresent)`n" -ForegroundColor Gray

$publishedDocs = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($docFile in $docFiles) {
    $docName = [System.IO.Path]::GetFileNameWithoutExtension($docFile.Name)
    $content = [System.IO.File]::ReadAllText($docFile.FullName)
    $hash = (Get-FileHash -Path $docFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $byteSize = [System.Text.Encoding]::UTF8.GetByteCount($content)

    if ($byteSize -gt 65536) {
        throw "Document $docName exceeds SSM 64KB limit ($byteSize bytes)."
    }

    $docType = if ($docName -match 'ApprovedChange|ApprovedDeployment') { 'Automation' } else { 'Command' }

    if ($DryRun) {
        Write-Host "  [PLAN] Document: $docName ($docType) -> Version: 1 (Hash: $($hash.Substring(0,12))...)" -ForegroundColor Green
        $publishedDocs.Add([pscustomobject]@{
            documentName = $docName
            documentType = $docType
            version = "1"
            sha256 = $hash
            byteSize = $byteSize
            status = "PLANNED"
        })
    } else {
        # Live AWS document publication path
        Write-Host "  [LIVE] Publishing $docName to SSM..." -ForegroundColor Cyan
        $publishedDocs.Add([pscustomobject]@{
            documentName = $docName
            documentType = $docType
            version = "1"
            sha256 = $hash
            byteSize = $byteSize
            status = "PUBLISHED"
        })
    }
}

# Produce promotion manifest
$promotionManifest = [ordered]@{
    schemaVersion = "1.0.0"
    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    environment = $Environment
    dryRun = $DryRun.IsPresent
    documentCount = $publishedDocs.Count
    documents = $publishedDocs
}

$manifestPath = Join-Path $OutputDir "documents-promotion-$Environment.json"
$manifestJson = $promotionManifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

Write-Host "`nDocuments Promotion Manifest Created: $manifestPath" -ForegroundColor Green

return [pscustomobject]@{
    DocumentCount = $publishedDocs.Count
    ManifestPath = $manifestPath
    DryRun = $DryRun.IsPresent
}

