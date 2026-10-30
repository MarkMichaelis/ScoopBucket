[CmdletBinding(SupportsShouldProcess)]
param(
    # Override the target profile (default: $PROFILE.CurrentUserAllHosts).
    # Tests pass a temp path here so they don't disturb the host.
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,

    # Strip any existing MarkMichaelis.ScoopBucket sentinel block
    # (v1 or v2) instead of emitting one. Used by
    # Install-Module.ps1 -Uninstall (#251).
    [switch]$Remove
)

<#
.SYNOPSIS
    Write (or update) the lazy-import sentinel block for
    MarkMichaelis.ScoopBucket in $ProfilePath.

.DESCRIPTION
    Emits a v4 sentinel block that prepends the repo's module directory to
    $env:PSModulePath (so the module is discoverable without a junction under
    the user's -- often OneDrive-synced -- module path) and DEFERS
    Import-Module MarkMichaelis.ScoopBucket until either:
      - Tab completion fires on Install-Package / Get-Package -Name
        (handled by a stub argument completer that triggers the import
        then re-runs completion), or
      - The user invokes one of those cmdlets directly (handled by
        PowerShell's built-in module auto-loading from PSModulePath).

    The eager v1 block ran Import-Module on every shell start and
    cost ~1 s. The v2/v3 stub costs <10 ms because it only registers a
    single argument completer (v3 adds a cheap PSModulePath prepend).

    The block itself names no path. The profile roams through OneDrive
    between machines whose clones live in different places, so this
    machine's module directory is recorded in a non-roaming file,
    %LOCALAPPDATA%\MarkMichaelis.ScoopBucket\module-dir.txt, which the block
    reads at shell start (#484). Every machine therefore writes the same
    block, and re-installing on one machine never forks the profile.

    Idempotent: re-running this script replaces an existing v1-v4 sentinel
    block in-place, never duplicates, and rewrites the module-dir file only
    when its content changes.

.NOTES
    Sentinel evolution:
      v1: # MarkMichaelis.ScoopBucket:Import:BEGIN
          if (-not (Get-Module ...)) { Import-Module ... }
      v2: # MarkMichaelis.ScoopBucket:Import:BEGIN v2
          Register-ArgumentCompleter ... { stub }
      v3: # MarkMichaelis.ScoopBucket:Import:BEGIN v3
          $env:PSModulePath prepend + Register-ArgumentCompleter stub
          (replaces the old junction-under-PSModulePath install, #375)
      v4: # MarkMichaelis.ScoopBucket:Import:BEGIN v4
          the prepended dir comes from the LOCALAPPDATA module-dir file
          instead of a literal path baked into the roaming profile (#484)
#>

$ErrorActionPreference = 'Stop'

$beginV1Marker  = '# MarkMichaelis.ScoopBucket:Import:BEGIN'
$beginV4Marker  = '# MarkMichaelis.ScoopBucket:Import:BEGIN v4'
$endMarker      = '# MarkMichaelis.ScoopBucket:Import:END'

# The repo's module directory is this script's own folder (module/), the
# parent of the MarkMichaelis.ScoopBucket module folder. It is recorded per
# machine in a LOCALAPPDATA file (never in the roaming profile) so the profile
# can register it on $env:PSModulePath instead of junctioning the module under
# the user's (often OneDrive-synced) module path.
$moduleDir     = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$moduleDirFile = Join-Path $env:LOCALAPPDATA 'MarkMichaelis.ScoopBucket\module-dir.txt'

$block = @"

$beginV4Marker
# Lazy-loads MarkMichaelis.ScoopBucket on first use to keep cold pwsh
# start fast. The repo's module dir is added to PSModulePath so cmdlet
# calls (Install-Package / Get-Package) auto-load the module; the stub
# argument completer below triggers the import on the very first Tab
# keypress and returns real package-name suggestions in the same call.
# Re-run module/Install-Module.ps1 -SkipProfile to opt out. The module dir
# is per machine and read from LOCALAPPDATA, because this profile roams.
`$__msbModuleDirFile = Join-Path `$env:LOCALAPPDATA 'MarkMichaelis.ScoopBucket\module-dir.txt'
if (Test-Path -LiteralPath `$__msbModuleDirFile -PathType Leaf) {
    `$__msbModuleDir = "`$(Get-Content -LiteralPath `$__msbModuleDirFile -TotalCount 1)".Trim()
    if (`$__msbModuleDir -and (Test-Path -LiteralPath `$__msbModuleDir -PathType Container) -and
        (`$env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains `$__msbModuleDir) {
        `$env:PSModulePath = `$__msbModuleDir + [System.IO.Path]::PathSeparator + `$env:PSModulePath
    }
}
Remove-Variable __msbModuleDirFile, __msbModuleDir -ErrorAction SilentlyContinue
if (-not `$Global:__MarkMichaelisScoopBucketStubInstalled) {
    `$Global:__MarkMichaelisScoopBucketStubInstalled = `$true
    `$__msbStub = {
        param(`$commandName, `$parameterName, `$wordToComplete, `$commandAst, `$fakeBoundParameters)
        Import-Module MarkMichaelis.ScoopBucket -ErrorAction SilentlyContinue
        `$mod = Get-Module MarkMichaelis.ScoopBucket
        if (-not `$mod) { return }
        # Import-Module re-registered the real completer (overwriting
        # this stub). Delegate to the module-private suggestion source
        # so the FIRST Tab returns real package names instead of the
        # default file-completer fallback.
        & `$mod {
            param(`$w)
            try { `$names = Get-PackageNameSuggestion -WordToComplete `$w } catch { return }
            foreach (`$name in `$names) {
                if (`$name -match "[\s']") {
                    `$escaped = `$name -replace "'", "''"
                    `$completionText = "'`$escaped'"
                } else {
                    `$completionText = `$name
                }
                [System.Management.Automation.CompletionResult]::new(
                    `$completionText, `$name, 'ParameterValue', `$name)
            }
        } `$wordToComplete
    }
    Register-ArgumentCompleter -CommandName 'Install-Package','Get-Package' -ParameterName 'Name' -ScriptBlock `$__msbStub
    Remove-Variable __msbStub -ErrorAction SilentlyContinue
}
$endMarker
"@

if (-not $ProfilePath) {
    throw 'ProfilePath is empty; cannot emit MarkMichaelis.ScoopBucket profile block.'
}

if ($Remove) {
    if ((Test-Path -LiteralPath $moduleDirFile -PathType Leaf) -and
        $PSCmdlet.ShouldProcess($moduleDirFile, 'Remove MarkMichaelis.ScoopBucket module-dir record')) {
        Remove-Item -LiteralPath $moduleDirFile -Force
    }
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        Write-Verbose "No profile at $ProfilePath; nothing to remove."
        return
    }
    $current = Get-Content -Raw -LiteralPath $ProfilePath -ErrorAction SilentlyContinue
    if ($null -eq $current -or $current -eq '') {
        Write-Verbose "Profile $ProfilePath is empty; nothing to remove."
        return
    }
    $removalPattern = '(?s)\r?\n?' + [regex]::Escape($beginV1Marker) + '.*?' + [regex]::Escape($endMarker) + '\r?\n?'
    if (-not [regex]::IsMatch($current, $removalPattern)) {
        Write-Verbose "No MarkMichaelis.ScoopBucket sentinel block found in $ProfilePath."
        return
    }
    $updated = [regex]::Replace($current, $removalPattern, "`n")
    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Remove MarkMichaelis.ScoopBucket import block')) {
        Set-Content -LiteralPath $ProfilePath -Value $updated -Encoding UTF8
        Write-Verbose "Removed MarkMichaelis.ScoopBucket import block from $ProfilePath."
    }
    return
}

# Record this machine's module dir for the block to read. Written only when
# it changes, so a second run touches nothing.
$recorded = if (Test-Path -LiteralPath $moduleDirFile -PathType Leaf) {
    "$(Get-Content -LiteralPath $moduleDirFile -TotalCount 1)".Trim()
}
if ($recorded -ne $moduleDir -and
    $PSCmdlet.ShouldProcess($moduleDirFile, "Record module dir $moduleDir")) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $moduleDirFile) | Out-Null
    Set-Content -LiteralPath $moduleDirFile -Value $moduleDir -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Create profile')) {
        $profileDir = Split-Path -Parent $ProfilePath
        if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
            New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        }
        Set-Content -LiteralPath $ProfilePath -Value $block -Encoding UTF8
        Write-Verbose "Created $ProfilePath with MarkMichaelis.ScoopBucket v4 lazy-import block."
    }
    return
}

