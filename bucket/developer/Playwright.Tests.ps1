#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Playwright member manifest (issue #417).

.DESCRIPTION
    Playwright used to be installed as a side effect of the AIAgents MCP
    configuration step. It is now a first-class package: a global npm install
    of @playwright/test (which carries the `playwright` CLI) plus an
    out-of-band download of the Chromium browser binaries, which npm never
    installs on its own.

    These tests lock in that contract:
      * the manifest runs the bundle script (not an inline installer line),
      * the package uses the npmGlobal engine against @playwright/test,
      * the Chromium download lives in ConfigScript -- re-applied on every
        install AND every update -- rather than install-only PostInstallScript,
      * only Chromium is downloaded (the full browser set costs several GB),
      * `playwright` ships a curated argument completer.

    Tagged 'Light' -- parses the manifest and harvests the declarative
    [Package] entries; no install side effects.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    $script:ManifestPath = Join-Path $PSScriptRoot 'Playwright.json'
    $script:Manifest = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    $script:Playwright = @(Get-Package -BucketPath $PSScriptRoot | Where-Object { $_.Bundle -eq 'Playwright' })
    # Code only: the header comment mentions the browsers a user may add by
    # hand, which must not be mistaken for the script installing them.
    $script:CodeText = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Playwright.ps1') |
        Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}

Describe 'Playwright manifest' -Tag 'Light' {

    It 'downloads its own bundle script' {
        @($script:Manifest.url) | Should -Contain 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/bucket/developer/Playwright.ps1'
    }

    It 'runs the bundle script as its installer' {
        ($script:Manifest.installer.script -join "`n") | Should -Match 'Playwright\.ps1'
    }
}

Describe 'Playwright package declaration' -Tag 'Light','Bundle','Completion' {

    It 'declares exactly one package' {
        $script:Playwright.Count | Should -Be 1
    }

    It 'installs @playwright/test globally via npm' {
        $script:Playwright[0].Installer | Should -Be 'npmGlobal'
        $script:Playwright[0].Id | Should -Be '@playwright/test'
    }

    It 'declares CliCommands=playwright' {
        @($script:Playwright[0].CliCommands) | Should -Be @('playwright')
    }

    It "uses Completion='auto' with a curated completer" {
        $script:Playwright[0].Completion | Should -Be 'auto'
        $script:Playwright[0].HasNativeCommandScript | Should -BeTrue
        # playwright ships no `completion powershell` subcommand, so the
        # completer is hand-maintained rather than sourced from the tool.
        "$($script:Playwright[0].NativeCompletionKind)" | Should -Be ''
    }

    It 'declares non-empty ExpectedCompletions for playwright' {
        $script:Playwright[0].ExpectedCompletions.ContainsKey('playwright') | Should -BeTrue
        foreach ($expected in 'test','install','codegen','show-report') {
            $script:Playwright[0].ExpectedCompletions['playwright'] | Should -Contain $expected
        }
    }

    It 'renders a Register-ArgumentCompleter -Native for playwright' {
        $rendered = $script:Playwright[0].NativeCommandOutputs['playwright']
        $rendered | Should -Not -BeNullOrEmpty
        $rendered | Should -Match 'Register-ArgumentCompleter\s+-Native'
        $rendered | Should -Match '-CommandName\s+playwright'
        foreach ($sub in "'test'","'install'","'codegen'","'show-report'") {
            $rendered | Should -BeLike "*$sub*"
        }
    }
}

Describe 'Playwright browser download' -Tag 'Light','Bundle' {

    It 'downloads browsers from ConfigScript so an npm-only upgrade cannot leave the CLI without a matching browser' {
        # PostInstallScript is install-only and PostUpdateScript is skipped on
        # no-op updates; only ConfigScript is re-applied every time.
        $script:Playwright[0].HasConfigScript | Should -BeTrue
        $script:Playwright[0].HasPostInstallScript | Should -BeFalse
    }

    It 'downloads Chromium only' {
        $script:CodeText | Should -Match '(?i)install\s+chromium'
        $script:CodeText | Should -Not -Match '(?i)install\s+firefox'
        $script:CodeText | Should -Not -Match '(?i)install\s+webkit'
        # A bare `playwright install` would pull down all three browsers.
        $script:CodeText | Should -Not -Match '(?i)playwright(\.cmd)?\s+install\s*(\r?\n|$)'
    }

    It 'falls back to npx when the global shim is not yet on PATH' {
        $script:CodeText | Should -Match '(?i)npx'
    }

    It 'warns instead of throwing when no Node runtime is present' {
        $script:CodeText | Should -Match '(?i)Write-Warning'
    }
}
