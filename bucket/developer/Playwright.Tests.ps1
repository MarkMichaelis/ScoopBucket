#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Playwright member manifest (issue #417).

.DESCRIPTION
    Playwright used to be installed as a side effect of the AIAgents MCP
    configuration step. It is now a first-class package: a global npm install
    of the `playwright` driver (which carries the CLI and the module other
    tools resolve as require('playwright')) plus an
    out-of-band download of the Chromium browser binaries, which npm never
    installs on its own.

    These tests lock in that contract:
      * the manifest runs the bundle script (not an inline installer line),
      * the package installs `playwright` -- the driver, never the
        `@playwright/test` runner (#423) -- and drives that install itself,
        because the conflicting runner has to be removed first and the module
        never runs top-level bundle code,
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

    It 'drives its own global npm install of the browser driver' {
        # Not the npmGlobal engine: the conflicting runner has to be removed
        # BEFORE npm runs, and there is no pre-install hook (#423).
        $script:Playwright[0].Installer | Should -Be 'custom'
        $script:Playwright[0].Id | Should -Be 'playwright'
        $script:Playwright[0].HasCustomInstallScript | Should -BeTrue
    }

    It 'installs the driver, NOT the test runner (issue #423)' {
        # `playwright` and `@playwright/test` are different packages. The
        # runner is a per-project dependency, and installing it globally does
        # NOT make `playwright` resolvable from the global root -- the runner
        # only carries a nested copy, which is an npm implementation detail.
        # Anything doing require('playwright') then fails while the install
        # reports success. Swapping these back would look harmless because
        # the `playwright` COMMAND resolves either way.
        $script:Playwright[0].Id | Should -Not -Be '@playwright/test' `
            -Because 'the test runner does not make the playwright module resolvable'
        # The Notes field names the runner to explain the choice, so match on
        # invocations rather than on the string appearing anywhere.
        # \binstall\b does not match inside "uninstall", so the migration's
        # removal of the runner is correctly not counted as installing it.
        $script:CodeText | Should -Not -Match '(?im)^\s*&\s*(npm|npx)[^\r\n]*\binstall\b[^\r\n]*@playwright/test' `
            -Because 'not even the npx fallback may reach for the runner'
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

Describe 'Playwright migrates off the conflicting test runner (issue #423)' -Tag 'Light','Bundle' {

    # Both packages publish a `playwright` bin, so npm refuses to install the
    # driver while a global @playwright/test owns those shims (EEXIST). The
    # removal must therefore precede the install.

    BeforeAll {
        # Get-Package returns a metadata projection (Has*Script booleans), so
        # harvest the real [Package] to read the scriptblocks themselves.
        $harvested = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($bundle)
            Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq 'Playwright'
        } (Join-Path $PSScriptRoot 'Playwright.ps1')
        $script:InstallBody = "$($harvested.CustomInstallScript)"
        $script:UpdateBody = "$($harvested.PostUpdateScript)"
        $script:UninstallBody = "$($harvested.CustomUninstallScript)"
    }

    It 'carries the migration where the module can actually reach it' {
        # THE regression guard for this package. Get-BundlePackageObjects
        # harvests only the $Packages assignment and never runs the rest of the
        # file, so a migration written as top-level code is silently skipped by
        # Install-Package / Update-Package -- this module's primary interface --
        # and only a raw `scoop install` would ever run it. Living inside the
        # harvested scriptblocks is what makes it reachable everywhere.
        $script:Playwright[0].HasCustomInstallScript | Should -BeTrue
        $script:Playwright[0].HasPostUpdateScript | Should -BeTrue `
            -Because 'a custom package gets no other update hook'
        foreach ($body in $script:InstallBody, $script:UpdateBody) {
            $body | Should -Match "(?i)\`$superseded\s*=\s*'@playwright/test'" `
                -Because 'the superseded runner is named once, as history rather than configuration'
            $body | Should -Match '(?i)npm(\.cmd)?\s+uninstall\s+--global\s+\$superseded' `
                -Because 'the driver install fails with EEXIST while the runner owns the playwright shims'
        }
    }

    It 'installs whatever Id declares, rather than a hardcoded twin' {
        # Id would be decoration if the hooks hardcoded the package name, and
        # the two could drift apart silently.
        foreach ($body in $script:InstallBody, $script:UpdateBody) {
            $body | Should -Match '(?i)npm(\.cmd)?\s+install\s+--global\s+\$Package\.Id'
        }
        $script:UninstallBody | Should -Match '(?i)npm(\.cmd)?\s+uninstall\s+--global\s+\$Package\.Id'
    }

    It 'removes the runner before installing the driver, in both hooks' {
        foreach ($body in $script:InstallBody, $script:UpdateBody) {
            $removeAt = $body.IndexOf('uninstall --global $superseded')
            $addAt = $body.IndexOf('install --global $Package.Id')
            $removeAt | Should -BeGreaterThan -1
            $addAt | Should -BeGreaterThan -1
            $removeAt | Should -BeLessThan $addAt `
                -Because 'installing first would just hit the EEXIST this exists to avoid'
        }
    }

    It 'only removes it when it is actually installed' {
        foreach ($body in $script:InstallBody, $script:UpdateBody) {
            $body | Should -Match '(?i)npm(\.cmd)?\s+list\s+-g' `
                -Because 'an unconditional uninstall would not be a no-op on a clean machine'
            $body | Should -Match '(?i)Escape\(\$superseded\)' `
                -Because 'the guard must match the installed runner, not any mention of it'
        }
    }

    It 'fails loudly when the removal fails, rather than walking into EEXIST' {
        # A custom install that throws is marked Failed. Continuing would hit a
        # guaranteed EEXIST and report the confusing file-exists error instead.
        foreach ($body in $script:InstallBody, $script:UpdateBody) {
            $body | Should -Match '(?i)throw[^\r\n]*EEXIST'
        }
    }

    It 'only ever touches the global runner, never a project dependency' {
        foreach ($body in $script:InstallBody, $script:UpdateBody) {
            $body | Should -Not -Match '(?i)package\.json'
            $body | Should -Not -Match "(?im)^\s*&\s*npm(\.cmd)?\s+uninstall\s+(?!--global)"
        }
    }

    It 'short-circuits the install when the driver is already there' {
        $script:InstallBody | Should -Match '(?i)already installed globally' `
            -Because 'the idempotency contract: a second install must change nothing'
    }

    It 'always reinstalls on update, because that is npm''s upgrade path' {
        $script:UpdateBody | Should -Not -Match '(?i)already installed globally' `
            -Because 'short-circuiting on update would pin the driver at its installed version forever'
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
