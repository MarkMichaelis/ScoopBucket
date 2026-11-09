#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pins the ChatGPT declarations to the current ChatGPT app (#511).

.DESCRIPTION
    OpenAI renamed the Store listing the bucket used to install, 9NT1R1C2HH7J,
    to "ChatGPT Classic" and retires it on 2027-01-30. The replacement is Store
    product 9PLM9XGG6VKS, whose package family is OpenAI.Codex_2p2nqsd0c76g0
    (the same identity the winget community package OpenAI.ChatGPT installs).

    The two apps are separate Appx packages, so a machine that still has Classic
    must not pass verification for the new app: Classic's presence would
    otherwise report the migration as done while the new app is missing.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    $script:bucketRoot = Split-Path -Parent $PSScriptRoot
    $script:pkgs       = @(Get-Package -BucketPath $script:bucketRoot)

    $script:ClassicStoreId = '9NT1R1C2HH7J'
    $script:CurrentStoreId = '9PLM9XGG6VKS'
}

Describe 'ChatGPT: installs the current app, not ChatGPT Classic (#511)' -Tag 'Light', 'Bundle' {

    It 'no bundle declares the retired ChatGPT Classic Store listing' {
        # winget still resolves 9NT1R1C2HH7J, so a regression here would
        # install cleanly and pass CI while placing an app that stops working
        # on 2027-01-30 on every provisioned machine.
        $classic = @($script:pkgs | Where-Object Id -EQ $script:ClassicStoreId)
        $classic | Should -BeNullOrEmpty -Because "still declared by: $(($classic | ForEach-Object { "$($_.Bundle)/$($_.Name)" }) -join ', ')"
    }

    It 'declares the current ChatGPT Store app in <Bundle>' -ForEach @(
        @{ Bundle = 'ChatGPT';            Name = 'ChatGPT' }
        @{ Bundle = 'ClientBasePackages'; Name = 'ChatGPT (Store)' }
    ) {
        $pkg = @($script:pkgs | Where-Object { $_.Bundle -eq $Bundle -and $_.Name -eq $Name })
        $pkg.Count        | Should -Be 1
        $pkg[0].Installer | Should -Be 'winget'
        $pkg[0].Id        | Should -Be $script:CurrentStoreId
        $pkg[0].Source    | Should -Be 'msstore'
    }
}

Describe 'ChatGPT: verification recognises the current app only (#511)' -Tag 'Light', 'Bundle' -Skip:(-not $IsWindows) {

    BeforeAll {
        $script:chatgpt = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($bundle) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq 'ChatGPT'
        } (Join-Path $PSScriptRoot 'ChatGPT.ps1')

        $script:hint = (& (Join-Path $script:bucketRoot 'ManifestTestHints.ps1'))['ChatGPT']
    }

    # The package VerifyScript is bound to the module's session state (the
    # bundle is loaded by Get-BundlePackageObjects), while the hint Script is
    # created in this file's scope -- so each context mocks both.
    Context 'only ChatGPT Classic is installed' {
        BeforeAll {
            Mock Get-AppxPackage -ModuleName MarkMichaelis.ScoopBucket { $null }
            Mock Get-AppxPackage -ModuleName MarkMichaelis.ScoopBucket -ParameterFilter { $Name -eq 'OpenAI.ChatGPT-Desktop' } {
                [pscustomobject]@{ Name = 'OpenAI.ChatGPT-Desktop' }
            }
            Mock Get-AppxPackage { $null }
            Mock Get-AppxPackage -ParameterFilter { $Name -eq 'OpenAI.ChatGPT-Desktop' } {
                [pscustomobject]@{ Name = 'OpenAI.ChatGPT-Desktop' }
            }
        }

        It 'the package VerifyScript reports the new app missing' {
            [bool](& $script:chatgpt.VerifyScript $script:chatgpt) | Should -BeFalse
        }

        It 'the Heavy-test hint reports the new app missing' {
            [bool](& $script:hint.Script) | Should -BeFalse
        }
    }

    Context 'the current ChatGPT app is installed' {
        BeforeAll {
            Mock Get-AppxPackage -ModuleName MarkMichaelis.ScoopBucket { $null }
            Mock Get-AppxPackage -ModuleName MarkMichaelis.ScoopBucket -ParameterFilter { $Name -eq 'OpenAI.Codex' } {
                [pscustomobject]@{ Name = 'OpenAI.Codex' }
            }
            Mock Get-AppxPackage { $null }
            Mock Get-AppxPackage -ParameterFilter { $Name -eq 'OpenAI.Codex' } {
                [pscustomobject]@{ Name = 'OpenAI.Codex' }
            }
        }

        It 'the package VerifyScript reports it present' {
            [bool](& $script:chatgpt.VerifyScript $script:chatgpt) | Should -BeTrue
        }

        It 'the Heavy-test hint reports it present' {
            [bool](& $script:hint.Script) | Should -BeTrue
        }
    }
}
