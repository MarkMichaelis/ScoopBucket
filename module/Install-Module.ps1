[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    # By default the installer also adds a sentinel-bracketed
    # `Import-Module MarkMichaelis.ScoopBucket` block to
    # $PROFILE.CurrentUserAllHosts so argument-completer registration
    # runs before the FIRST Tab keypress of a fresh session (PowerShell
    # registers completers only when a module is fully loaded, which
    # the first tab itself can't accomplish if it's also the trigger
    # for auto-load). Pass -SkipProfile to suppress this.
    [switch]$SkipProfile
)

<#
.SYNOPSIS
    Symlink the MarkMichaelis.ScoopBucket module into the current user's
    PSModulePath so `Import-Module MarkMichaelis.ScoopBucket` (and
    auto-loading of `Install-Package`, `Get-Package`,
    `Invoke-PackageInstall`) works from any PowerShell session on this
    machine. Also pre-imports the module from $PROFILE so Tab
    completion for `-Name` works on the very first keystroke.

.DESCRIPTION
    Creates a junction (no admin required for user-scope module paths)
    from $HOME\Documents\PowerShell\Modules\MarkMichaelis.ScoopBucket
    to this repo's module/MarkMichaelis.ScoopBucket folder. Re-running
    is idempotent; pass -Force to replace an existing entry (file, real
    directory, or stale junction).

    Additionally, unless -SkipProfile is passed, writes an idempotent,
    sentinel-bracketed `Import-Module MarkMichaelis.ScoopBucket` line
    into $PROFILE.CurrentUserAllHosts. This guarantees argument
    completers are registered before the first Tab keypress of a fresh
    session — PowerShell can auto-load the module on demand, but the
    completer the module registers at load time isn't visible to the
    same Tab call that triggered the load, so the *first* Tab in a
    fresh session would otherwise return nothing.

.NOTES
    PowerShell auto-imports modules located on $env:PSModulePath the first
    time one of their exported functions is referenced, so once installed
    you can use the helpers without an explicit Import-Module — but
    Tab-completion of `-Name` needs the module loaded up front.
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

if (-not (Test-Path -LiteralPath $userModulePath -PathType Container)) {
    Write-Verbose "Creating module path: $userModulePath"
    if ($PSCmdlet.ShouldProcess($userModulePath, 'New-Item -ItemType Directory')) {
        New-Item -ItemType Directory -Force -Path $userModulePath | Out-Null
    }
}

$target = Join-Path $userModulePath 'MarkMichaelis.ScoopBucket'

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

# Append an idempotent, sentinel-bracketed Import-Module to
# $PROFILE.CurrentUserAllHosts so the module's argument completers are
# wired up before the first Tab keystroke of a fresh session.
$profilePath = $PROFILE.CurrentUserAllHosts
$beginMarker = '# MarkMichaelis.ScoopBucket:Import:BEGIN'
$endMarker   = '# MarkMichaelis.ScoopBucket:Import:END'
$block = @"

$beginMarker
# Auto-loads the module so Tab completion for Install-Package / Get-Package
# -Name works on the first keystroke. Remove this block (or re-run
# Install-Module.ps1 -SkipProfile) to opt out.
if (-not (Get-Module -Name MarkMichaelis.ScoopBucket)) {
    Import-Module MarkMichaelis.ScoopBucket -ErrorAction SilentlyContinue
}
$endMarker
"@

if (-not (Test-Path -LiteralPath $profilePath)) {
    if ($PSCmdlet.ShouldProcess($profilePath, 'Create profile')) {
        $profileDir = Split-Path -Parent $profilePath
        if (-not (Test-Path -LiteralPath $profileDir)) {
            New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        }
        Set-Content -LiteralPath $profilePath -Value $block -Encoding UTF8
        Write-Host "Created $profilePath with MarkMichaelis.ScoopBucket import block."
    }
    return
}

$current = Get-Content -Raw -LiteralPath $profilePath -ErrorAction SilentlyContinue
if ($null -eq $current) { $current = '' }

if ($current -match [regex]::Escape($beginMarker)) {
    # Replace the existing block in-place so updates to the snippet
    # land on a re-install without duplicating.
    $pattern = "(?s)" + [regex]::Escape($beginMarker) + ".*?" + [regex]::Escape($endMarker)
    $updated = [regex]::Replace($current, $pattern, ($block.Trim()))
    if ($updated -ne $current) {
        if ($PSCmdlet.ShouldProcess($profilePath, 'Update MarkMichaelis.ScoopBucket import block')) {
            Set-Content -LiteralPath $profilePath -Value $updated -Encoding UTF8
            Write-Host "Updated MarkMichaelis.ScoopBucket import block in $profilePath."
        }
    } else {
        Write-Host "MarkMichaelis.ScoopBucket import block already up to date in $profilePath."
    }
} else {
    if ($PSCmdlet.ShouldProcess($profilePath, 'Append MarkMichaelis.ScoopBucket import block')) {
        Add-Content -LiteralPath $profilePath -Value $block -Encoding UTF8
        Write-Host "Appended MarkMichaelis.ScoopBucket import block to $profilePath."
    }
}
