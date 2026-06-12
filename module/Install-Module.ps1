[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    # By default the installer also adds a sentinel-bracketed lazy-import
    # stub block (v3) to $PROFILE.CurrentUserAllHosts so the
    # `Install-Package -Name <Tab>` argument completer fires on the
    # first keystroke without paying the ~1 s `Import-Module` cost on
    # every shell start. The v3 block also prepends this repo's module dir
    # to $env:PSModulePath. Pass -SkipProfile to make registration
    # session-only (no profile / no persistence).
    [switch]$SkipProfile,

    # Reverse a previous install: remove the sentinel-bracketed v1/v2/v3
    # block from $PROFILE.CurrentUserAllHosts AND remove any legacy
    # PSModulePath junction (only if it points back to this repo).
    # After -Uninstall, use the module by `cd`-ing here and running
    # `Import-Module .\module\MarkMichaelis.ScoopBucket`. See #251.
    [switch]$Uninstall
)

<#
.SYNOPSIS
    Make the MarkMichaelis.ScoopBucket module discoverable on the current
    user's PSModulePath so `Import-Module MarkMichaelis.ScoopBucket` (and
    auto-loading of `Install-Package`, `Get-Package`,
    `Invoke-PackageInstall`) works from any profile-loaded PowerShell
    session on this machine. Also writes a lazy-import stub block to
    $PROFILE so Tab completion for `-Name` works on the very first
    keystroke without eagerly loading the module on every shell start.

