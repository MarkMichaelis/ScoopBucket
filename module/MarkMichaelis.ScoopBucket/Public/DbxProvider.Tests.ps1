#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior tests for the DbxProvider package hooks (issue #509).

.DESCRIPTION
    Install-DbxProviderModule puts the latest DbxProvider GitHub release into
    the user's module path; Set-DbxDriveProfile writes the lazy `Dbx:` block
    into the profile. Both run on every install and every update, so the
    behavior that matters is that a rerun changes nothing.

    Every test writes under $TestDrive. The GitHub release lookup and the
    download are mocked, so nothing here touches the network or the real
    profile.
#>

BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $moduleManifest -Force

    function script:New-FakeRelease([string]$Version) {
        [pscustomobject]@{
            tag_name = "v$Version"
            assets   = @([pscustomobject]@{
                name                 = "DbxProvider-$Version.zip"
                browser_download_url = "https://example.invalid/DbxProvider-$Version.zip"
            })
        }
    }
}

Describe 'Install-DbxProviderModule' -Tag 'Light' {

    BeforeEach {
        $script:modulesRoot = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:modulesRoot | Out-Null

        # The "download" writes a real zip holding a module manifest, so the
        # extract step runs for real.
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-WebRequest {
            $src = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $src | Out-Null
            Set-Content -Path (Join-Path $src 'DbxProvider.psd1') -Value "@{ ModuleVersion = '9.9.9' }"
            Compress-Archive -Path (Join-Path $src '*') -DestinationPath $OutFile -Force
        }
    }

    It 'extracts the release zip into <ModulesRoot>\DbxProvider\<version>' {
        Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release (New-FakeRelease '1.2.3')

        Join-Path $script:modulesRoot 'DbxProvider\1.2.3\DbxProvider.psd1' | Should -Exist
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-WebRequest -Times 1 -Exactly
    }

    It 'downloads nothing when that version is already installed' {
        $existing = Join-Path $script:modulesRoot 'DbxProvider\1.2.3'
        New-Item -ItemType Directory -Path $existing -Force | Out-Null
        Set-Content -Path (Join-Path $existing 'DbxProvider.psd1') -Value "@{ ModuleVersion = '1.2.3' }"

        Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release (New-FakeRelease '1.2.3')

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-WebRequest -Times 0 -Exactly
    }

    It 'is twice-runnable: the second run downloads nothing' {
        Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release (New-FakeRelease '1.2.3')
        Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release (New-FakeRelease '1.2.3')

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-WebRequest -Times 1 -Exactly
    }

    It 'installs a newer release beside the older one' {
        Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release (New-FakeRelease '1.2.3')
        Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release (New-FakeRelease '1.3.0')

        Join-Path $script:modulesRoot 'DbxProvider\1.3.0\DbxProvider.psd1' | Should -Exist
        Join-Path $script:modulesRoot 'DbxProvider\1.2.3\DbxProvider.psd1' | Should -Exist
    }

    It 'throws when the release has no module zip' {
        $release = [pscustomobject]@{ tag_name = 'v1.2.3'; assets = @() }

        { Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release $release } |
            Should -Throw '*DbxProvider-1.2.3.zip*'
        Join-Path $script:modulesRoot 'DbxProvider\1.2.3' | Should -Not -Exist
    }

    It 'leaves no partial version folder when the zip holds no manifest' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-WebRequest {
            $src = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $src | Out-Null
            Set-Content -Path (Join-Path $src 'readme.txt') -Value 'not a module'
            Compress-Archive -Path (Join-Path $src '*') -DestinationPath $OutFile -Force
        }

        { Install-DbxProviderModule -ModulesRoot $script:modulesRoot -Release (New-FakeRelease '1.2.3') } |
            Should -Throw '*DbxProvider.psd1*'
        Join-Path $script:modulesRoot 'DbxProvider\1.2.3' | Should -Not -Exist
    }
}

Describe 'Set-DbxDriveProfile' -Tag 'Light' {

    BeforeEach {
        $script:profilePath = Join-Path $TestDrive "$([guid]::NewGuid())\profile.ps1"
        $script:credentialPath = Join-Path $TestDrive "$([guid]::NewGuid())\credentials.json"
    }

    It 'creates the profile (and its folder) when missing' {
        Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>$null

        $script:profilePath | Should -Exist
        $content = Get-Content -Raw $script:profilePath
        $content | Should -Match '(?m)^# ScoopBucket:DbxDrive:BEGIN v1'
        $content | Should -Match '(?m)^# ScoopBucket:DbxDrive:END'
    }

    It 'keeps existing profile content and appends the block once' {
        New-Item -ItemType Directory -Path (Split-Path $script:profilePath) -Force | Out-Null
        Set-Content -Path $script:profilePath -Value '$existing = 1'

        Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>$null

        $content = Get-Content -Raw $script:profilePath
        $content | Should -Match '^\$existing = 1'
        ([regex]::Matches($content, 'ScoopBucket:DbxDrive:BEGIN')).Count | Should -Be 1
    }

    It 'is twice-runnable: a second run leaves the file byte-identical' {
        Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>$null
        $first = Get-Content -Raw $script:profilePath

        Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>$null

        Get-Content -Raw $script:profilePath | Should -BeExactly $first
    }

    It 'replaces an older block in place instead of adding a second one' {
        New-Item -ItemType Directory -Path (Split-Path $script:profilePath) -Force | Out-Null
        Set-Content -Path $script:profilePath -Value @(
            '$before = 1'
            '# ScoopBucket:DbxDrive:BEGIN v0'
            'old body'
            '# ScoopBucket:DbxDrive:END'
            '$after = 2'
        )

        Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>$null

        $content = Get-Content -Raw $script:profilePath
        $content | Should -Not -Match 'old body'
        $content | Should -Match '(?m)^# ScoopBucket:DbxDrive:BEGIN v1'
        ([regex]::Matches($content, 'ScoopBucket:DbxDrive:BEGIN')).Count | Should -Be 1
        $content.IndexOf('$before') | Should -BeLessThan $content.IndexOf('DbxDrive:BEGIN')
        $content.IndexOf('DbxDrive:END') | Should -BeLessThan $content.IndexOf('$after')
    }

    It 'writes a block that connects lazily, not at profile load' {
        Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>$null

        # Dot-sourcing the profile must only define Dbx: -- importing the
        # module or calling Connect-Dropbox here would put a network call on
        # every shell start.
        $result = pwsh -NoProfile -Command "
            . '$($script:profilePath)'
            [pscustomobject]@{
                HasFunction  = [bool](Get-Command 'Dbx:' -CommandType Function -ErrorAction Ignore)
                ModuleLoaded = [bool](Get-Module DbxProvider)
            } | ConvertTo-Json -Compress
        " | ConvertFrom-Json

        $result.HasFunction  | Should -BeTrue
        $result.ModuleLoaded | Should -BeFalse
    }

    It 'reminds the user to sign in once when no saved credential exists' {
        $info = Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>&1

        ($info | Out-String) | Should -Match 'Connect-Dropbox -DriveName Dbx'
    }

    It 'says nothing about signing in when a saved credential exists' {
        New-Item -ItemType Directory -Path (Split-Path $script:credentialPath) -Force | Out-Null
        Set-Content -Path $script:credentialPath -Value '{}'

        $info = Set-DbxDriveProfile -ProfilePath $script:profilePath -CredentialPath $script:credentialPath 6>&1

        ($info | Out-String) | Should -Not -Match 'Connect-Dropbox'
    }
}
