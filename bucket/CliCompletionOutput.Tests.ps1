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
#   Skipped - CLI not installed in this environment. Empty output is
#             NOT an acceptable skip path: per #73, only CLIs that
#             reliably emit a PowerShell completion script are pinned
#             here, so empty output is a regression.
#   Fail    - CLI installed, command produced empty or non-PS output.
#             This catches a CLI silently changing its `completion`
#             subcommand contract under us, or a version downgrade
#             below the minimum that supports PS completion.
#
# Tagged 'Heavy','CompletionOutput' so it only runs in validate-installs
# (after the install matrix puts the CLIs on PATH).
# ----------------------------------------------------------------------------

Describe 'CliCompletion native command output' -Tag 'Heavy','CompletionOutput' {

    It '<Cli> native command produces a usable PowerShell completion script' -ForEach @(
        @{ Cli = 'gh'; Command = { gh completion -s powershell 2>$null } }
        @{ Cli = 'rg'; Command = { rg --generate complete-powershell 2>$null } }
    ) {
        param($Cli, $Command)

        if (-not (Get-Command $Cli -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "$Cli is not on PATH in this environment."
            return
        }

        $output = & $Command
        $text = ($output | Out-String)

        $text | Should -Not -BeNullOrEmpty -Because "$Cli native command must emit a PowerShell completion script; empty output regressed #73."
        $text | Should -Match 'Register-ArgumentCompleter' -Because "$Cli emitted $($text.Length) chars but no Register-ArgumentCompleter; the CLI's completion subcommand contract may have changed."
    }
}
