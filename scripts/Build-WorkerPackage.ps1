# Build-WorkerPackage.ps1
# Packages local WUU worker modules into an immutable, versioned, attributed ZIP artifact.
# Computes cryptographic SHA256 hashes and generates release-manifest.json conforming
# to schemas/release-manifest.schema.json. Strict exclusion of credentials and secrets.

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Environment = 'lab',

    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot "dist\packages"
}
if (-not (Test-Path $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$workersSourceDir = Join-Path $repoRoot "workers"
if (-not (Test-Path $workersSourceDir)) {
    $null = New-Item -ItemType Directory -Path $workersSourceDir -Force
}

# Upstream pinned metadata (Decoupled Consumer Model)
$upstreamProject = "WUU2-CLI"
$pinnedCommit = "e81b620905d549783d7e17498a0b3cbbcf5f4095"
$pinnedTag = "v1.5.0-rc.4-cli"
$license = "MIT"

$releaseTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
$releaseId = "rel-$releaseTimestamp"
$packageName = "wuu-worker-package-$Environment.zip"
$packageZipPath = Join-Path $OutputDir $packageName

Write-Host "Building Immutable WUU Worker Package" -ForegroundColor Cyan
Write-Host "Release ID: $releaseId | Environment: $Environment" -ForegroundColor Gray
Write-Host "Workers Source: $workersSourceDir" -ForegroundColor Gray
Write-Host "Output: $packageZipPath" -ForegroundColor Gray

# Ensure staging directory
$stagingDir = Join-Path $OutputDir "staging-$releaseId"
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
$null = New-Item -ItemType Directory -Path $stagingDir -Force

# Gather worker files
$workerFiles = Get-ChildItem -Path $workersSourceDir -Recurse -File

# If workers directory is empty in early plan phase, create starter attribution notice
if ($workerFiles.Count -eq 0) {
    $noticePath = Join-Path $workersSourceDir "NOTICE.txt"
    "WUU2-CLI Local Worker Package - Upstream commit: $pinnedCommit (MIT License)" | Set-Content $noticePath -Encoding utf8
    $workerFiles = Get-ChildItem -Path $workersSourceDir -Recurse -File
}

$contentsManifest = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($f in $workerFiles) {
    # Secret / Credential sanity check: strictly exclude configs with secrets
    $relPath = $f.FullName.Substring($workersSourceDir.Length).TrimStart('\', '/')
    if ($relPath -match 'password|secret|credential|\.key|\.pem') {
        throw "Security violation: Worker package must not contain credentials or secret files ($relPath)."
    }

    $destPath = Join-Path $stagingDir $relPath
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) { $null = New-Item -ItemType Directory -Path $destDir -Force }
    Copy-Item $f.FullName -Destination $destPath -Force

    $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $contentsManifest.Add([pscustomobject]@{
        relativePath = $relPath.Replace('\', '/')
        sha256 = $hash
        sizeBytes = [int]$f.Length
    })
}

# Create ZIP archive using .NET Framework 4.5+ ZipFile API compatible with PS 5.1
if (Test-Path $packageZipPath) { Remove-Item $packageZipPath -Force }
Add-Type -AssemblyName "System.IO.Compression.FileSystem"
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $packageZipPath)

$packageHash = (Get-FileHash -Path $packageZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$packageSize = (Get-Item $packageZipPath).Length

# Generate release manifest
$manifest = [ordered]@{
    schemaVersion = "1.0.0"
    releaseId = $releaseId
    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    upstream = [ordered]@{
        project = $upstreamProject
        pinnedCommit = $pinnedCommit
        pinnedTag = $pinnedTag
        license = $license
    }
    package = [ordered]@{
        fileName = $packageName
        sha256 = $packageHash
        sizeBytes = [int]$packageSize
    }
    contents = $contentsManifest
    environment = $Environment
}

$manifestPath = Join-Path $OutputDir "release-manifest.json"
$manifestJson = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

# Cleanup staging
Remove-Item $stagingDir -Recurse -Force

Write-Host "`nWorker Package Built Successfully!" -ForegroundColor Green
Write-Host "  Zip: $packageZipPath ($packageSize bytes, SHA256: $packageHash)" -ForegroundColor Green
Write-Host "  Manifest: $manifestPath" -ForegroundColor Green

return [pscustomobject]@{
    ReleaseId = $releaseId
    PackagePath = $packageZipPath
    ManifestPath = $manifestPath
    Sha256 = $packageHash
}
