#Requires -Version 5.1

<#
.SYNOPSIS
    Remove directory junctions / symbolic links that block OneDrive
    "Back up folders" (Known Folder Move) from the OneDrive-synced PowerShell
    module folders, so the OneDrive account can be (re-)registered and folder
    backup completes without the
    "<name> ... is a directory junction or symlink and can't be backed up" error.

.DESCRIPTION
    OneDrive folder backup refuses to back up ANY reparse point. Tools that
    "link" a module into the user module path (for example an older
    module/Install-Module.ps1 that junctioned MarkMichaelis.ScoopBucket into
    Documents\PowerShell\Modules) leave a directory junction under the
    OneDrive-redirected Documents folder, which permanently breaks backup.

    This script reproduces the manual cleanup that unblocks OneDrive:

      1. Locate the OneDrive-redirected Documents folder (via the Personal /
         MyDocuments known folder, which KFM repoints into OneDrive).
      2. Enumerate the PowerShell module folders under it
         (PowerShell\Modules and WindowsPowerShell\Modules).
      3. Find entries that are REAL junctions or symbolic links. OneDrive
         Files-On-Demand placeholders are also reparse points, so they are
         excluded by checking LinkType (Junction / SymbolicLink) -- cloud
         placeholders report a null LinkType and are never touched.
      4. Remove each link SAFELY: strip the ReadOnly attribute then call
         [System.IO.Directory]::Delete($link, $false) (non-recursive) so the
         link itself is deleted without ever following the reparse point into
         -- and deleting the contents of -- its target.

    After it finishes, re-run OneDrive "Back up folders" (or sign the account
    back in); backup should now succeed.

    Supports -WhatIf and -Confirm. Use -ListOnly to preview without changing
    anything. Removing files is not destructive to the link targets.

.PARAMETER Path
    Folders to scan. Defaults to the OneDrive Documents PowerShell module
    folders. Pass explicit paths to scan elsewhere (e.g. a different
    OneDrive-synced location).

.PARAMETER All
    Remove every junction/symlink found, including ones whose target is an
    existing, non-repo folder. By default repo-pointing links and dangling
    links (target no longer exists) are removed; a link to another live
    non-repo location is reported but left in place unless -All is supplied.

.PARAMETER ListOnly
    Report the discovered junctions/symlinks and exit without removing them.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    PSCustomObject for each junction/symlink found, with Path, LinkType,
    Target, PointsToGitRepo and Action (Removed / Skipped / WouldRemove).

.EXAMPLE
    .\Reset-OneDriveModuleJunction.ps1 -ListOnly

    Show every backup-blocking junction/symlink under the OneDrive module
    folders without changing anything.

.EXAMPLE
    .\Reset-OneDriveModuleJunction.ps1

    Remove repo-pointing junctions (the common case: the legacy scoop module
    junction) after a confirmation prompt, then re-run OneDrive backup.

.EXAMPLE
    .\Reset-OneDriveModuleJunction.ps1 -All -Confirm:$false

    Remove ALL junctions/symlinks found, no prompt. Use with care.

.NOTES
    Root cause and the permanent fix (registering the module via PSModulePath
    instead of a junction) are tracked in MarkMichaelis/ScoopBucket #375.
    For the scoop module specifically, the supported reinstall is
    module/Install-Module.ps1, which no longer creates a junction.

    Detecting real links vs. Files-On-Demand placeholders: `dir /al` lists both;
    the programmatic discriminator used here is Get-Item ... .LinkType, which is
    'Junction' or 'SymbolicLink' only for genuine links.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # One or more folders to scan for backup-blocking junctions/symlinks.
    # Defaults to the PowerShell module folders under the OneDrive-redirected
    # Documents folder (both PowerShell 7 and Windows PowerShell 5.1).
    [Parameter()]
    [string[]]$Path,

    # Also remove junctions/symlinks whose target is an existing, non-repo
    # location. By default repo-pointing links AND dangling links (target
    # missing) are removed; -All also removes links to other live folders.
    [Parameter()]
    [switch]$All,

    # Emit the discovered junction/symlink objects without removing anything.
    # Equivalent to -WhatIf but returns structured objects for inspection.
    [Parameter()]
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'

