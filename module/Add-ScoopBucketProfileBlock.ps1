[CmdletBinding(SupportsShouldProcess)]
param(
    # Override the target profile (default: $PROFILE.CurrentUserAllHosts).
    # Tests pass a temp path here so they don't disturb the host.
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts
)

<#
.SYNOPSIS
    Write (or update) the lazy-import sentinel block for
    MarkMichaelis.ScoopBucket in $ProfilePath.

.DESCRIPTION
    Emits a v2 sentinel block that DEFERS Import-Module
    MarkMichaelis.ScoopBucket until either:
      - Tab completion fires on Install-Package / Get-Package /
        Uninstall-Package -Name (handled by a stub argument completer
        that triggers the import then re-runs completion), or
      - The user invokes one of those cmdlets directly (handled by
        PowerShell's built-in module auto-loading from PSModulePath).

    The eager v1 block ran Import-Module on every shell start and
    cost ~1 s. The v2 stub costs <10 ms because it only registers a
    single argument completer.

    Idempotent: re-running this script replaces an existing v1 OR v2
    sentinel block in-place; never duplicates.

.NOTES
    Sentinel evolution:
      v1: # MarkMichaelis.ScoopBucket:Import:BEGIN
          if (-not (Get-Module ...)) { Import-Module ... }
      v2: # MarkMichaelis.ScoopBucket:Import:BEGIN v2
          Register-ArgumentCompleter ... { stub }
#>

$ErrorActionPreference = 'Stop'

$beginV1Marker  = '# MarkMichaelis.ScoopBucket:Import:BEGIN'
$beginV2Marker  = '# MarkMichaelis.ScoopBucket:Import:BEGIN v2'
$endMarker      = '# MarkMichaelis.ScoopBucket:Import:END'

$block = @"

$beginV2Marker
# Lazy-loads MarkMichaelis.ScoopBucket on first use to keep cold pwsh
# start fast. Cmdlet calls (Install-Package / Get-Package /
# Uninstall-Package) auto-load the module via PSModulePath. The stub
# argument completer below triggers the import on the very first Tab
# keypress and returns real package-name suggestions in the same call.
# Re-run module/Install-Module.ps1 -SkipProfile to opt out.
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
    Register-ArgumentCompleter -CommandName 'Install-Package','Get-Package','Uninstall-Package' -ParameterName 'Name' -ScriptBlock `$__msbStub
    Remove-Variable __msbStub -ErrorAction SilentlyContinue
}
$endMarker
"@

if (-not $ProfilePath) {
    throw 'ProfilePath is empty; cannot emit MarkMichaelis.ScoopBucket profile block.'
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Create profile')) {
        $profileDir = Split-Path -Parent $ProfilePath
        if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
            New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        }
        Set-Content -LiteralPath $ProfilePath -Value $block -Encoding UTF8
        Write-Verbose "Created $ProfilePath with MarkMichaelis.ScoopBucket v2 lazy-import block."
    }
    return
}

$current = Get-Content -Raw -LiteralPath $ProfilePath -ErrorAction SilentlyContinue
if ($null -eq $current) { $current = '' }

# Match either v1 (no version suffix) or v2 BEGIN markers. Use the
# bare (no-version-suffix) marker as the prefix; a v2 line starts
# with the same prefix plus " v2", so this regex catches both.
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
        if ($PSCmdlet.ShouldProcess($ProfilePath, 'Update MarkMichaelis.ScoopBucket import block to v2')) {
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
