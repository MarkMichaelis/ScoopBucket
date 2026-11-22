#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    End-to-end (no mocks) tab-completion tests: for every Package
    declaring Completion != 'none', press Tab after `<cli> ` in a fresh
    pwsh runspace and verify the manifest-declared ExpectedCompletions
    actually appear.

.DESCRIPTION
    Heavy-tag suite. Assumes the CLI under test is already installed on
    PATH (i.e. validate-installs.yml has run Install-Package first) and
    the CurrentUserAllHosts profile contains the sentinel block written by
    Register-PackageCompletion. Each row spawns `pwsh -NoProfile`, dot-
    sources the profile, then calls [CommandCompletion]::CompleteInput
    so PowerShell's real completion engine produces the candidate list.
    No mocks of psc, Register-ArgumentCompleter, or anything else —
    this is the spec for "Tab actually works."

    The cases MUST be built in BeforeDiscovery: -ForEach is evaluated at
    discovery, before any BeforeAll runs. Built in BeforeAll (as they were
    until #513) the list is always $null there, so the suite silently
    generated zero tests. The Light guard below fails if that recurs.
#>

BeforeDiscovery {
    $moduleManifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $moduleManifest -Force

    $script:completionCases = @(
        foreach ($p in @(Get-Package -BucketPath $PSScriptRoot)) {
            if ($p.Completion -eq 'none') { continue }
            foreach ($cli in @($p.CliCommands)) {
                @{
                    Bundle   = $p.Bundle
                    Package  = $p.Name
                    Cli      = $cli
                    Expected = @($p.ExpectedCompletions[$cli])
                }
            }
        }
    )
}

BeforeAll {
    $script:profilePath = $PROFILE.CurrentUserAllHosts
    $script:profileExists = $script:profilePath -and (Test-Path $script:profilePath)
}

Describe 'Completion end-to-end case discovery' -Tag 'Light' -ForEach @(@{ Cases = $script:completionCases }) {

    It 'discovers a case for every declared CLI with completion (#513)' {
        @($Cases).Count | Should -BeGreaterThan 0 -Because 'an empty list means the Heavy suite below silently runs nothing'
        @($Cases | ForEach-Object { $_.Cli }) | Should -Contain 'rg'
    }
}

Describe 'Completion end-to-end (real Tab, no mocks)' -Tag 'Heavy','Completion' {

    It '<Package>/<Cli> sentinel block is present in the completion profile' -ForEach $script:completionCases {
        if (-not $script:profileExists) {
            Set-ItResult -Skipped -Because "Completion profile missing at $script:profilePath; run Install-Package first."
            return
        }
        # Registration only writes a block for a CLI that is installed, so an
        # absent CLI has nothing to assert (mirrors the Tab test below).
        if (-not (Get-Command $Cli -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "CLI '$Cli' not on PATH on this host; Install-Package may have been skipped."
            return
        }
        $raw = Get-Content -Raw -Path $script:profilePath
        $raw | Should -Match "ScoopBucket:CliCompletion:$([regex]::Escape($Cli)):BEGIN"
    }

    It '<Package>/<Cli> TabExpansion2 returns expected subcommands' -ForEach $script:completionCases {
        if (-not $script:profileExists) {
            Set-ItResult -Skipped -Because "Completion profile missing; nothing to load."
            return
        }
        if (-not (Get-Command $Cli -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "CLI '$Cli' not on PATH on this host; Install-Package may have been skipped."
            return
        }

        # Load the two profiles every host loads, in the engine's order:
        # AllUsersAllHosts, then CurrentUserAllHosts. Some CLIs complete from
        # a module the machine profile imports rather than from a block of
        # ours -- git stands aside for posh-git, which GitConfigure.ps1 adds
        # to AllUsersAllHosts. Host-specific profiles are deliberately left
        # out: they carry interactive, per-user startup work.
        $profileList = (@($PROFILE.AllUsersAllHosts, $script:profilePath) |
            Where-Object { $_ } | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
        $script = @"
`$ErrorActionPreference = 'Stop'
foreach (`$p in @($profileList)) { if (Test-Path -LiteralPath `$p) { . `$p } }
# Profile blocks defer Register-ArgumentCompleter to PowerShell.OnIdle (#212).
# OnIdle never fires in a non-interactive child, so raise it and let the
# engine run the subscriber as an interactive shell would. Re-running the
# Action's text with & would dot-source each sidecar into a throwaway scope
# and lose the helper functions Cobra-generated completers call (#539).
`$null = New-Event -SourceIdentifier PowerShell.OnIdle
for (`$i = 0; `$i -lt 250 -and `$Global:__ScoopBucketCompletionQueue -and `$Global:__ScoopBucketCompletionQueue.Count; `$i++) {
    Start-Sleep -Milliseconds 20
}
`$line = '$Cli '
`$result = [System.Management.Automation.CommandCompletion]::CompleteInput(`$line, `$line.Length, `$null)
`$result.CompletionMatches | ForEach-Object { `$_.CompletionText }
"@
        # pwsh -File refuses any extension but .ps1, so New-TemporaryFile's
        # .tmp made every case run nothing (#539).
        $probeFile = Join-Path $TestDrive ("e2e-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -Path $probeFile -Value $script -Encoding UTF8
        $raw = @(& pwsh -NoProfile -NoLogo -NonInteractive -File $probeFile 2>&1)
        $childErrors = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
        $completions = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and "$_" } | ForEach-Object { "$_" })

        foreach ($e in $Expected) {
            $completions | Should -Contain $e -Because "TabExpansion2 for '$Cli ' must return '$e' per the ExpectedCompletions contract; got: $($completions -join ', '); child errors: $($childErrors -join ' | ')"
        }
    }
}
