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
        foreach ($section in @($json.installer, $json.uninstaller, $json.pre_install, $json.post_install)) {
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
        $_.ScriptText | Should -Not -Match 'choco[\s\S]*dotnet-sdk' -Because 'the .NET SDK must come only from the DeveloperBasePackages winget entry, not a choco dotnet-sdk manifest'
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
