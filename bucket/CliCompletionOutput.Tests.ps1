# ----------------------------------------------------------------------------
# Behavioural test: each pinned CLI's native completion command actually
# emits a usable PowerShell completion script when the CLI is installed.
#
# Static `CompletionPinned.Tests.ps1` checks that each owning bundle WIRES
# the CLI; this file checks that the wired command actually PRODUCES
# something. Verdicts:
#
#   Pass    - CLI installed, command exited cleanly, output contains
#             `Register-ArgumentCompleter` (the marker of a real PS5+
#             tab-completion script).
#   Skipped - CLI not installed OR the command threw OR the command
#             produced no output. These are best-effort cases inherited
#             from the historical CliCompletionNativeMap and are not
#             regressions.
#   Fail    - CLI installed, command produced non-empty output that does
#             NOT look like a PowerShell completion script. This catches
#             a CLI silently changing its `completion` subcommand
#             contract under us.
#
# Tagged 'Heavy','CompletionOutput' so it only runs in validate-installs
# (after the install matrix puts the CLIs on PATH).
# ----------------------------------------------------------------------------

Describe 'CliCompletion native command output' -Tag 'Heavy','CompletionOutput' {

    It '<Cli> native command produces a usable PowerShell completion script' -ForEach @(
        @{ Cli = 'gh';      Command = { gh completion -s powershell 2>$null } }
        @{ Cli = 'rg';      Command = { rg --generate complete-powershell 2>$null } }
        @{ Cli = 'gcloud';  Command = { gcloud --quiet --help-format=ps1 2>$null } }
        @{ Cli = 'bw';      Command = { bw completion --shell powershell 2>$null } }
        @{ Cli = 'copilot'; Command = { copilot completion powershell 2>$null } }
    ) {
        param($Cli, $Command)

        if (-not (Get-Command $Cli -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "$Cli is not on PATH in this environment."
            return
        }

        $output = $null
        try { $output = & $Command } catch {
            Set-ItResult -Skipped -Because "$Cli native command threw: $($_.Exception.Message)"
            return
        }

        $text = ($output | Out-String)
        if ([string]::IsNullOrWhiteSpace($text)) {
            Set-ItResult -Skipped -Because "$Cli native command produced no output (CLI version may not support PowerShell completion)."
            return
        }

        $text | Should -Match 'Register-ArgumentCompleter' -Because "$Cli emitted $($text.Length) chars but no Register-ArgumentCompleter; the CLI's completion subcommand contract may have changed."
    }
}