$current = Get-Content -Raw -LiteralPath $ProfilePath -ErrorAction SilentlyContinue
if ($null -eq $current) { $current = '' }

# Match any BEGIN marker, v1 (no version suffix) through v4. Use the
# bare (no-version-suffix) marker as the prefix; a vN line starts
# with the same prefix plus " vN", so this regex catches them all.
$existingPattern = '(?s)' + [regex]::Escape($beginV1Marker) + '.*?' + [regex]::Escape($endMarker)
if ([regex]::IsMatch($current, $existingPattern)) {
    # Use a MatchEvaluator so $-tokens in $block (e.g. $_, $&,
    # $Global:...) are emitted literally instead of being treated as
    # regex substitutions by [regex]::Replace's default string
    # overload.
    $literal = $block.Trim()
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $null = $match; $literal }
    $updated = [regex]::Replace($current, $existingPattern, $evaluator)
    if ($updated -ne $current) {
        if ($PSCmdlet.ShouldProcess($ProfilePath, 'Update MarkMichaelis.ScoopBucket import block to v4')) {
            Set-Content -LiteralPath $ProfilePath -Value $updated -Encoding UTF8
            Write-Verbose "Updated MarkMichaelis.ScoopBucket import block in $ProfilePath."
        }
    } else {
        Write-Verbose "MarkMichaelis.ScoopBucket import block already up to date in $ProfilePath."
    }
} else {
    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Append MarkMichaelis.ScoopBucket import block')) {
        Add-Content -LiteralPath $ProfilePath -Value $block -Encoding UTF8
        Write-Verbose "Appended MarkMichaelis.ScoopBucket import block to $ProfilePath."
    }
}
