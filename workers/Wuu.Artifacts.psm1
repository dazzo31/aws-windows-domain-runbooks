# Wuu.Artifacts.psm1
# Local node worker artifact verification, secure extraction, and integrity management.
# Enforces cryptographic SHA256 verification, anti-path-traversal, anti-junction security,
# and rollback to known-good worker packages. PowerShell 5.1 native syntax.

$ErrorActionPreference = 'Stop'

function Test-WuuReparsePoint {
    param([string]$Path)
    if (Test-Path $Path) {
        $item = Get-Item $Path
        return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
    return $false
}

function Expand-WuuWorkerPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ZipFilePath,

        [Parameter(Mandatory=$true)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory=$true)]
        [string]$TargetDirectory,

        [Parameter()]
        [switch]$Force
    )

    if (-not (Test-Path $ZipFilePath)) {
        throw "Worker package zip file not found: $ZipFilePath"
    }

    # 1. Cryptographic Hash Validation
    $actualHash = (Get-FileHash -Path $ZipFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "Package integrity failure: expected SHA256 $ExpectedSha256, but found $actualHash"
    }

    # 2. Target Directory Anti-Junction / Reparse Point Check
    if (Test-WuuReparsePoint $TargetDirectory) {
        throw "Security violation: target directory $TargetDirectory is a junction point or symlink."
    }

    if (-not (Test-Path $TargetDirectory)) {
        $null = New-Item -ItemType Directory -Path $TargetDirectory -Force
    }

    $canonicalTarget = (Resolve-Path $TargetDirectory).Path.TrimEnd('\', '/')

    # 3. Safe Extraction with Path Traversal Protection
    Add-Type -AssemblyName "System.IO.Compression.FileSystem"
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipFilePath)
    try {
        foreach ($entry in $zip.Entries) {
            # Normalize path and check for traversal (e.g. ../ or absolute drives)
            $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $canonicalTarget $entry.FullName))
            if (-not $destinationPath.StartsWith($canonicalTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Security violation: Zip slip path traversal attempt detected ($($entry.FullName))."
            }

            if ([string]::IsNullOrEmpty($entry.Name)) {
                # Directory entry
                if (-not (Test-Path $destinationPath)) {
                    $null = New-Item -ItemType Directory -Path $destinationPath -Force
                }
                if (Test-WuuReparsePoint $destinationPath) {
                    throw "Security violation: extracted directory $destinationPath is a reparse point."
                }
            } else {
                # File entry
                $parentDir = [System.IO.Path]::GetDirectoryName($destinationPath)
                if (-not (Test-Path $parentDir)) {
                    $null = New-Item -ItemType Directory -Path $parentDir -Force
                }
                if (Test-WuuReparsePoint $parentDir) {
                    throw "Security violation: parent directory $parentDir is a reparse point."
                }

                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destinationPath, $true)
            }
        }
    } finally {
        $zip.Dispose()
    }

    # 4. Set Protected Non-Inherited ACLs (SYSTEM and Administrators Only)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544',
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]'S-1-5-18',
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    Set-Acl -Path $canonicalTarget -AclObject $acl

    Write-Verbose "Extracted and secured worker package at $canonicalTarget"
    return $canonicalTarget
}

function Test-WuuWorkerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkerDirectory,

        [Parameter(Mandatory=$true)]
        [array]$ExpectedContents
    )

    if (-not (Test-Path $WorkerDirectory)) { return $false }

    foreach ($item in $ExpectedContents) {
        $filePath = Join-Path $WorkerDirectory $item.relativePath
        if (-not (Test-Path $filePath)) { return $false }
        $hash = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $item.sha256.ToLowerInvariant()) { return $false }
    }
    return $true
}

Export-ModuleMember -Function Test-WuuReparsePoint, Expand-WuuWorkerPackage, Test-WuuWorkerIntegrity

