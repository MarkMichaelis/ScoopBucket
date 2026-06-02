<#
.SYNOPSIS
    Light-suite coverage for the version-probe helpers behind #283: the pure
    CLI-output parsers (winget/choco/npm/scoop) and Resolve-PackageVersionInfo.

.DESCRIPTION
    These helpers make `Update-Package -WhatIf` accurate (Updated only when a
    newer version really exists) and feed the `from -> to` version column. The
    parsers are pure (text/JSON -> hashtable) and pinned here against canned
    CLI fixtures so a winget/choco/scoop output-format tweak is caught by a
    failing test rather than a silently-wrong summary.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    function script:InModule {
        param([scriptblock]$Block, [object[]]$ArgumentList)
        & (Get-Module MarkMichaelis.ScoopBucket) $Block @ArgumentList
    }
}

Describe 'ConvertFrom-WingetVersionTable' {
    It 'extracts Installed and Available for an upgradable row and leaves Available empty for a current row' {
        $fixture = @(
            'Name              Id                       Version      Available    Source',
            '-----------------------------------------------------------------------------',
            'Claude            Anthropic.Claude         1.9659.2     1.9712.0     winget',
            'Warp              Warp.Warp                0.2026.05.27              winget'
        )
        $map = InModule { param($l) ConvertFrom-WingetVersionTable $l } @(, $fixture)

        $map['anthropic.claude'].Installed | Should -Be '1.9659.2'
        $map['anthropic.claude'].Available | Should -Be '1.9712.0'
        $map['warp.warp'].Installed        | Should -Be '0.2026.05.27'
        $map['warp.warp'].Available        | Should -Be ''
    }

    It 'strips a truncation ellipsis / non-ASCII mojibake from a version cell so it never leaks into the transition' {
        $ellipsis = [char]0x2026
        $fixture = @(
            'Name              Id                       Version          Available        Source',
            '---------------------------------------------------------------------------------------',
            ("Warp              Warp.Warp                v0.2026.05.27.15 v0.2026.05.27.15$ellipsis winget")
        )
        $map = InModule { param($l) ConvertFrom-WingetVersionTable $l } @(, $fixture)

        $map['warp.warp'].Available | Should -Not -Match '[^\x20-\x7E]'
        $map['warp.warp'].Available | Should -Be 'v0.2026.05.27.15'
    }

    It 'returns an empty map when no header row is present' {
        $map = InModule { param($l) ConvertFrom-WingetVersionTable $l } @(, @('no table here'))
        $map.Keys.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-ChocoOutdated' {
    It 'parses the pipe-delimited machine-readable rows' {
        $fixture = @(
            'nodejs|22.14.0|22.15.0|false',
            'exiftool|13.10|13.11|false'
        )
        $map = InModule { param($l) ConvertFrom-ChocoOutdated $l } @(, $fixture)

        $map['nodejs'].Installed   | Should -Be '22.14.0'
        $map['nodejs'].Available   | Should -Be '22.15.0'
        $map['exiftool'].Available | Should -Be '13.11'
    }
}

Describe 'ConvertFrom-NpmOutdated' {
    It 'maps current and latest from the JSON object' {
        $json = '{ "typescript": { "current": "5.3.0", "wanted": "5.3.3", "latest": "5.4.2" } }'
        $map = InModule { param($j) ConvertFrom-NpmOutdated $j } @($json)

        $map['typescript'].Installed | Should -Be '5.3.0'
        $map['typescript'].Available | Should -Be '5.4.2'
    }

    It 'returns an empty map for malformed JSON instead of throwing' {
        $map = InModule { param($j) ConvertFrom-NpmOutdated $j } @('not json')
        $map.Keys.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-ScoopStatus' {
    It 'extracts Installed and Latest for an outdated app' {
        $fixture = @(
            'Name    Installed Version Latest Version Missing Dependencies Info',
            '----    ----------------- -------------- -------------------- ----',
            'ripgrep 14.1.0            14.1.1'
        )
        $map = InModule { param($l) ConvertFrom-ScoopStatus $l } @(, $fixture)

        $map['ripgrep'].Installed | Should -Be '14.1.0'
        $map['ripgrep'].Available | Should -Be '14.1.1'
    }
}

Describe 'Resolve-PackageVersionInfo' {
    BeforeAll {
        $script:index = @{
            winget = @{
                'anthropic.claude' = @{ Installed = '1.9659.2'; Available = '1.9712.0' }
                'warp.warp'        = @{ Installed = '0.2026.05.27'; Available = '' }
            }
            scoop = @{
                'ripgrep' = @{ Installed = '14.1.0'; Available = '14.1.1' }
            }
            dotnetTool = @{
                'aspire.cli' = @{ Installed = '9.0.0'; Available = '' }
            }
        }
    }

    It 'reports UpdateAvailable=true with both versions when a newer version exists' {
        $pkg = [pscustomobject]@{ Installer = 'winget'; Id = 'Anthropic.Claude' }
        $info = InModule { param($p, $i) Resolve-PackageVersionInfo -Package $p -Index $i } @($pkg, $script:index)

        $info.Present         | Should -BeTrue
        $info.UpdateAvailable | Should -BeTrue
        $info.Installed       | Should -Be '1.9659.2'
        $info.Available       | Should -Be '1.9712.0'
    }

    It 'reports UpdateAvailable=false when the installed version is already current' {
        $pkg = [pscustomobject]@{ Installer = 'winget'; Id = 'Warp.Warp' }
        $info = InModule { param($p, $i) Resolve-PackageVersionInfo -Package $p -Index $i } @($pkg, $script:index)

        $info.Present         | Should -BeTrue
        $info.UpdateAvailable | Should -BeFalse
    }

    It 'reports Present=false for a package absent from a winget map' {
        $pkg = [pscustomobject]@{ Installer = 'winget'; Id = 'Not.Installed' }
        $info = InModule { param($p, $i) Resolve-PackageVersionInfo -Package $p -Index $i } @($pkg, $script:index)

        $info.Present | Should -BeFalse
    }

    It 'keys scoop by the bare app name (strips the bucket prefix)' {
        $pkg = [pscustomobject]@{ Installer = 'scoop'; Id = 'MarkMichaelis/ripgrep' }
        # rename the map key to the bare app so the lookup must strip the prefix
        $info = InModule { param($p, $i) Resolve-PackageVersionInfo -Package $p -Index $i } @($pkg, $script:index)

        $info.UpdateAvailable | Should -BeTrue
        $info.Available       | Should -Be '14.1.1'
    }

    It 'returns UpdateAvailable=null (unknown) for dotnetTool' {
        $pkg = [pscustomobject]@{ Installer = 'dotnetTool'; Id = 'Aspire.Cli' }
        $info = InModule { param($p, $i) Resolve-PackageVersionInfo -Package $p -Index $i } @($pkg, $script:index)

        $info.Present         | Should -BeTrue
        $info.UpdateAvailable | Should -BeNullOrEmpty
    }

    It 'returns all-unknown when the installer was not probed at all' {
        $pkg = [pscustomobject]@{ Installer = 'choco'; Id = 'nodejs' }
        $info = InModule { param($p, $i) Resolve-PackageVersionInfo -Package $p -Index $i } @($pkg, $script:index)

        $info.Present         | Should -BeNullOrEmpty
        $info.UpdateAvailable | Should -BeNullOrEmpty
    }
}
