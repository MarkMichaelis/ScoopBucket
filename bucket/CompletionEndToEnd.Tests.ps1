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
    the AllUsersAllHosts profile contains the sentinel block written by
    Register-PackageCompletion. Each row spawns `pwsh -NoProfile`, dot-
    sources the profile, then calls [CommandCompletion]::CompleteInput
    so PowerShell's real completion engine produces the candidate list.
    No mocks of psc, Register-ArgumentCompleter, or anything else —
    this is the spec for "Tab actually works."
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    $script:allPkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:completionCases = @(
        foreach ($p in $script:allPkgs) {
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

    $script:profilePath = $PROFILE.AllUsersAllHosts
    $script:profileExists = $script:profilePath -and (Test-Path $script:profilePath)
}

Describe 'Completion end-to-end (real Tab, no mocks)' -Tag 'Heavy','Completion' {

    It '<Package>/<Cli> sentinel block is present in AllUsersAllHosts profile' -ForEach $script:completionCases {
        if (-not $script:profileExists) {
            Set-ItResult -Skipped -Because "AllUsersAllHosts profile missing at $script:profilePath; run Install-Package first."
            return
        }
        $raw = Get-Content -Raw -Path $script:profilePath
        $raw | Should -Match "ScoopBucket:CliCompletion:$([regex]::Escape($Cli)):BEGIN"
    }

    It '<Package>/<Cli> TabExpansion2 returns expected subcommands' -ForEach $script:completionCases {
        if (-not $script:profileExists) {
            Set-ItResult -Skipped -Because "AllUsersAllHosts profile missing; nothing to load."
            return
        }
        if (-not (Get-Command $Cli -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "CLI '$Cli' not on PATH on this host; Install-Package may have been skipped."
            return
        }

        $script = @"
`$ErrorActionPreference = 'Stop'
. '$($script:profilePath -replace "'","''")'
# Profile blocks defer Register-ArgumentCompleter to PowerShell.OnIdle (#212).
# Drain any pending subscribers in this non-interactive child runspace before
# asking the completion engine for matches.
foreach (`$sub in @(Get-EventSubscriber -SourceIdentifier 'PowerShell.OnIdle' -ErrorAction SilentlyContinue)) {
    try {
        `$cmd = `$sub.Action.Command
        if (`$cmd) { & ([scriptblock]::Create(`$cmd)) 2>`$null | Out-Null }
    } catch { }
}
`$line = '$Cli '
`$result = [System.Management.Automation.CommandCompletion]::CompleteInput(`$line, `$line.Length, `$null)
`$result.CompletionMatches | ForEach-Object { `$_.CompletionText }
"@
        $tmp = New-TemporaryFile
        try {
            Set-Content -Path $tmp -Value $script -Encoding UTF8
            $out = & pwsh -NoProfile -NoLogo -File $tmp 2>$null
        } finally {
            Remove-Item -Path $tmp -ErrorAction Ignore
        }
        $completions = @($out | Where-Object { $_ })

        foreach ($e in $Expected) {
            $completions | Should -Contain $e -Because "TabExpansion2 for '$Cli ' must return '$e' per the ExpectedCompletions contract; got: $($completions -join ', ')"
        }
    }
}
