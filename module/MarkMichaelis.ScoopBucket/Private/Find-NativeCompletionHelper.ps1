# ----------------------------------------------------------------------------
# Self-healing native-completion adoption (#278).
#
# A hand-curated completer (a literal Register-ArgumentCompleter here-string)
# is only a stand-in for a CLI that ships no native PowerShell completion
# helper *today*. If the CLI later gains a real helper, we want to adopt it
# automatically and nudge a human to delete the now-redundant curated block --
# never hard-fail.
#
# Find-NativeCompletionHelper    -- probes a CLI for a native helper.
# Resolve-SelfHealingCompleter   -- prefers the native helper over a fallback,
#                                   emitting a low-priority advisory when it
#                                   supersedes a hand-curated block.
# ----------------------------------------------------------------------------

# The genuine cmdlet every completion generator (cobra/Go, clap/Rust, oclif,
# click, gh, rg) emits is `Register-ArgumentCompleter`. There is NO
# `Register-ArgumentCompletion`. Match it HARDENED, not loosened: a bare
# `completion`/`completer` token appears in help text and bash scripts and
# would produce false positives. Tolerate an optional module qualifier
# (e.g. `Microsoft.PowerShell.Core\Register-ArgumentCompleter`, or a hyphenated
# module name such as `posh-git\Register-ArgumentCompleter`).
$script:NativeCompletionMarker = '(?i)(?:[\w.-]+\\)?Register-ArgumentCompleter\b'

# Default probe argument-lines, ordered most- to least-common. Each is run as
# `<cli> <args>` guarded by Get-Command with all errors swallowed.
$script:NativeCompletionProbes = @(
    'completion powershell'
    'completion -s powershell'
    'completions powershell'
    'completion --shell powershell'
    '--generate complete-powershell'
)

function Invoke-CompletionProbe {
    <#
    .SYNOPSIS
        Run a single `<cli> <args>` completion probe with a hard timeout.

    .DESCRIPTION
        Runs the probe as `cmd.exe /d /s /c "<cli> <args>"` so PATH resolution
        covers .exe, .cmd and .bat alike, delegating the timeout and child-tree
        kill to the module's single Invoke-WithTimeout helper (rather than a
        second bespoke wrapper). `/d` skips AutoRun, `/s` keeps the quoted CLI
        token intact, and quoting $Cli handles a resolved path with spaces and
        stray cmd metacharacters. Always returns a PSCustomObject with `Output`
        (captured stdout/stderr, or $null when the probe timed out) and
        `TimedOut` (a boolean the caller uses to short-circuit further probes).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$ArgumentLine,
        [int]$TimeoutMs = 5000
    )

    $timeoutSeconds = [math]::Max(1, [int][math]::Ceiling($TimeoutMs / 1000.0))
    # The /c payload is `"<cli>" <args>`: only the CLI token is quoted (so a
    # resolved path with spaces is safe), while $ArgumentLine stays unquoted so
    # cmd parses each probe word as a separate argument. cmd's `/s` strips the
    # outer quote pair only when the payload BOTH starts and ends with a quote;
    # here it ends with an argument word, so nothing is stripped and the args
    # reach the CLI intact (verified against an argument-echoing shim).
    $result = Invoke-WithTimeout -FilePath $env:ComSpec `
        -Arguments @('/d', '/s', '/c', "`"$Cli`" $ArgumentLine") `
        -TimeoutSeconds $timeoutSeconds -CaptureOutput

    if ($result.TimedOut) {
        return [pscustomobject]@{ Output = $null; TimedOut = $true }
    }
    return [pscustomobject]@{ Output = $result.Output; TimedOut = $false }
}

