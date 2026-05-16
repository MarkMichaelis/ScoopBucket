#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Light unit coverage for Update-LocalManifestInstallMetadata — the
    helper Install-LocalManifest invokes post-install to repair
    ~/scoop/apps/<App>/current/install.json and manifest.json after a
    working-copy `scoop install <temp manifest>` (issue #62).

.DESCRIPTION
    Synthesises a fake ~/scoop/apps tree under TestDrive: with the same
    layout scoop produces (current/ junction + version dir, each with
    install.json + manifest.json) and asserts:

      * install.json.bucket is set to MarkMichaelis in BOTH dirs.
      * manifest.json.url[] is rewritten back to canonical
        raw.githubusercontent.com/MarkMichaelis/ScoopBucket/master URLs.
      * Missing files / malformed JSON / read-only files do NOT throw
        (install.json is internal Scoop API; helper must be best-effort).
      * Calling the helper twice is idempotent.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $scoopBucketPsd1 -Force

    function script:New-FakeScoopApp {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$AppName,
            [string]$Version = '1.0.000',
            [string[]]$LocalUrls = @('file:///D:/Git/ScoopBucket/bucket/Sample.ps1'),
            [string]$Bucket = ''
        )
        $versionDir = Join-Path $Root "apps\$AppName\$Version"
        $currentDir = Join-Path $Root "apps\$AppName\current"
        $null = New-Item -ItemType Directory -Path $versionDir -Force
        $null = New-Item -ItemType Directory -Path $currentDir -Force
        $installJson = [ordered]@{ bucket = $Bucket; architecture = '64bit'; hold = $false } | ConvertTo-Json
        $manifestJson = [ordered]@{ version = $Version; url = $LocalUrls; installer = @{ script = '& "$dir\Sample.ps1"' } } | ConvertTo-Json -Depth 5
        foreach ($d in @($versionDir, $currentDir)) {
            $installJson  | Out-File -LiteralPath (Join-Path $d 'install.json') -Encoding UTF8
            $manifestJson | Out-File -LiteralPath (Join-Path $d 'manifest.json') -Encoding UTF8
        }
        return @{ AppRoot = (Join-Path $Root "apps\$AppName"); CurrentDir = $currentDir; VersionDir = $versionDir }
    }
}

Describe 'Update-LocalManifestInstallMetadata' -Tag 'Light' {

    It 'sets install.json.bucket in both current/ and the version dir (#62)' {
        $fake = New-FakeScoopApp -Root $TestDrive -AppName 'SampleApp'

        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Root = $TestDrive } {
            param($Root)
            Update-LocalManifestInstallMetadata -AppName 'SampleApp' -BucketName 'MarkMichaelis' -ScoopRoot $Root
        }

        (Get-Content (Join-Path $fake.CurrentDir 'install.json') -Raw | ConvertFrom-Json).bucket | Should -Be 'MarkMichaelis'
        (Get-Content (Join-Path $fake.VersionDir 'install.json') -Raw | ConvertFrom-Json).bucket | Should -Be 'MarkMichaelis'
    }

    It 'restores canonical raw.githubusercontent.com url[] entries (#62)' {
        $fake = New-FakeScoopApp -Root $TestDrive -AppName 'SampleApp2' `
            -LocalUrls @('file:///D:/Git/ScoopBucket/bucket/Sample.ps1', 'file:///D:/Git/ScoopBucket/bucket/Utils.ps1')

        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Root = $TestDrive } {
            param($Root)
            Update-LocalManifestInstallMetadata -AppName 'SampleApp2' -BucketName 'MarkMichaelis' -ScoopRoot $Root
        }

        $urls = (Get-Content (Join-Path $fake.CurrentDir 'manifest.json') -Raw | ConvertFrom-Json).url
        @($urls) | Should -Be @(
            'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/master/bucket/Sample.ps1',
            'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/master/bucket/Utils.ps1'
        )
    }

    It 'is idempotent — running twice leaves the same result' {
        $fake = New-FakeScoopApp -Root $TestDrive -AppName 'SampleApp3'

        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Root = $TestDrive } {
            param($Root)
            Update-LocalManifestInstallMetadata -AppName 'SampleApp3' -BucketName 'MarkMichaelis' -ScoopRoot $Root
            Update-LocalManifestInstallMetadata -AppName 'SampleApp3' -BucketName 'MarkMichaelis' -ScoopRoot $Root
        }

        (Get-Content (Join-Path $fake.CurrentDir 'install.json') -Raw | ConvertFrom-Json).bucket | Should -Be 'MarkMichaelis'
        $urls = (Get-Content (Join-Path $fake.CurrentDir 'manifest.json') -Raw | ConvertFrom-Json).url
        @($urls)[0] | Should -Match '^https://raw\.githubusercontent\.com/'
    }

    It 'is a no-op when the app directory does not exist' {
        {
            InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Root = $TestDrive } {
                param($Root)
                Update-LocalManifestInstallMetadata -AppName 'DoesNotExist' -BucketName 'MarkMichaelis' -ScoopRoot $Root
            }
        } | Should -Not -Throw
    }

    It 'does not throw on malformed install.json' {
        $appRoot = Join-Path $TestDrive 'apps\BadApp'
        $current = Join-Path $appRoot 'current'
        $null = New-Item -ItemType Directory -Path $current -Force
        '{ this is not json' | Out-File -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

        {
            InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Root = $TestDrive } {
                param($Root)
                Update-LocalManifestInstallMetadata -AppName 'BadApp' -BucketName 'MarkMichaelis' -ScoopRoot $Root -WarningAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}
