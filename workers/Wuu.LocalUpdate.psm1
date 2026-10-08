# Wuu.LocalUpdate.psm1
# Local Windows Update Agent (WUA) COM automation module for noninteractive execution.
# Extracted from WUU2-CLI local worker scripts with remote-dispatch and process-exits removed.
#
# Attribution:
# Derived from WUU / WUU2-CLI (https://github.com/dazzo31/WUU2-CLI)
# Original authors: Boe Prox, Tyler Siegrist, HanSolo71, dazzo31.
# Licensed under the MIT License.
#
# Invariants:
# 1. Enforces WSUS as update source: sets ServerSelection = 2 (ssManagedServer).
# 2. Revalidates update GUID and revision against approved selection manifest.
# 3. Requires explicit EULA approval policy; never unconditionally auto-accepts EULAs.
# 4. Reports native ResultCode and HRESULTs; never returns update counts as exit codes.

$ErrorActionPreference = 'Stop'

function Get-WuuUpdateSession {
    return New-Object -ComObject 'Microsoft.Update.Session'
}

function Search-WuuUpdates {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Criteria = "IsInstalled=0 and IsHidden=0",

        [Parameter()]
        [array]$ApprovedSelection = @()
    )

    $session = Get-WuuUpdateSession
    $searcher = $session.CreateUpdateSearcher()

    # Enforce managed WSUS source: ServerSelection = 2 (ssManagedServer)
    $searcher.ServerSelection = 2

    Write-Verbose "Querying WUA with Criteria: $Criteria (ServerSelection=2 ssManagedServer)"
    $searchResult = $searcher.Search($Criteria)

    $approvedList = [System.Collections.Generic.List[pscustomobject]]::new()
    $approvedMap = @{}
    foreach ($app in $ApprovedSelection) {
        $approvedMap[$app.updateId.ToLowerInvariant()] = $app
    }

    foreach ($update in $searchResult.Updates) {
        $id = $update.Identity.UpdateID.ToLowerInvariant()
        $rev = $update.Identity.RevisionNumber

        # If an approved selection list is provided, filter and bind
        if ($ApprovedSelection.Count -gt 0) {
            if (-not $approvedMap.ContainsKey($id)) {
                Write-Verbose "Skipping unapproved update: $($update.Title) ($id)"
                continue
            }
            $expected = $approvedMap[$id]
            if ($expected.revisionNumber -and ($rev -ne $expected.revisionNumber)) {
                Write-Warning "Revision mismatch for update $($id): expected $($expected.revisionNumber), found $rev. Skipping."
                continue
            }
        }

        $approvedList.Add([pscustomobject]@{
            UpdateObject = $update
            UpdateId = $id
            RevisionNumber = $rev
            Title = $update.Title
            IsDownloaded = $update.IsDownloaded
            KbArticleId = if ($update.KBArticleIDs.Count -gt 0) { "KB" + $update.KBArticleIDs[0] } else { $null }
            EulaAccepted = $update.EulaAccepted
        })
    }

    return $approvedList
}

function Download-WuuUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$UpdatesToDownload
    )

    $session = Get-WuuUpdateSession
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($item in $UpdatesToDownload) {
        $update = $item.UpdateObject
        Write-Verbose "Downloading update: $($update.Title)"

        $coll = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        [void]$coll.Add($update)

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $coll

        $dlResult = $downloader.Download()
        $unitResult = $dlResult.GetUpdateResult(0)
        $code = $unitResult.ResultCode
        $hresult = "0x{0:X8}" -f $unitResult.HResult

        $status = switch ($code) {
            2 { "SUCCEEDED" }
            3 { "PARTIAL" }
            default { "FAILED" }
        }

        $results.Add([pscustomobject]@{
            updateId = $item.UpdateId
            revisionNumber = $item.RevisionNumber
            title = $item.Title
            kbArticleId = $item.KbArticleId
            resultCode = $code
            hresult = $hresult
            status = $status
        })
    }

    return $results
}

function Install-WuuUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$UpdatesToInstall,

        [Parameter()]
        [bool]$AllowEulaAcceptance = $false
    )

    $session = Get-WuuUpdateSession
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $anyRebootRequired = $false

    foreach ($item in $UpdatesToInstall) {
        $update = $item.UpdateObject

        if ($update.InstallationBehavior.CanRequestUserInput) {
            Write-Warning "Skipping interactive update: $($update.Title)"
            $results.Add([pscustomobject]@{
                updateId = $item.UpdateId
                revisionNumber = $item.RevisionNumber
                title = $item.Title
                kbArticleId = $item.KbArticleId
                resultCode = 0
                hresult = "0x00000000"
                status = "SKIPPED"
            })
            continue
        }

        if (-not $update.EulaAccepted) {
            if ($AllowEulaAcceptance) {
                Write-Verbose "Accepting EULA per approved policy for: $($update.Title)"
                $update.AcceptEula()
            } else {
                Write-Warning "EULA not accepted and AllowEulaAcceptance is false for: $($update.Title). Refusing install."
                $results.Add([pscustomobject]@{
                    updateId = $item.UpdateId
                    revisionNumber = $item.RevisionNumber
                    title = $item.Title
                    kbArticleId = $item.KbArticleId
                    resultCode = 0
                    hresult = "0x80240020"
                    status = "FAILED"
                })
                continue
            }
        }

        $coll = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        [void]$coll.Add($update)

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $coll

        $instResult = $installer.Install()
        $unitResult = $instResult.GetUpdateResult(0)
        $code = $unitResult.ResultCode
        $hresult = "0x{0:X8}" -f $unitResult.HResult

        if ($instResult.RebootRequired) { $anyRebootRequired = $true }

        $status = switch ($code) {
            2 { "SUCCEEDED" }
            3 { "PARTIAL" }
            default { "FAILED" }
        }

        $results.Add([pscustomobject]@{
            updateId = $item.UpdateId
            revisionNumber = $item.RevisionNumber
            title = $item.Title
            kbArticleId = $item.KbArticleId
            resultCode = $code
            hresult = $hresult
            status = $status
        })
    }

    # Inspect SystemInfo COM interface for pending reboot
    try {
        if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired) {
            $anyRebootRequired = $true
        }
    } catch {}

    return [pscustomobject]@{
        UpdateOutcomes = $results
        RebootRequired = $anyRebootRequired
    }
}

Export-ModuleMember -Function Get-WuuUpdateSession, Search-WuuUpdates, Download-WuuUpdates, Install-WuuUpdates