function Find-NativeCompletionHelper {
    <#
    .SYNOPSIS
        Probe a CLI for a genuine native PowerShell completion helper.

    .DESCRIPTION
        Tries each known `completion`-style invocation for $Cli and returns the
        first whose output contains the standard `Register-ArgumentCompleter`
        marker. The CLI must be on PATH (Get-Command guard); each probe runs
        under a hard timeout (Invoke-CompletionProbe) so an unrecognised
        subcommand -- or a CLI that blocks waiting for input (e.g. wsl) --
        never hangs registration. Returns $null when the CLI is absent or no
        probe yields a real helper.

    .PARAMETER Cli
        The command name to probe (e.g. 'pwsh', 'gk', 'rg').

    .PARAMETER ProbeArgument
        Override the default probe argument-lines (testing / unusual CLIs).

    .PARAMETER TimeoutMs
        Per-probe timeout in milliseconds (default 5000).

    .OUTPUTS
        [pscustomobject] @{ Cli; Invocation; Output } for the winning probe,
        or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [string[]]$ProbeArgument,
        [int]$TimeoutMs = 5000
    )

    if (-not (Get-Command -Name $Cli -ErrorAction SilentlyContinue)) { return $null }

    $probes = if ($ProbeArgument) { $ProbeArgument } else { $script:NativeCompletionProbes }

    foreach ($argLine in $probes) {
        $probe = Invoke-CompletionProbe -Cli $Cli -ArgumentLine $argLine -TimeoutMs $TimeoutMs
        # A CLI that blocks on one completion-style arg (e.g. wsl waiting on a
        # distro) will block on the rest too; stop probing after a timeout so
        # the cost is bounded to a single $TimeoutMs, not the whole list.
        if ($probe.TimedOut) { break }
        $output = $probe.Output
        if ($output -and [regex]::IsMatch($output, $script:NativeCompletionMarker)) {
            return [pscustomobject]@{
                Cli        = $Cli
                Invocation = "$Cli $argLine"
                Output     = $output
            }
        }
    }

    return $null
}

function Resolve-SelfHealingCompleter {
    <#
    .SYNOPSIS
        Prefer a detected native completion helper over a fallback completer,
        advising (low priority) when it supersedes a hand-curated block.

    .DESCRIPTION
        Runs the detector for $Cli. When a native helper is found AND its
        output differs from $FallbackOutput, the native output is adopted and a
        non-terminating Write-Warning advises that the hand-curated block can be
        removed. When the detector finds nothing -- or finds output identical to
        the fallback (i.e. the fallback already IS the native helper, as with
        gh) -- the fallback is returned unchanged and no warning is emitted.

        This keeps native-sourced completers (gh, rg, dotnet) quiet while
        letting hand-curated ones (pwsh, powershell, wsl, gk, ...) upgrade
        themselves the moment the upstream CLI ships a real helper.

    .PARAMETER Cli
        The CLI whose completion is being resolved.

    .PARAMETER FallbackOutput
        The completer text to use when no superseding native helper exists
        (typically a hand-curated Register-ArgumentCompleter here-string, or a
        native command's own output).

    .PARAMETER Detector
        Injectable detector scriptblock taking a single CLI-name argument and
        returning a helper object (or $null). Defaults to
        Find-NativeCompletionHelper. Exists so tests can simulate
        "native present" / "native absent" without a real CLI on PATH.

    .PARAMETER SourceHint
        Optional human-readable location of the hand-curated block (e.g.
        'bucket/PowerShell.ps1') included in the advisory.

    .OUTPUTS
        [pscustomobject] @{ Output; Healed; Invocation }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FallbackOutput,
        [scriptblock]$Detector,
        [string]$SourceHint
    )

    $helper = $null
    try {
        $helper = if ($Detector) { & $Detector $Cli } else { Find-NativeCompletionHelper -Cli $Cli }
    } catch {
        $helper = $null
    }

    if (-not $helper -or -not $helper.Output) {
        return [pscustomobject]@{ Output = $FallbackOutput; Healed = $false; Invocation = $null }
    }

    $nativeText = [string]$helper.Output
    if ($nativeText.Trim() -eq ([string]$FallbackOutput).Trim()) {
        # The fallback is already the native helper (e.g. gh's own
        # `gh completion -s powershell`): adopt nothing, stay silent.
        return [pscustomobject]@{ Output = $FallbackOutput; Healed = $false; Invocation = $helper.Invocation }
    }

    $advisory = "[self-heal] '$Cli' now provides native completion via '$($helper.Invocation)'; the hand-curated completer"
    if ($SourceHint) { $advisory += " in $SourceHint" }
    $advisory += ' is redundant and can be removed.'
    Write-Warning $advisory

    return [pscustomobject]@{ Output = $nativeText; Healed = $true; Invocation = $helper.Invocation }
}
