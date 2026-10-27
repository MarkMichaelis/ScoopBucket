#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Guards the single .NET SDK install path (issue #374).

.DESCRIPTION
    The .NET SDK must be installed by exactly one mechanism: the winget
    Microsoft.DotNet.SDK.<major> package declared in DeveloperBasePackages
    (#466). An earlier,
    orphaned foldered manifest (`bucket/developer/dotnet.json`) installed the
    SDK a second way via `choco upgrade dotnet-sdk`, which collides on the
    package name `dotnet` and produces a duplicate machine-wide SDK copy in a
    different location/scope.

    These tests fail (with a behavioral assertion, not a compile error) if any
    manifest reintroduces a Chocolatey `dotnet-sdk` install, or if the
    canonical winget bundle entry is removed.
#>

BeforeDiscovery {
    $script:BucketRoot = $PSScriptRoot

    $script:ManifestCases = @()
    Get-ChildItem -Path $script:BucketRoot -Filter '*.json' -File -Recurse | ForEach-Object {
        $manifestPath = $_.FullName
        $manifestName = $_.BaseName
        try {
            $json = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        }
        catch {
            return
        }

        $scriptLines = @()
        foreach ($section in @($json.installer, $json.uninstaller, $json.pre_install, $json.post_install, $json.pre_uninstall, $json.post_uninstall)) {
            if ($null -eq $section) { continue }
            if ($section -is [string]) { $scriptLines += $section; continue }
            if ($null -ne $section.script) { $scriptLines += @($section.script) }
        }
        $scriptText = ($scriptLines | Where-Object { $_ -is [string] }) -join "`n"

        $script:ManifestCases += [pscustomobject]@{
            Manifest   = $manifestName
            ScriptText = $scriptText
        }
    }
}

Describe 'Single .NET SDK install path (issue #374)' -Tag 'Light' {

    It 'manifest <_.Manifest> does not install dotnet-sdk via Chocolatey' -ForEach $script:ManifestCases {
        # A Chocolatey dotnet-sdk install duplicates the canonical winget
        # package and makes a second, independently updated SDK install.
        # One command line: `choco install|upgrade ... dotnet<anything>`, so a
        # chocolatey path on one line and an unrelated dotnet-sdk on another
        # do not trip it, and dotnet, dotnet-sdk, dotnet-9.0-sdk are all caught.
        $_.ScriptText | Should -Not -Match 'choco(\.exe)?\s+(install|upgrade)\b[^\r\n]*\bdotnet' -Because 'the .NET SDK must come only from the DeveloperBasePackages winget entry, not a choco dotnet-sdk manifest'
    }

    It 'no bundle [Package] installs the .NET SDK through Chocolatey' {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
        $chocoDotnet = @(Get-Package -BucketPath $PSScriptRoot) |
            Where-Object { $_.Installer -eq 'choco' -and $_.Id -match '^dotnet' } |
            ForEach-Object { "$($_.Bundle)/$($_.Name): choco $($_.Id)" }
        $chocoDotnet | Should -BeNullOrEmpty -Because 'the .NET SDK must come only from the DeveloperBasePackages winget entry'
    }

    Context 'canonical winget bundle entry' {
        BeforeAll {
            $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
            if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
            $script:dotnet = @(Get-Package -BucketPath $PSScriptRoot) |
                Where-Object { $_.Bundle -eq 'DeveloperBasePackages' -and $_.Name -eq 'dotnet' } |
                Select-Object -First 1
        }

        It 'DeveloperBasePackages installs dotnet via winget Microsoft.DotNet.SDK.<major>' {
            $script:dotnet | Should -Not -BeNullOrEmpty
            $script:dotnet.Installer | Should -Be 'winget'
            $script:dotnet.Id | Should -Match '^Microsoft\.DotNet\.SDK\.\d+$'
        }
    }
}
