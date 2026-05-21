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

Describe 'Set-RootDirAclFromHome' -Tag 'Light' {
    It 'does not call Set-Acl when -WhatIf is supplied' {
        Mock -CommandName Set-Acl -MockWith {}
        Mock -CommandName Get-Acl -MockWith {
            [pscustomobject]@{ Sddl = 'O:S-1-5-21-fake' }
        }

        Set-RootDirAclFromHome -Path 'TestDrive:\nope' -ReferencePath 'TestDrive:\home' -WhatIf

        Should -Invoke -CommandName Set-Acl -Times 0 -Exactly
    }

    It 'calls Set-Acl with the reference ACL when not in WhatIf' {
        $synthetic = [pscustomobject]@{ Sddl = 'O:S-1-5-21-synthetic' }
        Mock -CommandName Set-Acl -MockWith {}

        Set-RootDirAclFromHome -Path 'TestDrive:\target' -ReferenceAcl $synthetic

        Should -Invoke -CommandName Set-Acl -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'TestDrive:\target' -and $AclObject -eq $synthetic
        }
    }

    It 'reads the reference ACL via Get-Acl on $ReferencePath when -ReferenceAcl is not supplied' {
        $synthetic = [pscustomobject]@{ Sddl = 'O:S-1-5-21-fromhome' }
        Mock -CommandName Get-Acl -MockWith { $synthetic } -ParameterFilter {
            $LiteralPath -eq 'TestDrive:\home'
        }
        Mock -CommandName Set-Acl -MockWith {}

        Set-RootDirAclFromHome -Path 'TestDrive:\target' -ReferencePath 'TestDrive:\home'

        Should -Invoke -CommandName Get-Acl -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'TestDrive:\home'
        }
        Should -Invoke -CommandName Set-Acl -Times 1 -Exactly -ParameterFilter {
            $AclObject -eq $synthetic
        }
    }

    It 'still calls Set-Acl on the target even when the target path does not exist (mock-only)' {
        # The helper is a pure transform: it doesn't probe the target.
        # The orchestrator is responsible for sequencing Create-then-ACL.
        $synthetic = [pscustomobject]@{ Sddl = 'O:S-1-5-21-x' }
        Mock -CommandName Set-Acl -MockWith {}

        Set-RootDirAclFromHome -Path 'TestDrive:\does-not-exist' -ReferenceAcl $synthetic

        Should -Invoke -CommandName Set-Acl -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'TestDrive:\does-not-exist'
        }
    }
}

Describe 'Resolve-FreshSyncAccounts' -Tag 'Light' {
    BeforeAll {
        $script:b1 = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'
            DisplayName = 'Michaelis Consulting'; UserFolder = 'C:\OneDrive\OneDrive - Michaelis Consulting'
        }
        $script:b2 = [pscustomobject]@{
            Slot = 'Business2'; AccountType = 'Business'
            DisplayName = 'IntelliTect'; UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'
        }
        $script:personal = [pscustomobject]@{
            Slot = 'Personal'; AccountType = 'Personal'
            DisplayName = $null; UserFolder = 'C:\OneDrive\OneDrive - Personal'
        }
        $script:allAccounts = @($script:b1, $script:b2, $script:personal)
    }

    It 'returns an empty array when -FreshSync is empty' {
        $result = Resolve-FreshSyncAccounts -Accounts $script:allAccounts -FreshSync @()
        $result | Should -BeNullOrEmpty
    }

    It 'returns an empty array when -FreshSync is $null' {
        $result = Resolve-FreshSyncAccounts -Accounts $script:allAccounts -FreshSync $null
        $result | Should -BeNullOrEmpty
    }

    It 'resolves a Slot name (e.g. Business2) to the matching account' {
        $result = Resolve-FreshSyncAccounts -Accounts $script:allAccounts -FreshSync @('Business2')
        @($result) | Should -HaveCount 1
        $result[0].Slot | Should -Be 'Business2'
        $result[0].DisplayName | Should -Be 'IntelliTect'
    }

    It 'resolves a DisplayName case-insensitively' {
        $result = Resolve-FreshSyncAccounts -Accounts $script:allAccounts -FreshSync @('intellitect')
        @($result) | Should -HaveCount 1
        $result[0].Slot | Should -Be 'Business2'
    }

    It 'resolves multiple entries (Slot + DisplayName mix) without duplicates' {
        $result = Resolve-FreshSyncAccounts -Accounts $script:allAccounts `
            -FreshSync @('Business2','IntelliTect','Business1')
        @($result) | Should -HaveCount 2
        ($result | ForEach-Object Slot) | Should -Contain 'Business1'
        ($result | ForEach-Object Slot) | Should -Contain 'Business2'
    }

    It 'throws when an entry matches no discovered account' {
        { Resolve-FreshSyncAccounts -Accounts $script:allAccounts -FreshSync @('Bogus') } |
            Should -Throw -ExpectedMessage "*'Bogus'*"
    }

    It 'throws when an entry matches the Personal account slot' {
        { Resolve-FreshSyncAccounts -Accounts $script:allAccounts -FreshSync @('Personal') } |
            Should -Throw -ExpectedMessage '*only Business accounts*'
    }

    It 'partitions the discovered accounts so FreshSync matches are excluded from a file-copy list' {
        # Mirrors the partitioning the orchestrator performs.
        $fs = Resolve-FreshSyncAccounts -Accounts $script:allAccounts -FreshSync @('Business2')
        $fsSlots = @($fs | ForEach-Object Slot)
        $fileCopy = $script:allAccounts | Where-Object { $fsSlots -notcontains $_.Slot }
        @($fileCopy | ForEach-Object Slot) | Should -Be @('Business1','Personal')
    }
}


Describe 'Elevation pre-flight' -Tag 'Light' {
    BeforeAll {
        $script:bundlePath = "$PSScriptRoot\MarkMichaelisOneDriveConfiguration.ps1"
    }

    AfterEach {
        # Clear the test escape hatch so one test cannot leak state into
        # another (or into a subsequent dot-source).
        if (Test-Path 'Variable:Global:__MMOD_ForceIsElevated') {
            Remove-Variable -Name '__MMOD_ForceIsElevated' -Scope Global -Force
        }
    }

    It 'Test-IsElevated returns a [bool]' {
        $result = Test-IsElevated
        $result | Should -BeOfType [bool]
    }

    It 'throws with an "elevated PowerShell" message when not elevated and -SkipElevationCheck is absent' {
        $global:__MMOD_ForceIsElevated = $false
        {
            & $script:bundlePath -RootDir 'TestDrive:\OD' -WhatIf
        } | Should -Throw -ExpectedMessage '*elevated PowerShell*'
    }

    It 'does not throw the elevation message when -SkipElevationCheck is passed (even when not elevated)' {
        $global:__MMOD_ForceIsElevated = $false
        # The orchestrator may fail later for unrelated reasons (TestDrive,
        # missing registry, etc.); we only assert that the *elevation*
        # pre-flight does not fire.
        $threw = $null
        try {
            & $script:bundlePath -RootDir 'TestDrive:\OD' -SkipElevationCheck -WhatIf
        } catch {
            $threw = $_
        }
        if ($threw) {
            $threw.Exception.Message | Should -Not -Match 'elevated PowerShell'
        }
    }
}
