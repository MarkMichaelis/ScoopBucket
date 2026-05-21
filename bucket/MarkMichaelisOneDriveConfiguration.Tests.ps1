#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pure-function tests for MarkMichaelisOneDriveConfiguration.ps1.

.DESCRIPTION
    The migration script itself is mostly registry + filesystem
    plumbing (covered by -WhatIf smoke tests during user verification),
    but its decision helpers are pure and easily testable:

      - Get-OneDriveTargetPath: account record + RootDir -> target folder
      - Test-IsSameVolume:      same-volume vs cross-volume detection
      - Resolve-KfmRebindAction: KFM rebind decision (track / rebind /
        warn / owner-not-signed-in)

    Pester 5 quirk (see bucket/Bundles.Tests.ps1 for the long-form
    note): -ForEach test cases must be populated at DISCOVERY time, not
    inside BeforeAll. We dot-source the bundle script at discovery so
    the helper functions are visible to It blocks too -- BeforeAll
    re-dot-sources for clean state.
#>

# Discovery-time: dot-source the bundle so its helpers are in scope
# when -ForEach evaluates. The bundle's main orchestration is gated by
# $MyInvocation.InvocationName -eq '.', so dot-sourcing only loads
# helpers without running the migration.
. "$PSScriptRoot\MarkMichaelisOneDriveConfiguration.ps1"

BeforeAll {
    . "$PSScriptRoot\MarkMichaelisOneDriveConfiguration.ps1"
}

Describe 'Get-OneDriveTargetPath' -Tag 'Light' {
    It 'computes Work tenant path as "<RootDir>\OneDrive - <DisplayName>"' {
        $acct = [pscustomobject]@{
            AccountType = 'Business'
            DisplayName = 'IntelliTect'
            UserFolder  = 'C:\Users\me\OneDrive - IntelliTect'
        }
        Get-OneDriveTargetPath -Account $acct -RootDir 'C:\OneDrive' |
            Should -Be 'C:\OneDrive\OneDrive - IntelliTect'
    }

    It 'computes Personal path as "<RootDir>\OneDrive - Personal"' {
        $acct = [pscustomobject]@{
            AccountType = 'Personal'
            DisplayName = $null
            UserFolder  = 'C:\Users\me\OneDrive'
        }
        Get-OneDriveTargetPath -Account $acct -RootDir 'C:\OneDrive' |
            Should -Be 'C:\OneDrive\OneDrive - Personal'
    }

    It 'honors a non-default RootDir' {
        $acct = [pscustomobject]@{
            AccountType = 'Business'
            DisplayName = 'Michaelis'
            UserFolder  = 'D:\Mark\OneDrive - Michaelis'
        }
        Get-OneDriveTargetPath -Account $acct -RootDir 'E:\Cloud' |
            Should -Be 'E:\Cloud\OneDrive - Michaelis'
    }

    It 'throws when Work account is missing DisplayName' {
        $acct = [pscustomobject]@{
            AccountType = 'Business'
            DisplayName = $null
            UserFolder  = 'C:\foo'
        }
        { Get-OneDriveTargetPath -Account $acct -RootDir 'C:\OneDrive' } |
            Should -Throw -ExpectedMessage '*DisplayName*'
    }
}

Describe 'Test-IsSameVolume' -Tag 'Light' {
    It 'returns $true for two paths on the same drive root' {
        Test-IsSameVolume -Source 'C:\Users\me\OneDrive - X' -Destination 'C:\OneDrive\OneDrive - X' |
            Should -BeTrue
    }

    It 'returns $false for paths on different drive roots' {
        Test-IsSameVolume -Source 'C:\Users\me\OneDrive - X' -Destination 'D:\OneDrive\OneDrive - X' |
            Should -BeFalse
    }

    It 'is case-insensitive on the drive letter' {
        Test-IsSameVolume -Source 'c:\foo' -Destination 'C:\bar' | Should -BeTrue
    }
}

