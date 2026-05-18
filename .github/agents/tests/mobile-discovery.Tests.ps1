#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the mobile-app discovery sub-phase (issue #44).
# Exercises import-mobile-app.js in --non-interactive mode, the new SKILL.md
# Phase 1.5 section, the README.MobileDiscovery.md.tmpl token contract,
# and the --source-label flag added to detect-auth.js.

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:ImportJs   = Join-Path $script:ScriptsDir 'import-mobile-app.js'
    $script:DetectJs   = Join-Path $script:ScriptsDir 'detect-auth.js'
    $script:CsharpDir  = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/csharp'
    $script:ManifestPath = Join-Path $script:CsharpDir 'manifest.json'
    $script:SkillPath  = Join-Path $script:RepoRoot '.github/skills/api-wrapper-scaffold/SKILL.md'
    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures/har'

    function Invoke-Import {
        param([Parameter(Mandatory)][string[]]$Args)
        $stdout = & node $script:ImportJs @Args 2>$null
        return @{
            ExitCode = $LASTEXITCODE
            Output   = ($stdout -join "`n")
        }
    }
}

Describe 'import-mobile-app.js (non-interactive instruction printer)' {

    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:ImportJs | Should -BeTrue
    }

    It 'android + proxy: prints mitmproxy, CA cert, and Samples/HAR-Original export path' {
        $r = Invoke-Import @('--non-interactive', '--platform=android', '--mode=proxy')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'mitmproxy'
        $r.Output   | Should -Match 'CA certificate'
        $r.Output   | Should -Match 'Samples/HAR-Original/'
    }

    It 'ios + proxy: prints iOS Certificate Trust setting steps' {
        $r = Invoke-Import @('--non-interactive', '--platform=ios', '--mode=proxy')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'Settings'
        $r.Output   | Should -Match 'Certificate Trust'
        $r.Output   | Should -Match 'mitmproxy'
    }

    It 'android + decompile: references jadx and adb' {
        $r = Invoke-Import @('--non-interactive', '--platform=android', '--mode=decompile')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'jadx'
        $r.Output   | Should -Match 'adb'
        $r.Output   | Should -Match 'Samples/MobileApp-Discovered/android-endpoints.txt'
    }

    It 'ios + decompile: references class-dump' {
        $r = Invoke-Import @('--non-interactive', '--platform=ios', '--mode=decompile')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'class-dump'
        $r.Output   | Should -Match 'Samples/MobileApp-Discovered/ios-endpoints.txt'
    }

    It 'both + both: prints all four platform/mode combinations' {
        $r = Invoke-Import @('--non-interactive', '--platform=both', '--mode=both')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'mitmproxy'
        $r.Output   | Should -Match 'jadx'
        $r.Output   | Should -Match 'class-dump'
        $r.Output   | Should -Match 'Certificate Trust'
    }

    It 'prints a legal/ToS warning about decompilation' {
        $r = Invoke-Import @('--non-interactive', '--platform=android', '--mode=decompile')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match '(?i)legal|terms of service|permitted'
    }

    It '--validate-only reports failure when expected HAR file is absent' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mobile-disc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            & node $script:ImportJs '--validate-only' "--har-dir=$tmp" '--platform=android' '--mode=proxy' 2>$null
            $LASTEXITCODE | Should -Not -Be 0
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
    }

    It '--validate-only succeeds when a matching mobile-<platform>-*.har file exists' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mobile-disc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $tmp 'mobile-android-20260101T000000Z.har') -Value '{"log":{"entries":[]}}' -NoNewline
            & node $script:ImportJs '--validate-only' "--har-dir=$tmp" '--platform=android' '--mode=proxy' 2>$null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'rejects unknown --platform values' {
        $r = Invoke-Import @('--non-interactive', '--platform=blackberry', '--mode=proxy')
        $r.ExitCode | Should -Not -Be 0
    }

    It 'android + download: prints adb pull, gplaycli, and Samples/MobileApp-Binaries path' {
        $r = Invoke-Import @('--non-interactive', '--platform=android', '--mode=download')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'adb pull'
        $r.Output   | Should -Match '(?i)gplaycli|APKMirror|APKPure'
        $r.Output   | Should -Match 'Samples/MobileApp-Binaries/'
        $r.Output   | Should -Match '\.apk'
    }

    It 'ios + download: references ipatool and Apple Configurator / iMazing' {
        $r = Invoke-Import @('--non-interactive', '--platform=ios', '--mode=download')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'ipatool'
        $r.Output   | Should -Match '(?i)Apple Configurator|iMazing'
        $r.Output   | Should -Match 'Samples/MobileApp-Binaries/'
        $r.Output   | Should -Match '\.ipa'
    }

    It 'download mode prints a legal / ToS reminder' {
        $r = Invoke-Import @('--non-interactive', '--platform=android', '--mode=download')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match '(?i)legal|terms of service|permitted|redistribut'
    }

    It '--mode=both expands to include download instructions for both platforms' {
        $r = Invoke-Import @('--non-interactive', '--platform=both', '--mode=both')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'adb pull'
        $r.Output   | Should -Match 'ipatool'
    }
}

