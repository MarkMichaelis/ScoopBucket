# ----------------------------------------------------------------------------
# Pinned contract for the curated CLI-completion native map.
#
# Locks the set of CLIs the bucket guarantees will get a tab-completion
# block in the AllUsersAllHosts profile when their owning bundle is
# installed. Regressions here mean either:
#   (a) the curated map in Utils.ps1 silently lost an entry, or
#   (b) the registration helper changed its sentinel format.
#
# Tagged 'Heavy','CompletionPinned' so the standard fast suite is
# unaffected. Validate-installs.yml will invoke this explicitly.
# ----------------------------------------------------------------------------

Describe 'CliCompletion pinned contract — curated native map' -Tag 'Heavy','CompletionPinned' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Utils.ps1')
    }

    It 'includes <Cli> in the curated native map' -ForEach @(
        @{ Cli = 'gh' }
        @{ Cli = 'rg' }
        @{ Cli = 'bw' }
        @{ Cli = 'docker' }
        @{ Cli = 'copilot' }
        @{ Cli = 'gcloud' }
    ) {
        param($Cli)
        $script:CliCompletionNativeMap.ContainsKey($Cli) |
            Should -BeTrue -Because "the curated native map must continue to declare '$Cli'"
    }

    It 'uses sentinel version v1' {
        $script:CompletionSentinelVersion | Should -Be 'v1'
    }
}
