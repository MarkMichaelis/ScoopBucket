#requires -Version 7.0
# ----------------------------------------------------------------------------
# Part C behavior tests (Pester v5, Light): Register-BucketModule.ps1 is the
# opt-in, per-machine helper that makes the bare `Install-Package <x>` wrapper
# resolve to OUR module. "Installing the module" is two idempotent steps:
#   1. a junction <scoopRoot>\modules\MarkMichaelis.ScoopBucket -> the module
#      source (bucket clone, an explicit path, or the local repo checkout);
#   2. exactly one `Import-Module MarkMichaelis.ScoopBucket` line in $PROFILE.
# Every case runs against TestDrive via the -ScoopRoot/-ProfilePath/-ModulePath
# seams, so the host machine is never touched. See #390 (Part C).
# ----------------------------------------------------------------------------

Set-StrictMode -Version Latest

Describe 'Register-BucketModule' -Tag 'Light', 'Admin' {

    BeforeAll {
        # bucket\admin -> bucket -> repo root
        $script:Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Register-BucketModule.ps1'

        function New-FakeModuleSource {
            param([Parameter(Mandatory)][string]$Path, [string]$Marker = ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'MarkMichaelis.ScoopBucket.psd1') -Value "@{ ModuleVersion = '9.9.9' }" -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Path 'marker.txt') -Value $Marker -Encoding utf8
            return [pscustomobject]@{ Path = $Path; Marker = $Marker }
        }
        function Get-ImportLineCount {
            param([string]$ProfilePath)
            if (-not (Test-Path -LiteralPath $ProfilePath)) { return 0 }
            @(Get-Content -LiteralPath $ProfilePath | Where-Object { $_ -match '^\s*Import-Module\s+MarkMichaelis\.ScoopBucket\s*$' }).Count
        }
        function Test-IsJunction {
            param([string]$Path)
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            return [bool]($item -and $item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))
        }
        function Read-ThroughLink {
            param([string]$LinkDir)
            $p = Join-Path $LinkDir 'marker.txt'
            if (Test-Path -LiteralPath $p) { return (Get-Content -Raw -LiteralPath $p).Trim() }
            return ''
        }
    }

    Context 'installing from an explicit -ModulePath' {
        BeforeEach {
            $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Scoop = Join-Path $script:Root 'scoop'
            $script:Src = New-FakeModuleSource -Path (Join-Path $script:Root 'src\MarkMichaelis.ScoopBucket')
            $script:Prof = Join-Path $script:Root 'profile\Microsoft.PowerShell_profile.ps1'
            $script:Link = Join-Path $script:Scoop 'modules\MarkMichaelis.ScoopBucket'
        }

        It 'creates a junction under <scoopRoot>\modules pointing at the module source' {
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            Test-IsJunction -Path $script:Link | Should -BeTrue
            Read-ThroughLink -LinkDir $script:Link | Should -Be $script:Src.Marker
        }

        It 'adds exactly one Import-Module line to the profile' {
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            Get-ImportLineCount -ProfilePath $script:Prof | Should -Be 1
        }

        It 'is idempotent: a second run keeps one junction and one Import-Module line' {
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            Test-IsJunction -Path $script:Link | Should -BeTrue
            Get-ImportLineCount -ProfilePath $script:Prof | Should -Be 1
        }

        It '-WhatIf makes no changes' {
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof -WhatIf
            Test-Path -LiteralPath $script:Link | Should -BeFalse
            Get-ImportLineCount -ProfilePath $script:Prof | Should -Be 0
        }

        It '-Remove deletes the junction and strips the Import-Module line (leaving the source intact)' {
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            & $script:Script -ScoopRoot $script:Scoop -ProfilePath $script:Prof -Remove
            Test-Path -LiteralPath $script:Link | Should -BeFalse
            Get-ImportLineCount -ProfilePath $script:Prof | Should -Be 0
            # -Remove must delete only the link, never the real module source.
            Test-Path -LiteralPath (Join-Path $script:Src.Path 'MarkMichaelis.ScoopBucket.psd1') | Should -BeTrue
        }

        It '-Remove deletes a junction that carries the ReadOnly attribute (some hosts set it)' {
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            # New-Item -ItemType Junction sets ReadOnly on some hosts; simulate that so a
            # plain (Get-Item).Delete() would fail with Access denied. See PR #391 review.
            $item = Get-Item -LiteralPath $script:Link -Force
            $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::ReadOnly
            & $script:Script -ScoopRoot $script:Scoop -ProfilePath $script:Prof -Remove
            Test-Path -LiteralPath $script:Link | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Src.Path 'MarkMichaelis.ScoopBucket.psd1') | Should -BeTrue
        }

        It 're-points a stale ReadOnly junction to a new source without following the reparse point' {
            & $script:Script -ModulePath $script:Src.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            $item = Get-Item -LiteralPath $script:Link -Force
            $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::ReadOnly
            $src2 = New-FakeModuleSource -Path (Join-Path $script:Root 'src2\MarkMichaelis.ScoopBucket')
            & $script:Script -ModulePath $src2.Path -ScoopRoot $script:Scoop -ProfilePath $script:Prof
            Test-IsJunction -Path $script:Link | Should -BeTrue
            Read-ThroughLink -LinkDir $script:Link | Should -Be $src2.Marker
            # The old source must remain intact -- the delete must not follow the link.
            Test-Path -LiteralPath (Join-Path $script:Src.Path 'MarkMichaelis.ScoopBucket.psd1') | Should -BeTrue
        }
    }

    Context 'discovering the module in the scoop bucket clone' {
        It 'junctions to <scoopRoot>\buckets\*\module\MarkMichaelis.ScoopBucket when no source is given' {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $scoop = Join-Path $root 'scoop'
            $clone = New-FakeModuleSource -Path (Join-Path $scoop 'buckets\MarkMichaelis\module\MarkMichaelis.ScoopBucket')
            $prof = Join-Path $root 'profile.ps1'
            $link = Join-Path $scoop 'modules\MarkMichaelis.ScoopBucket'
            & $script:Script -ScoopRoot $scoop -ProfilePath $prof
            Test-IsJunction -Path $link | Should -BeTrue
            Read-ThroughLink -LinkDir $link | Should -Be $clone.Marker
        }
    }

    Context 'targeting the local repo checkout' {
        It '-FromLocalRepo junctions to the module dir beside the script' {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $scoop = Join-Path $root 'scoop'   # no bucket clone here
            $prof = Join-Path $root 'profile.ps1'
            $link = Join-Path $scoop 'modules\MarkMichaelis.ScoopBucket'
            & $script:Script -FromLocalRepo -ScoopRoot $scoop -ProfilePath $prof
            Test-IsJunction -Path $link | Should -BeTrue
            # With no clone and no -ModulePath, the module can only be reached
            # via the repo checkout beside the script.
            Test-Path -LiteralPath (Join-Path $link 'MarkMichaelis.ScoopBucket.psd1') | Should -BeTrue
        }
    }

    Context 'the RegisterBucketModule manifest wires the script' {
        BeforeAll {
            $script:Manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'RegisterBucketModule.json') | ConvertFrom-Json
        }
        It 'url points at the repo-root Register-BucketModule.ps1' {
            $script:Manifest.url | Should -Be 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/Register-BucketModule.ps1'
        }
        It 'installer runs the downloaded script' {
            ($script:Manifest.installer.script -join "`n") | Should -Match 'Register-BucketModule\.ps1'
        }
        It 'uninstaller reverses with -Remove' {
            ($script:Manifest.uninstaller.script -join "`n") | Should -Match '-Remove'
        }
    }
}