Describe 'Resolve-KfmRebindAction' -Tag 'Light' {
    BeforeAll {
        $script:owner = [pscustomobject]@{
            Slot        = 'Business1'
            AccountType = 'Business'
            DisplayName = 'Michaelis Consulting'
            UserFolder  = 'C:\OneDrive\OneDrive - Michaelis Consulting'
        }
        $script:other = [pscustomobject]@{
            Slot        = 'Business2'
            AccountType = 'Business'
            DisplayName = 'IntelliTect'
            UserFolder  = 'C:\OneDrive\OneDrive - IntelliTect'
        }
        $script:personal = [pscustomobject]@{
            Slot        = 'Personal'
            AccountType = 'Personal'
            DisplayName = $null
            UserFolder  = 'C:\OneDrive\OneDrive - Personal'
        }
    }

    It "returns Action='Track' when KFM is bound under the owner's UserFolder" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner, $script:other) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - Michaelis Consulting\Documents' `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'Track'
        $result.OwnerAccount.Slot | Should -Be 'Business1'
    }

    It "returns Action='Rebind' when KFM is bound under a different account" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner, $script:other) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'Rebind'
        $result.OwnerAccount.Slot | Should -Be 'Business1'
    }

    It "returns Action='WarnOnly' when -NoKfmRebind is supplied with a mismatched binding" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner, $script:other) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'Michaelis' -NoKfmRebind
        $result.Action | Should -Be 'WarnOnly'
    }

    It "returns Action='None' when KFM is not currently active" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner) `
            -KfmCurrentPath $null `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'None'
    }

    It "returns Action='OwnerNotSignedIn' when no Business account has a matching DisplayName" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:other, $script:personal) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'OwnerNotSignedIn'
        $result.OwnerAccount | Should -BeNullOrEmpty
    }

    It "never matches the Personal slot even if its DisplayName contains the owner keyword" {
        $personalNamedMichaelis = [pscustomobject]@{
            Slot        = 'Personal'
            AccountType = 'Personal'
            DisplayName = 'Mark Michaelis'
            UserFolder  = 'C:\foo'
        }
        $result = Resolve-KfmRebindAction `
            -Accounts @($personalNamedMichaelis, $script:other) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'OwnerNotSignedIn'
    }

    It 'returns an empty-accounts result as OwnerNotSignedIn' {
        $result = Resolve-KfmRebindAction `
            -Accounts @() `
            -KfmCurrentPath $null `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'OwnerNotSignedIn'
    }
}

Describe 'Get-OneDriveAccountList (zombie slot filter)' -Tag 'Light' {
    # Regression for issue #192: a Business slot left over from a failed
    # sign-in has no DisplayName / UserFolder / UserEmail and must be
    # skipped, else Get-OneDriveTargetPath throws downstream.

    BeforeAll {
        function New-FakeSlot {
            param([string]$Name, [hashtable]$Props)
            [pscustomobject]@{
                PSChildName = $Name
                PSPath      = "TestRegistry::OneDrive\Accounts\$Name"
                _Props      = [pscustomobject]$Props
            }
        }
    }

    It 'skips a Business slot with empty DisplayName and UserFolder' {
        $real = New-FakeSlot 'Business1' @{
            DisplayName        = 'IntelliTect'
            ConfiguredTenantId = 'tid-1'
            UserEmail          = 'a@example.com'
            UserFolder         = 'C:\Users\me\OneDrive - IntelliTect'
        }
        $zombie = New-FakeSlot 'Business2' @{
            DisplayName        = $null
            ConfiguredTenantId = $null
            UserEmail          = $null
            UserFolder         = $null
        }

        Mock -CommandName Test-Path -ParameterFilter {
            $Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        } -MockWith { $true }

        Mock -CommandName Get-ChildItem -ParameterFilter {
            $Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        } -MockWith { @($real, $zombie) }

        Mock -CommandName Get-ItemProperty -MockWith {
            param($Path)
            ($real, $zombie | Where-Object { $_.PSPath -eq $Path } | Select-Object -First 1)._Props
        }

        $accounts = Get-OneDriveAccountList
        $accounts | Should -HaveCount 1
        $accounts[0].Slot | Should -Be 'Business1'
        $accounts[0].DisplayName | Should -Be 'IntelliTect'
    }

    It 'skips a Business slot with DisplayName but no UserFolder' {
        $halfZombie = New-FakeSlot 'Business1' @{
            DisplayName        = 'Foo'
            ConfiguredTenantId = 'tid-1'
            UserEmail          = 'a@example.com'
            UserFolder         = $null
        }

        Mock -CommandName Test-Path -ParameterFilter {
            $Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        } -MockWith { $true }

        Mock -CommandName Get-ChildItem -ParameterFilter {
            $Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        } -MockWith { @($halfZombie) }

        Mock -CommandName Get-ItemProperty -MockWith { $halfZombie._Props }

        Get-OneDriveAccountList | Should -BeNullOrEmpty
    }
}
