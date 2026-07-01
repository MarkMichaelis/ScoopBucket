#requires -Version 7.0
<#
.SYNOPSIS
    Opt-in, per-machine helper that "installs" MarkMichaelis.ScoopBucket so the
    bare `Install-Package <x>` wrapper resolves to this bucket's module.

.DESCRIPTION
    scoop keeps a full clone of this bucket on disk under
    <scoopRoot>\buckets\<name>\, which includes the module at
    module\MarkMichaelis.ScoopBucket. Bundles load that module directly under
    -NoProfile (see #390 Part B), but the convenience wrapper `Install-Package
    <x>` only wins the name clash with PackageManagement\Install-Package when
    OUR module is imported in the shell. This script performs the two
    deliberate, idempotent steps that constitute "installing the module":

      1. Create a directory junction
             <scoopRoot>\modules\MarkMichaelis.ScoopBucket
         pointing at the module source. Because <scoopRoot>\modules is on
         PSModulePath, the module becomes discoverable by name.
      2. Append exactly one `Import-Module MarkMichaelis.ScoopBucket` line to
         the CurrentUserAllHosts profile (inside a distinctly-marked sentinel
         block) so an interactive shell eagerly imports the module and our
         Install-Package shadows PackageManagement's.

    Both steps are idempotent (safe to re-run) and honor -WhatIf / -Confirm.
    This helper is intentionally NOT wired as a `depends` of any bundle, so
    third-party consumers of individual bundles are never forced to alter their
    machine. It is offered only via `scoop install MarkMichaelis/RegisterBucketModule`
    or by running this script directly.

    NOTE (deliberate tradeoff): this is the EAGER "the bare command must resolve
    to ours" option. It differs from module/Install-Module.ps1's default lazy v3
    profile block (which prepends PSModulePath and defers the import). It uses a
    distinct sentinel so the two never collide; run only one of them.

.PARAMETER ModulePath
    Explicit path to the MarkMichaelis.ScoopBucket module directory to junction
    to. Overrides discovery. Useful for pointing at a local repo checkout
    (e.g. D:\Git\ScoopBucket\module\MarkMichaelis.ScoopBucket).

.PARAMETER FromLocalRepo
    Junction to the module directory that sits beside this script
    (<scriptDir>\module\MarkMichaelis.ScoopBucket) -- i.e. this repo checkout --
    instead of the scoop bucket clone. Intended for a dev machine.

.PARAMETER ScoopRoot
    Root of the scoop installation. Defaults to $env:SCOOP, else ~\scoop. The
    junction is created under <ScoopRoot>\modules and, absent -ModulePath /
    -FromLocalRepo, the module is discovered under <ScoopRoot>\buckets\*\module.

.PARAMETER ProfilePath
    Profile file to edit. Defaults to $PROFILE.CurrentUserAllHosts. Tests pass a
    temp path so the host profile is never touched.

.PARAMETER Remove
    Reverse both steps: delete the junction (never the module source) and strip
    the sentinel block from the profile.

.EXAMPLE
    ./Register-BucketModule.ps1
    # Junction to the scoop bucket clone + add the profile import. Idempotent.

.EXAMPLE
    ./Register-BucketModule.ps1 -FromLocalRepo
    # Dev machine: junction to this repo's module\ instead of the bucket clone.

.EXAMPLE
    ./Register-BucketModule.ps1 -WhatIf
    # Show what would change without touching the machine.

.EXAMPLE
    ./Register-BucketModule.ps1 -Remove
    # Uninstall: remove the junction and the profile import block.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ModulePath,
    [switch]$FromLocalRepo,
    [string]$ScoopRoot,
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleName  = 'MarkMichaelis.ScoopBucket'
$script:BeginMarker = "# $($script:ModuleName):RegisterBucketModule:BEGIN"
$script:EndMarker   = "# $($script:ModuleName):RegisterBucketModule:END"

function Resolve-ScoopRoot {
    param([string]$ScoopRoot)
    if ($ScoopRoot) { return $ScoopRoot }
    if ($env:SCOOP) { return $env:SCOOP }
    return (Join-Path $HOME 'scoop')
}

function Resolve-ModuleSource {
    param([string]$ModulePath, [switch]$FromLocalRepo, [string]$ScoopRoot, [string]$ScriptRoot)
    if ($ModulePath) {
        if (-not (Test-Path -LiteralPath $ModulePath -PathType Container)) { throw "ModulePath not found or not a directory: $ModulePath" }
        return (Resolve-Path -LiteralPath $ModulePath).Path
    }
    if ($FromLocalRepo) {
        $local = Join-Path $ScriptRoot "module\$($script:ModuleName)"
        if (-not (Test-Path -LiteralPath $local -PathType Container)) { throw "Local repo module not found (or not a directory) beside the script: $local" }
        return (Resolve-Path -LiteralPath $local).Path
    }
    $pattern = Join-Path $ScoopRoot "buckets\*\module\$($script:ModuleName)"
    $found = Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        throw "Could not find $($script:ModuleName) under $ScoopRoot\buckets\*\module. Pass -ModulePath or -FromLocalRepo."
    }
    return $found.FullName
}

function Test-IsReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return [bool]($item -and $item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))
}

function Test-JunctionTarget {
    param([string]$Link, [string]$Target)
    if (-not (Test-IsReparsePoint -Path $Link)) { return $false }
    $current = @((Get-Item -LiteralPath $Link -Force).Target)[0]
    if (-not $current) { return $false }
    return ([System.IO.Path]::GetFullPath($current).TrimEnd('\')) -ieq ([System.IO.Path]::GetFullPath($Target).TrimEnd('\'))
}

function Install-BucketModuleJunction {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Link, [string]$Source)
    if (Test-JunctionTarget -Link $Link -Target $Source) { Write-Verbose "Junction already current: $Link"; return }
    $exists = Test-Path -LiteralPath $Link
    if ($exists -and -not (Test-IsReparsePoint -Path $Link)) {
        throw "Refusing to replace an existing path that is not a junction (reparse point): $Link"
    }
    if (-not $PSCmdlet.ShouldProcess($Link, "Junction to $Source")) { return }
    if ($exists) {
        # New-Item -ItemType Junction sets the ReadOnly attribute on some hosts,
        # which makes a plain delete fail with Access denied. Strip ReadOnly, then
        # delete ONLY the link (non-recursive) so we never follow the reparse point
        # into the target. Mirrors module\Install-Module.ps1 (#391 review).
        $stale = Get-Item -LiteralPath $Link -Force
        if (($stale.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            $stale.Attributes = $stale.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        [System.IO.Directory]::Delete($Link, $false)
    }
    $parent = Split-Path -Parent $Link
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    New-Item -ItemType Junction -Path $Link -Value $Source | Out-Null
    Write-Verbose "Created junction $Link -> $Source"
}

function Uninstall-BucketModuleJunction {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Link)
    if (-not (Test-Path -LiteralPath $Link)) { Write-Verbose "No junction at $Link."; return }
    if (-not (Test-IsReparsePoint -Path $Link)) { Write-Warning "Path exists but is not a junction (reparse point); leaving as-is: $Link"; return }
    if ($PSCmdlet.ShouldProcess($Link, 'Remove junction')) {
        # Strip ReadOnly (New-Item -ItemType Junction sets it on some hosts) then
        # delete only the link (non-recursive) so we never follow the reparse point
        # into the target. Mirrors module\Install-Module.ps1 (#391 review).
        $existing = Get-Item -LiteralPath $Link -Force
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            $existing.Attributes = $existing.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        [System.IO.Directory]::Delete($Link, $false)
        Write-Verbose "Removed junction $Link"
    }
}

function Add-BucketModuleImport {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ProfilePath)
    $current = if (Test-Path -LiteralPath $ProfilePath) { Get-Content -Raw -LiteralPath $ProfilePath } else { '' }
    if ($null -eq $current) { $current = '' }
    if ($current -match [regex]::Escape($script:BeginMarker)) { Write-Verbose "Import block already present."; return }
    if (-not $PSCmdlet.ShouldProcess($ProfilePath, "Add $($script:ModuleName) import")) { return }
    $parent = Split-Path -Parent $ProfilePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $block = $script:BeginMarker + "`n" + "Import-Module $($script:ModuleName)" + "`n" + $script:EndMarker
    $prefix = if ($current -and -not $current.EndsWith("`n")) { "`n" } else { '' }
    Add-Content -LiteralPath $ProfilePath -Value ($prefix + $block) -Encoding utf8
    Write-Verbose "Added $($script:ModuleName) import block to $ProfilePath"
}

function Remove-BucketModuleImport {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ProfilePath)
    if (-not (Test-Path -LiteralPath $ProfilePath)) { Write-Verbose "No profile at $ProfilePath."; return }
    $current = Get-Content -Raw -LiteralPath $ProfilePath
    if ($null -eq $current) { return }
    $pattern = '(?s)\r?\n?' + [regex]::Escape($script:BeginMarker) + '.*?' + [regex]::Escape($script:EndMarker) + '\r?\n?'
    if ($current -notmatch $pattern) { Write-Verbose "No import block found in $ProfilePath."; return }
    if ($PSCmdlet.ShouldProcess($ProfilePath, "Remove $($script:ModuleName) import")) {
        $updated = [regex]::Replace($current, $pattern, "`n")
        Set-Content -LiteralPath $ProfilePath -Value $updated -Encoding utf8
        Write-Verbose "Removed import block from $ProfilePath"
    }
}

# --- main -----------------------------------------------------------------
$resolvedScoop = Resolve-ScoopRoot -ScoopRoot $ScoopRoot
$link = Join-Path (Join-Path $resolvedScoop 'modules') $script:ModuleName

if ($Remove) {
    Uninstall-BucketModuleJunction -Link $link
    Remove-BucketModuleImport -ProfilePath $ProfilePath
    return
}

$source = Resolve-ModuleSource -ModulePath $ModulePath -FromLocalRepo:$FromLocalRepo -ScoopRoot $resolvedScoop -ScriptRoot $PSScriptRoot
Install-BucketModuleJunction -Link $link -Source $source
Add-BucketModuleImport -ProfilePath $ProfilePath
