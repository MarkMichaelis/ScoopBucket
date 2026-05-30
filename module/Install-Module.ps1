[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    # By default the installer also adds a sentinel-bracketed lazy-import
    # stub block (v2) to $PROFILE.CurrentUserAllHosts so the
    # `Install-Package -Name <Tab>` argument completer fires on the
    # first keystroke without paying the ~1 s `Import-Module` cost on
    # every shell start. Pass -SkipProfile to suppress this.
    [switch]$SkipProfile,

    # Reverse a previous install: remove the sentinel-bracketed v1/v2
    # block from $PROFILE.CurrentUserAllHosts AND remove the
    # PSModulePath junction (only if it points back to this repo).
    # After -Uninstall, use the module by `cd`-ing here and running
    # `Import-Module .\module\MarkMichaelis.ScoopBucket`. See #251.
    [switch]$Uninstall
)

<#
.SYNOPSIS
    Symlink the MarkMichaelis.ScoopBucket module into the current user's
    PSModulePath so `Import-Module MarkMichaelis.ScoopBucket` (and
    auto-loading of `Install-Package`, `Get-Package`,
    `Invoke-PackageInstall`) works from any PowerShell session on this
    machine. Also writes a lazy-import stub block to $PROFILE so
    Tab completion for `-Name` works on the very first keystroke
    without eagerly loading the module on every shell start.

.DESCRIPTION
    Creates a junction (no admin required for user-scope module paths)
    from $HOME\Documents\PowerShell\Modules\MarkMichaelis.ScoopBucket
    to this repo's module/MarkMichaelis.ScoopBucket folder. Re-running
    is idempotent; pass -Force to replace an existing entry (file, real
    directory, or stale junction).

    Additionally, unless -SkipProfile is passed, writes (or migrates)
    an idempotent, sentinel-bracketed lazy-import stub (v2) into
    $PROFILE.CurrentUserAllHosts. The stub registers a single argument
    completer for Install/Get/Uninstall-Package -Name; the actual
    Import-Module is deferred until the first Tab keypress. Cmdlet
    invocations (Install-Package etc.) auto-load the module via
    PSModulePath.

    Profile-block emission is delegated to the sibling helper
    Add-ScoopBucketProfileBlock.ps1 so the test suite can target a
    temp profile without running the junction step.

.NOTES
    PowerShell auto-imports modules located on $env:PSModulePath the first
    time one of their exported functions is referenced. Tab completion
    of `-Name` does NOT trigger auto-load early enough for the same
    Tab call to see the module's argument completer, which is why the
    stub block is needed at profile-load time.
#>

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'MarkMichaelis.ScoopBucket'
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Source module folder not found: $source"
}

# Resolve a user-scope module path. $env:PSModulePath splits on ';' on
# Windows; we want one under the user profile (writable without admin).
$userModulePath = $env:PSModulePath -split [System.IO.Path]::PathSeparator |
    Where-Object {
        $_ -and ($_ -like "$HOME\*" -or $_ -like "$env:USERPROFILE\*")
    } |
    Select-Object -First 1

if (-not $userModulePath) {
    $userModulePath = Join-Path $HOME 'Documents\PowerShell\Modules'
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
                Remove-Item -LiteralPath $target -Recurse -Force
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

if (-not (Test-Path -LiteralPath $userModulePath -PathType Container)) {
    Write-Verbose "Creating module path: $userModulePath"
    if ($PSCmdlet.ShouldProcess($userModulePath, 'New-Item -ItemType Directory')) {
        New-Item -ItemType Directory -Force -Path $userModulePath | Out-Null
    }
}

if (Test-Path -LiteralPath $target) {
    $existing = Get-Item -LiteralPath $target -Force
    $isJunction = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isJunction -and $existing.Target -and ((Resolve-Path -LiteralPath $existing.Target).Path -eq (Resolve-Path -LiteralPath $source).Path)) {
        Write-Host "MarkMichaelis.ScoopBucket module already linked at: $target"
        $script:JunctionCreated = $false
    } else {
        if (-not $Force) {
            throw "An entry already exists at $target. Re-run with -Force to replace it."
        }
        if ($PSCmdlet.ShouldProcess($target, 'Remove existing entry')) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        $script:JunctionCreated = $true
    }
} else {
    $script:JunctionCreated = $true
}

if ($script:JunctionCreated) {
    if ($PSCmdlet.ShouldProcess("$target -> $source", 'New-Item -ItemType Junction')) {
        New-Item -ItemType Junction -Path $target -Target $source | Out-Null
        Write-Host "Linked MarkMichaelis.ScoopBucket module: $target -> $source"
        Write-Host "Test with: Import-Module MarkMichaelis.ScoopBucket -Force; Get-Command -Module MarkMichaelis.ScoopBucket"
    }
}

if ($SkipProfile) { return }

# Delegate to Add-ScoopBucketProfileBlock.ps1 so the v2 lazy-import
# stub emission is shared with the test suite (which calls the helper
# directly with -ProfilePath against a temp file).
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
Write-Verbose "Wrote MarkMichaelis.ScoopBucket lazy-import (v2) block to $($PROFILE.CurrentUserAllHosts)."
