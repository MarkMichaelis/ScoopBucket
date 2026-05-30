# ----------------------------------------------------------------------------
# Pinned contract for per-bundle CLI tab-completion registration.
#
# Each curated CLI must be registered by its owning bundle's install script
# via `Register-CliCompletion -Cli <name> -NativeCommand { ... }`. This
# replaces the old central `$CliCompletionNativeMap` in Utils.ps1 — knowledge
# of how to generate completion for a given CLI now lives next to its
# install, not in a shared catalog. Regressions here mean either:
#   (a) a bundle silently lost its native-registration line, or
#   (b) the helper signature changed.
#
# Tagged 'Heavy','CompletionPinned' so the standard fast suite is
# unaffected. Validate-installs.yml will invoke this explicitly.
# ----------------------------------------------------------------------------

Describe 'CliCompletion pinned contract -- per-bundle native registration' -Tag 'Heavy','CompletionPinned' {

    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
        $script:allPkgs = @(Get-Package -BucketPath $PSScriptRoot)
    }

    # gh is still wired through the legacy procedural Register-CliCompletion
    # path in GitConfigure.ps1 (the install block lives inside a function, not
    # a declarative [Package]). Keep the original pattern assertion for it.
    It 'gh is registered with -NativeCommand in GitConfigure.ps1' {
        $path = Join-Path $PSScriptRoot 'GitConfigure.ps1'
        Test-Path $path | Should -BeTrue
        $content = Get-Content -Raw -Path $path
        $pattern = "(?ms)Register-CliCompletion\b[^\r\n]*?-Cli\s+['`"]?gh['`"]?\b[^\r\n]*?-NativeCommand"
        $content | Should -Match $pattern -Because "GitConfigure.ps1 must call Register-CliCompletion -Cli gh -NativeCommand { ... }"
    }

    # rg, bw, gcloud, and the sysinternals shims live in declarative [Package]
    # manifests. Their wiring is asserted at the manifest level: each Package
    # owning <Cli> must declare both NativeCommandScript and ExpectedCompletions
    # (so CompletionEndToEnd.Tests.ps1 can verify Tab actually returns those).
    It '<Cli> Package in <Bundle> declares NativeCommandScript + ExpectedCompletions' -ForEach @(
        @{ Cli = 'rg';     Bundle = 'OSBasePackages' }
        @{ Cli = 'bw';     Bundle = 'ClientBasePackages' }
        @{ Cli = 'gcloud'; Bundle = 'OSBasePackages' }
    ) {
        param($Cli, $Bundle)

        $owning = @($script:allPkgs | Where-Object {
            $_.Bundle -eq $Bundle -and ($_.CliCommands -contains $Cli)
        })
        $owning.Count | Should -BeGreaterThan 0 -Because "a [Package] in bundle '$Bundle' must list '$Cli' in CliCommands"

        $pkg = $owning[0]
        # Get-Package marshalls Packages across runspaces; the actual
        # scriptblock cannot round-trip, so we assert HasNativeCommandScript
        # (the cross-runspace-safe boolean projection).
        $pkg.HasNativeCommandScript | Should -BeTrue -Because "Package owning '$Cli' must supply NativeCommandScript"
        $pkg.ExpectedCompletions | Should -Not -BeNullOrEmpty -Because "Package owning '$Cli' must supply ExpectedCompletions"
        $pkg.ExpectedCompletions.ContainsKey($Cli) | Should -BeTrue -Because "ExpectedCompletions must have a key for '$Cli'"
        @($pkg.ExpectedCompletions[$Cli]).Count | Should -BeGreaterThan 0 -Because "ExpectedCompletions['$Cli'] must list at least one expected subcommand"
    }

    It 'uses sentinel version v3' {
        # $script:CompletionSentinelVersion lives inside the module and is not
        # visible from this test runspace; assert against the source instead so
        # any bump of the sentinel format requires updating this guard too.
        # v3 (#216) persists each cached native completer payload to a
        # sidecar .ps1 file under $env:ProgramData\ScoopBucket\completions
        # and emits a tiny `. '<sidecar>.ps1'` dot-source inside the OnIdle
        # Action body. This is required because clap/Rust-derived completers
        # emit a leading `using namespace System.Management.Automation` which
        # the parser only accepts as the FIRST statement of a script file --
        # never inside an if/Action scriptblock (v2's regression).
        $src = Get-Content -Raw -Path (Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\Private\Register-PackageCompletion.ps1')
        $src | Should -Match "(?m)^\s*\`$script:CompletionSentinelVersion\s*=\s*'v3'\s*$" -Because 'Register-PackageCompletion.ps1 must pin sentinel version v3'
    }

    It 'Register-CliCompletion exposes the -NativeCommand parameter' {
        (Get-Command Register-CliCompletion).Parameters.ContainsKey('NativeCommand') | Should -BeTrue
        (Get-Command Register-CliCompletion).Parameters['NativeCommand'].ParameterType | Should -Be ([scriptblock])
    }
}