Describe 'detect-auth.js --source-label integration' {

    It 'classifies the mobile-android-bearer fixture as bearer' {
        $har = Join-Path $script:FixturesDir 'mobile-android-bearer.har'
        Test-Path -LiteralPath $har | Should -BeTrue
        $out = & node $script:DetectJs $har 2>$null
        $LASTEXITCODE | Should -Be 0
        $r = ($out -join "`n") | ConvertFrom-Json
        $r.authModel | Should -Be 'bearer'
    }

    It 'tags every evidence entry with source when --source-label is given' {
        $har = Join-Path $script:FixturesDir 'mobile-android-bearer.har'
        $out = & node $script:DetectJs $har '--source-label=mobile-android' 2>$null
        $LASTEXITCODE | Should -Be 0
        $r = ($out -join "`n") | ConvertFrom-Json
        $r.authModel | Should -Be 'bearer'
        $r.evidence.Count | Should -BeGreaterThan 0
        foreach ($e in $r.evidence) {
            $e.source | Should -Be 'mobile-android'
        }
    }

    It 'omits the source field when --source-label is not given (backwards compatible)' {
        $har = Join-Path $script:FixturesDir 'mobile-android-bearer.har'
        $out = & node $script:DetectJs $har 2>$null
        $r = ($out -join "`n") | ConvertFrom-Json
        # Each evidence entry should have no "source" property when label absent.
        foreach ($e in $r.evidence) {
            $e.PSObject.Properties.Name | Should -Not -Contain 'source'
        }
    }
}

Describe 'api-wrapper-scaffold SKILL.md mobile-discovery section' {

    BeforeAll {
        $script:SkillText = Get-Content -LiteralPath $script:SkillPath -Raw
    }

    It 'introduces "Phase 1.5" referencing the mobile app discovery sub-phase' {
        $script:SkillText | Should -Match 'Phase 1\.5'
        $script:SkillText | Should -Match '(?i)mobile app'
    }

    It 'documents the y/N opt-in prompt' {
        $script:SkillText | Should -Match '\[y/N\]'
    }

    It 'mentions iOS, Android, proxy, and decompile capture options' {
        $script:SkillText | Should -Match '(?i)iOS'
        $script:SkillText | Should -Match '(?i)Android'
        $script:SkillText | Should -Match '(?i)proxy'
        $script:SkillText | Should -Match '(?i)decompile'
    }

    It 'documents the download mode for acquiring APK / IPA binaries' {
    $script:SkillText | Should -Match '(?i)download'
    $script:SkillText | Should -Match '(?i)\.apk'
    $script:SkillText | Should -Match '(?i)\.ipa'
    }

    It 'preserves the existing 11 ordered phases' {
        1..11 | ForEach-Object {
            $script:SkillText | Should -Match "Phase $_ --"
        }
    }
}

Describe 'README.MobileDiscovery.md.tmpl + manifest' {

    It 'README.MobileDiscovery.md.tmpl exists and is declared in manifest.json' {
        $tmpl = Join-Path $script:CsharpDir 'README.MobileDiscovery.md.tmpl'
        Test-Path -LiteralPath $tmpl | Should -BeTrue
        $manifest = Get-Content -Raw $script:ManifestPath | ConvertFrom-Json
        $entry = $manifest.templates | Where-Object { $_.file -eq 'README.MobileDiscovery.md.tmpl' }
        $entry | Should -Not -BeNullOrEmpty
    }

    It 'manifest declares the HasMobileCoverage and MobileHarPaths tokens' {
        $manifest = Get-Content -Raw $script:ManifestPath | ConvertFrom-Json
        $manifest.tokens.HasMobileCoverage | Should -Not -BeNullOrEmpty
        $manifest.tokens.MobileHarPaths    | Should -Not -BeNullOrEmpty
    }
}