function Get-DefaultModulePath {
    <#
    .SYNOPSIS
        Resolve the OneDrive-redirected PowerShell module folders to scan.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::Personal)
    if (-not $documents) {
        $documents = Join-Path $HOME 'Documents'
    }

    @(
        (Join-Path $documents 'PowerShell\Modules')
        (Join-Path $documents 'WindowsPowerShell\Modules')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
}

function Test-TargetIsGitRepo {
    <#
    .SYNOPSIS
        Return $true when a link target resolves into a Git working tree.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Target)

    if (-not $Target) { return $false }
    try {
        $resolved = (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path
    } catch {
        return $false
    }

    $dir = Get-Item -LiteralPath $resolved -ErrorAction SilentlyContinue
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName '.git')) { return $true }
        $dir = $dir.Parent
    }
    return $false
}

$scanPaths = if ($PSBoundParameters.ContainsKey('Path') -and $Path) { $Path } else { Get-DefaultModulePath }

if (-not $scanPaths) {
    Write-Warning 'No PowerShell module folders found under the OneDrive Documents path. Nothing to scan.'
    Write-Host 'If your Documents folder is not OneDrive-redirected, pass -Path explicitly.'
    return
}

Write-Host 'Scanning for OneDrive backup-blocking junctions / symlinks:'
$scanPaths | ForEach-Object { Write-Host "  $_" }

$results = foreach ($root in $scanPaths) {
    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $item = $_
        # Real junction/symlink only. Cloud (Files-On-Demand) placeholders are
        # also ReparsePoints but report a null LinkType, so they are skipped.
        if ($item.LinkType -notin @('Junction', 'SymbolicLink')) { return }

        $target = $item.Target | Select-Object -First 1
        $pointsToRepo = Test-TargetIsGitRepo -Target $target
        $targetExists = [bool]($target -and (Test-Path -LiteralPath $target))
        # A dangling link (its target is gone) is always worthless and always
        # blocks OneDrive backup, so it is removable by default alongside
        # repo-pointing links. -All additionally removes links to other
        # existing, non-repo locations.
        $removable = $pointsToRepo -or (-not $targetExists) -or $All
        $action = 'Skipped'

        if ($ListOnly) {
            $action = 'Listed'
        } elseif ($removable) {
            if ($PSCmdlet.ShouldProcess($item.FullName, "Remove $($item.LinkType) -> $target")) {
                try {
                    if (($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                        $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                    }
                    # Non-recursive: deletes the link only, never follows the
                    # reparse point into the (possibly read-only) target.
                    [System.IO.Directory]::Delete($item.FullName, $false)
                    $action = 'Removed'
                } catch {
                    $action = "Failed: $($_.Exception.Message)"
                }
            } else {
                $action = 'WouldRemove'
            }
        } else {
            Write-Warning "Link at $($item.FullName) points to an existing non-repo target; leaving it. Pass -All to remove anyway."
        }

        [PSCustomObject]@{
            Path            = $item.FullName
            LinkType        = $item.LinkType
            Target          = $target
            TargetExists    = $targetExists
            PointsToGitRepo = $pointsToRepo
            Action          = $action
        }
    }
}

$results = @($results)

if (-not $results) {
    Write-Host 'No junctions or symbolic links found. OneDrive folder backup is not blocked by reparse points here.'
    return $results
}

$removed = @($results | Where-Object Action -eq 'Removed').Count
Write-Host ''
Write-Host "Found $($results.Count) junction/symlink(s); removed $removed."
if ($removed -gt 0) {
    Write-Host 'Next: re-run OneDrive "Back up folders" (or sign the account back in). Backup should now succeed.'
}

return $results