.DESCRIPTION
    Registers this repo's module/ directory on PSModulePath via the
    $PROFILE.CurrentUserAllHosts sentinel block (no junction, no reparse
    point under the user's -- often OneDrive-synced -- module path, #375).
    Earlier versions junctioned the module under the user module path,
    which broke OneDrive folder backup; this installer removes any such
    legacy self-pointing junction it finds (transitional, see #376).

    Unless -SkipProfile is passed, writes (or migrates) an idempotent,
    sentinel-bracketed lazy-import stub (v3) into
    $PROFILE.CurrentUserAllHosts. The block prepends the module dir to
    $env:PSModulePath and registers a single argument completer for
    Install/Get/Uninstall-Package -Name; the actual Import-Module is
    deferred until the first Tab keypress. Cmdlet invocations
    (Install-Package etc.) auto-load the module via PSModulePath.
    -SkipProfile makes the PSModulePath registration session-only.

    Profile-block emission is delegated to the sibling helper
    Add-ScoopBucketProfileBlock.ps1 so the test suite can target a
    temp profile.

.NOTES
    PowerShell auto-imports modules located on $env:PSModulePath the first
    time one of their exported functions is referenced. Tab completion
    of `-Name` does NOT trigger auto-load early enough for the same
    Tab call to see the module's argument completer, which is why the
    stub block is needed at profile-load time. Auto-load via the profile
    PSModulePath entry does not apply to `-NoProfile` sessions; there,
    use `Import-Module .\module\MarkMichaelis.ScoopBucket` explicitly.
#>

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'MarkMichaelis.ScoopBucket'
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Source module folder not found: $source"
}

# Resolve a user-scope module path. $env:PSModulePath splits on ';' on
# Windows; we want one under the user profile (writable without admin).
# Internal/test seam: $env:SCOOPBUCKET_USER_MODULE_PATH overrides the
# resolved path so the legacy-junction cleanup can be exercised against a
# sandbox without touching the host.
if ($env:SCOOPBUCKET_USER_MODULE_PATH) {
    $userModulePath = $env:SCOOPBUCKET_USER_MODULE_PATH
} else {
    $userModulePath = $env:PSModulePath -split [System.IO.Path]::PathSeparator |
        Where-Object {
            $_ -and ($_ -like "$HOME\*" -or $_ -like "$env:USERPROFILE\*")
        } |
        Select-Object -First 1

    if (-not $userModulePath) {
        $userModulePath = Join-Path $HOME 'Documents\PowerShell\Modules'
    }
}

$target = Join-Path $userModulePath 'MarkMichaelis.ScoopBucket'

if ($Uninstall) {
    # Strip the v1/v2 sentinel block from the profile (delegated to
    # the same helper used by the install path).
    $helper = Join-Path $PSScriptRoot 'Add-ScoopBucketProfileBlock.ps1'
    if (Test-Path -LiteralPath $helper) {
        $helperArgs = @{
            ProfilePath = $PROFILE.CurrentUserAllHosts
            Remove      = $true
            Verbose     = $VerbosePreference -eq 'Continue'
        }
        if ($PSBoundParameters.ContainsKey('WhatIf')) { $helperArgs['WhatIf'] = $WhatIfPreference }
        & $helper @helperArgs
        Write-Host "Removed MarkMichaelis.ScoopBucket lazy-import block from $($PROFILE.CurrentUserAllHosts) (if present)."
    } else {
        Write-Warning "Profile-block helper not found at $helper; skipping profile cleanup."
    }

    # Remove the junction iff it points back to this repo. Leave any
    # non-junction install (e.g. real directory from a different
    # workflow) alone unless -Force is passed.
    if (Test-Path -LiteralPath $target) {
        $existing = Get-Item -LiteralPath $target -Force
        $isJunction = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        $pointsHere = $false
        if ($isJunction -and $existing.Target) {
            try {
                $pointsHere = (Resolve-Path -LiteralPath $existing.Target).Path -eq (Resolve-Path -LiteralPath $source).Path
            } catch { $pointsHere = $false }
        }
        if ($pointsHere -or $Force) {
            if ($PSCmdlet.ShouldProcess($target, 'Remove MarkMichaelis.ScoopBucket junction')) {
                if ($isJunction) {
                    # PowerShell's Remove-Item -Recurse follows the
                    # reparse point and tries to delete the *target*
                    # contents (which fails with Access Denied if the
                    # target is read-only or the junction has the
                    # ReadOnly attribute set, as New-Item -ItemType
                    # Junction does on some hosts). Strip ReadOnly
                    # then use the .NET non-recursive Directory.Delete
                    # which removes only the link itself.
                    if (($existing.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                        $existing.Attributes = $existing.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                    }
                    [System.IO.Directory]::Delete($target, $false)
                } else {
                    Remove-Item -LiteralPath $target -Recurse -Force
                }
                Write-Host "Removed MarkMichaelis.ScoopBucket entry at $target."
            }
        } else {
            Write-Warning "Entry at $target is not a junction to this repo; leaving it in place. Pass -Force to remove anyway."
        }
    } else {
        Write-Verbose "No MarkMichaelis.ScoopBucket entry at $target; nothing to remove."
    }

    Write-Host "Uninstall complete. To use the module from this repo: cd here and run 'Import-Module .\module\MarkMichaelis.ScoopBucket'."
    return
}

# Transitional legacy cleanup (#375 -> follow-up #376): earlier versions of
# this installer junctioned the module into $userModulePath. On a OneDrive
# Known-Folder-Move machine that path is synced and folder backup chokes on
# the reparse point. Remove any such self-pointing junction so the machine is
# unblocked; discovery now flows through the PSModulePath entry the profile
# block adds (below). Once GLOBETROTTERX1 and DAKAR are migrated this block
# can be deleted (#376).
if (Test-Path -LiteralPath $target) {
    $existing = Get-Item -LiteralPath $target -Force
    $isJunction = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    $pointsHere = $false
    if ($isJunction -and $existing.Target) {
        try {
            $pointsHere = (Resolve-Path -LiteralPath $existing.Target).Path -eq (Resolve-Path -LiteralPath $source).Path
        } catch { $pointsHere = $false }
    }
    if ($pointsHere) {
        if ($PSCmdlet.ShouldProcess($target, 'Remove legacy MarkMichaelis.ScoopBucket junction')) {
            # Strip ReadOnly then delete only the link (non-recursive) so we
            # never follow the reparse point into the repo source (#253).
            if (($existing.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                $existing.Attributes = $existing.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            }
            [System.IO.Directory]::Delete($target, $false)
            Write-Host "Removed legacy MarkMichaelis.ScoopBucket junction at $target (now registered via PSModulePath)."
        }
    }
}

# Register the repo's module dir on PSModulePath for the CURRENT session so
# the module is immediately discoverable; persistence is handled by the
# profile block (unless -SkipProfile).
$moduleDir = $PSScriptRoot
if (($env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains $moduleDir) {
    $env:PSModulePath = $moduleDir + [System.IO.Path]::PathSeparator + $env:PSModulePath
}
Write-Host "MarkMichaelis.ScoopBucket discoverable via PSModulePath: $moduleDir"
Write-Host "Test with: Import-Module MarkMichaelis.ScoopBucket -Force; Get-Command -Module MarkMichaelis.ScoopBucket"

# -SkipProfile means session-only: the PSModulePath entry above applies to
# this session but is not persisted to the profile.
if ($SkipProfile) { return }

# Delegate to Add-ScoopBucketProfileBlock.ps1 so the v3 lazy-import stub
# emission (which also persists the PSModulePath entry) is shared with the
# test suite (which calls the helper directly with -ProfilePath).
$helper = Join-Path $PSScriptRoot 'Add-ScoopBucketProfileBlock.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Profile-block helper not found: $helper"
}
$helperArgs = @{
    ProfilePath = $PROFILE.CurrentUserAllHosts
    Verbose     = $VerbosePreference -eq 'Continue'
}
if ($PSBoundParameters.ContainsKey('WhatIf')) { $helperArgs['WhatIf'] = $WhatIfPreference }
& $helper @helperArgs
Write-Verbose "Wrote MarkMichaelis.ScoopBucket lazy-import (v3) block to $($PROFILE.CurrentUserAllHosts)."
