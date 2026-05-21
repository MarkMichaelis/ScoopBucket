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

    It 'returns Action=''None'' when KFM is inactive even if the owner is not signed in' {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:other, $script:personal) `
            -KfmCurrentPath $null `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'None'
        $result.OwnerAccount | Should -BeNullOrEmpty
    }

    It 'returns an empty-accounts result as None when KFM is inactive' {
        $result = Resolve-KfmRebindAction `
            -Accounts @() `
            -KfmCurrentPath $null `
            -KfmOwner 'Michaelis'
        $result.Action | Should -Be 'None'
    }
}

Describe 'Resolve-KfmCurrentOwnerRoot' -Tag 'Light' {
    BeforeAll {
        $script:kfmOwner1 = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'Michaelis Consulting'
            UserFolder = 'C:\OneDrive\OneDrive - Michaelis Consulting'
        }
        $script:kfmOwner2 = [pscustomobject]@{
            Slot = 'Business2'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'
        }
    }

    It 'returns the owning account for <Path>' -ForEach @(
        @{ Path = 'C:\OneDrive\OneDrive - IntelliTect\Documents'; ExpectedSlot = 'Business2' }
        @{ Path = 'C:\OneDrive\OneDrive - IntelliTect\Desktop'; ExpectedSlot = 'Business2' }
        @{ Path = 'C:\OneDrive\OneDrive - IntelliTect\Pictures'; ExpectedSlot = 'Business2' }
        @{ Path = 'C:\OneDrive\OneDrive - IntelliTect\Music'; ExpectedSlot = 'Business2' }
        @{ Path = 'C:\OneDrive\OneDrive - IntelliTect\Videos'; ExpectedSlot = 'Business2' }
    ) {
        $result = Resolve-KfmCurrentOwnerRoot -Accounts @($script:kfmOwner1, $script:kfmOwner2) -KfmCurrentPath $Path
        $result.Slot | Should -Be $ExpectedSlot
    }

    It 'returns $null for an orphaned KFM path outside discovered roots' {
        Resolve-KfmCurrentOwnerRoot -Accounts @($script:kfmOwner1, $script:kfmOwner2) -KfmCurrentPath 'D:\Elsewhere\Documents' |
            Should -BeNullOrEmpty
    }
}

Describe 'Get-OneDriveSharePointSiteList' -Tag 'Light' {
    It 'discovers nested and sibling SharePoint mount points and computes canonical tenant-sibling targets' {
        $account = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'; TenantId = 'tenant-1'
            UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }

        Mock -CommandName Get-OneDriveRegistryStringValuesUnderPath -MockWith {
            param($Path)
            switch ($Path) {
                'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1\Tenants\tenant-1' {
                    @(
                        [pscustomobject]@{ KeyPath = $Path; ValueName = 'Nested'; Value = 'C:\OneDrive\OneDrive - IntelliTect\Projects' },
                        [pscustomobject]@{ KeyPath = $Path; ValueName = 'Sibling'; Value = 'C:\Users\Mark\IntelliTect - Engineering' }
                    )
                    break
                }
                'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache' {
                    @([pscustomobject]@{ KeyPath = $Path; ValueName = 'Cache'; Value = 'C:\Users\Mark\IntelliTect - Engineering' })
                    break
                }
                default { @() }
            }
        }

        $sites = Get-OneDriveSharePointSiteList -Accounts @($account) -RootDir 'C:\OneDrive'

        @($sites).Count | Should -Be 2
        ($sites | ForEach-Object CurrentPath) | Should -Contain 'C:\OneDrive\OneDrive - IntelliTect\Projects'
        ($sites | ForEach-Object CurrentPath) | Should -Contain 'C:\Users\Mark\IntelliTect - Engineering'
        ($sites | Where-Object CurrentPath -eq 'C:\OneDrive\OneDrive - IntelliTect\Projects').DesiredPath | Should -Be 'C:\OneDrive\IntelliTect\Projects'
        ($sites | Where-Object CurrentPath -eq 'C:\Users\Mark\IntelliTect - Engineering').DesiredPath | Should -Be 'C:\OneDrive\IntelliTect\IntelliTect - Engineering'
    }
}

Describe 'Update-OneDriveSharePointCache' -Tag 'Light' {
    It 'prefix-rewrites nested and sibling SharePoint cache paths for <OldPath>' -ForEach @(
        @{ OldPath = 'C:\OneDrive\OneDrive - IntelliTect\Projects'; NewPath = 'C:\OneDrive\IntelliTect\Projects'; Current = 'C:\OneDrive\OneDrive - IntelliTect\Projects\Docs'; Expected = 'C:\OneDrive\IntelliTect\Projects\Docs' }
        @{ OldPath = 'C:\Users\Mark\IntelliTect - Engineering'; NewPath = 'C:\OneDrive\IntelliTect\IntelliTect - Engineering'; Current = 'C:\Users\Mark\IntelliTect - Engineering\Sub'; Expected = 'C:\OneDrive\IntelliTect\IntelliTect - Engineering\Sub' }
    ) {
        $account = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'; TenantId = 'tenant-1'
            UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }

        Mock -CommandName Get-OneDriveRegistryStringValuesUnderPath -MockWith {
            @([pscustomobject]@{ KeyPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'; ValueName = 'Site'; Value = $Current })
        }
        Mock -CommandName Set-ItemProperty

        Update-OneDriveSharePointCache -Account $account -OldPath $OldPath -NewPath $NewPath -Confirm:$false

        Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter {
            $Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache' -and
            $Name -eq 'Site' -and
            $Value -eq $Expected
        }
    }
}

Describe 'Get-OneDrivePlaceholderCount' -Tag 'Light' {
    It 'counts Files-On-Demand placeholders via recall/offline file attributes' {
        Mock -CommandName Test-Path -MockWith { $true }
        Mock -CommandName Get-ChildItem -MockWith {
            @(
                [pscustomobject]@{ FullName = 'C:\Source\a.txt' },
                [pscustomobject]@{ FullName = 'C:\Source\b.txt' },
                [pscustomobject]@{ FullName = 'C:\Source\c.txt' }
            )
        }
        Mock -CommandName Get-OneDriveFileAttributes -MockWith {
            param($Path)
            switch ($Path) {
                'C:\Source\a.txt' { return 0x00400000 }
                'C:\Source\b.txt' { return 0x00001000 }
                default { return 0 }
            }
        }

        Get-OneDrivePlaceholderCount -Path 'C:\Source' | Should -Be 2
    }
}

Describe 'Export-OneDriveRegistryBackup' -Tag 'Light' {
    It 'exports each required registry subtree into the combined backup file' {
        Mock -CommandName Test-Path -MockWith { $false }
        Mock -CommandName New-Item
        Mock -CommandName Set-Content
        Mock -CommandName Add-Content
        Mock -CommandName Remove-Item
        Mock -CommandName Get-Content -MockWith { "Windows Registry Editor Version 5.00`r`n[HKEY_CURRENT_USER\\Software]" }
        Mock -CommandName Invoke-RegExportCommand

        Export-OneDriveRegistryBackup -OutputPath 'C:\Users\Mark\AppData\Local\MarkMichaelis\OneDriveMigration\backup-20240102-030405.reg' | Out-Null

        foreach ($subKey in @(
            'HKCU\Software\Microsoft\OneDrive\Accounts',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions',
            'HKCU\SOFTWARE\Policies\Microsoft\OneDrive',
            'HKLM\SOFTWARE\Policies\Microsoft\OneDrive'
        )) {
            Should -Invoke Invoke-RegExportCommand -Times 1 -ParameterFilter { $SubKey -eq $subKey }
        }
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

Describe 'Set-OneDrivePolicy' -Tag 'Light' {
    It 'writes DefaultRootDir in HKCU per tenant and GPOSetUpdateRing=0 in HKLM' {
        $accounts = @(
            [pscustomobject]@{
                Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
                TenantId = '11111111-1111-1111-1111-111111111111'; UserFolder = 'C:\Users\me\OneDrive - IntelliTect'
            },
            [pscustomobject]@{
                Slot = 'Personal'; AccountType = 'Personal'; DisplayName = $null
                TenantId = $null; UserFolder = 'C:\Users\me\OneDrive'
            }
        )

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            $Path -in @(
                'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive',
                'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir',
                'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
            )
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param($Path, $Name)
            if ($Path -eq 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' -and $Name -eq '11111111-1111-1111-1111-111111111111') {
                return [pscustomobject]@{ '11111111-1111-1111-1111-111111111111' = 'C:\SomewhereElse' }
            }
            if ($Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -and $Name -eq 'GPOSetUpdateRing') {
                return [pscustomobject]@{ GPOSetUpdateRing = 4 }
            }
            return [pscustomobject]@{}
        }
        Mock -CommandName Set-ItemProperty
        Mock -CommandName New-Item

        Set-OneDrivePolicy -Accounts $accounts -RootDir 'C:\OneDrive' -Confirm:$false

        Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter {
            $Path -eq 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' -and
            $Name -eq '11111111-1111-1111-1111-111111111111' -and
            $Value -eq 'C:\OneDrive\OneDrive - IntelliTect' -and
            $Type -eq 'String'
        }
        Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter {
            $Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -and
            $Name -eq 'GPOSetUpdateRing' -and
            $Value -eq 0 -and
            $Type -eq 'DWord'
        }
    }
}

Describe 'Move-OneDriveFolder' -Tag 'Light' {
    It 'moves successfully when only the destination parent exists' {
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                'C:\OneDrive\OneDrive - IntelliTect' { $false; break }
                'C:\OneDrive' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Move-Item
        Mock -CommandName New-Item

        { Move-OneDriveFolder -Source 'C:\Users\me\OneDrive - IntelliTect' -Destination 'C:\OneDrive\OneDrive - IntelliTect' -Confirm:$false } |
            Should -Not -Throw

        Should -Invoke Move-Item -Times 1 -ParameterFilter {
            $LiteralPath -eq 'C:\Users\me\OneDrive - IntelliTect' -and
            $Destination -eq 'C:\OneDrive\OneDrive - IntelliTect'
        }
        Should -Invoke New-Item -Times 0
    }

    It 'renames the source to a .migrated-* folder after successful cross-volume copy by default' {
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                'D:\OneDrive\OneDrive - IntelliTect' { $false; break }
                'D:\OneDrive' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Test-IsSameVolume -MockWith { $false }
        Mock -CommandName Invoke-RobocopyMirror -MockWith { 1 }
        Mock -CommandName Get-Date -MockWith { '20240102-030405' }
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Move-Item
        Mock -CommandName Remove-Item

        $result = Move-OneDriveFolder -Source 'C:\Users\me\OneDrive - IntelliTect' -Destination 'D:\OneDrive\OneDrive - IntelliTect' -Confirm:$false

        $result.DeferredDeletePath | Should -Be 'C:\Users\me\OneDrive - IntelliTect.migrated-20240102-030405'
        Should -Invoke Move-Item -Times 1 -ParameterFilter {
            $LiteralPath -eq 'C:\Users\me\OneDrive - IntelliTect' -and
            $Destination -eq 'C:\Users\me\OneDrive - IntelliTect.migrated-20240102-030405'
        }
        Should -Invoke Remove-Item -Times 0
    }

    It 'only deletes the renamed source when -DeleteSourceOnSuccess is supplied and verification passed' {
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                'D:\OneDrive\OneDrive - IntelliTect' { $false; break }
                'D:\OneDrive' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Test-IsSameVolume -MockWith { $false }
        Mock -CommandName Invoke-RobocopyMirror -MockWith { 1 }
        Mock -CommandName Get-Date -MockWith { '20240102-030405' }
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Move-Item
        Mock -CommandName Remove-Item

        $result = Move-OneDriveFolder -Source 'C:\Users\me\OneDrive - IntelliTect' -Destination 'D:\OneDrive\OneDrive - IntelliTect' -DeleteSourceOnSuccess -Confirm:$false

        $result.DeferredDeletePath | Should -BeNullOrEmpty
        Should -Invoke Remove-Item -Times 1 -ParameterFilter {
            $LiteralPath -eq 'C:\Users\me\OneDrive - IntelliTect.migrated-20240102-030405'
        }
    }

    It 'refuses delete cleanup when cross-volume verification fails' {
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                'D:\OneDrive\OneDrive - IntelliTect' { $false; break }
                'D:\OneDrive' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Test-IsSameVolume -MockWith { $false }
        Mock -CommandName Invoke-RobocopyMirror -MockWith { 1 }
        Mock -CommandName Get-Date -MockWith { '20240102-030405' }
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $false }
        Mock -CommandName Move-Item
        Mock -CommandName Remove-Item

        { Move-OneDriveFolder -Source 'C:\Users\me\OneDrive - IntelliTect' -Destination 'D:\OneDrive\OneDrive - IntelliTect' -DeleteSourceOnSuccess -Confirm:$false } |
            Should -Throw -ExpectedMessage '*Original data was preserved*'

        Should -Invoke Move-Item -Times 1
        Should -Invoke Remove-Item -Times 0
    }
}

Describe 'Invoke-MarkMichaelisOneDriveConfiguration pre-create behavior' -Tag 'Heavy' {
    It 'creates RootDir and bare tenant directories but not the per-account destination' {
        $rootDir = 'C:\OneDrive'
        $tenantDir = 'C:\OneDrive\IntelliTect'
        $targetDir = 'C:\OneDrive\OneDrive - IntelliTect'
        $sourceDir = 'C:\Users\me\OneDrive - IntelliTect'
        $createdPaths = New-Object System.Collections.Generic.List[string]
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = $sourceDir; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                $rootDir { $false; break }
                $tenantDir { $false; break }
                $sourceDir { $true; break }
                default { $false }
            }
        }
        Mock -CommandName New-Item -MockWith {
            param($ItemType, $Path)
            $createdPaths.Add($Path) | Out-Null
        }
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($acct) }
        Mock -CommandName Resolve-FreshSyncAccounts -MockWith { @() }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $acct; Reason = 'KFM inactive' }
        }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir $rootDir -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false

        $createdPaths | Should -Contain $rootDir
        $createdPaths | Should -Contain $tenantDir
        $createdPaths | Should -Not -Contain $targetDir
        Should -Invoke Move-OneDriveFolder -Times 1 -ParameterFilter {
            $Source -eq $sourceDir -and $Destination -eq $targetDir
        }
    }
}

Describe 'Invoke-MarkMichaelisOneDriveConfiguration running state' -Tag 'Heavy' {
    BeforeEach {
        $script:acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = 'C:\Users\me\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\OneDrive' { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($script:acct) }
        Mock -CommandName Resolve-FreshSyncAccounts -MockWith { @() }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }
        }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName New-Item
    }

    It 'does not restart OneDrive when it was not running before the script started' {
        Mock -CommandName Get-Process -MockWith { $null }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false

        Should -Invoke Start-OneDriveExe -Times 0
    }

    It 'restarts OneDrive when it was running before the script started' {
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false

        Should -Invoke Start-OneDriveExe -Times 1
    }
}

Describe 'Invoke-MarkMichaelisOneDriveConfiguration rollback' -Tag 'Heavy' {
    It 'moves the source back when a same-volume registry update fails' {
        $rootDir = 'C:\OneDrive'
        $oldPath = 'C:\Users\me\OneDrive - IntelliTect'
        $newPath = 'C:\OneDrive\OneDrive - IntelliTect'
        $script:afterMove = $false
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = $oldPath; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                $rootDir { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                $oldPath { if ($script:afterMove) { $false } else { $true }; break }
                $newPath { if ($script:afterMove) { $true } else { $false }; break }
                default { $false }
            }
        }
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($acct) }
        Mock -CommandName Resolve-FreshSyncAccounts -MockWith { @() }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }
        }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Move-OneDriveFolder -MockWith { $script:afterMove = $true }
        Mock -CommandName Get-OneDriveAccountRegistrySnapshot -MockWith { [pscustomobject]@{ UserFolder = $oldPath; CacheValues = @{} } }
        Mock -CommandName Update-OneDriveAccountRegistry -MockWith { throw 'registry write failed' }
        Mock -CommandName Restore-OneDriveAccountRegistrySnapshot
        Mock -CommandName Move-Item -MockWith { $script:afterMove = $false }
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }
        Mock -CommandName Write-Error

        { Invoke-MarkMichaelisOneDriveConfiguration -RootDir $rootDir -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false } |
            Should -Throw -ExpectedMessage '*registry write failed*'

        Should -Invoke Move-Item -Times 1 -ParameterFilter {
            $LiteralPath -eq $newPath -and $Destination -eq $oldPath
        }
        Should -Invoke Restore-OneDriveAccountRegistrySnapshot -Times 1
        Should -Invoke Start-OneDriveExe -Times 0
    }
}

Describe 'Invoke-MarkMichaelisOneDriveConfiguration KFM rebind' -Tag 'Heavy' {
    It 'preserves the known-folder suffix by rebinding from the owning account root for <Suffix>' -ForEach @(
        @{ Suffix = 'Documents' }
        @{ Suffix = 'Desktop' }
        @{ Suffix = 'Pictures' }
        @{ Suffix = 'Music' }
        @{ Suffix = 'Videos' }
    ) {
        $rootDir = 'C:\OneDrive'
        $owner = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'Michaelis Consulting'
            UserEmail = 'owner@example.com'; UserFolder = 'C:\OneDrive\OneDrive - Michaelis Consulting'; TenantId = 'tid-owner'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $other = [pscustomobject]@{
            Slot = 'Business2'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'other@example.com'; UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'; TenantId = 'tid-other'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business2'
        }
        $kfmCurrent = "C:\OneDrive\OneDrive - IntelliTect\$Suffix"

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\OneDrive' { $true; break }
                'C:\OneDrive\Michaelis Consulting' { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($owner, $other) }
        Mock -CommandName Resolve-FreshSyncAccounts -MockWith { @() }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $kfmCurrent }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Update-KfmBindings

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir $rootDir -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false

        Should -Invoke Update-KfmBindings -Times 1 -ParameterFilter {
            $OldRoot -eq 'C:\OneDrive\OneDrive - IntelliTect' -and
            $NewRoot -eq 'C:\OneDrive\OneDrive - Michaelis Consulting'
        }
    }

    It 'warns and skips rebind when the current KFM path is orphaned' {
        $owner = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'Michaelis Consulting'
            UserEmail = 'owner@example.com'; UserFolder = 'C:\OneDrive\OneDrive - Michaelis Consulting'; TenantId = 'tid-owner'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            $Path -eq 'C:\OneDrive'
        }
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($owner) }
        Mock -CommandName Resolve-FreshSyncAccounts -MockWith { @() }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { 'D:\Elsewhere\Documents' }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Update-KfmBindings
        Mock -CommandName Write-Warning

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false

        Should -Invoke Update-KfmBindings -Times 0
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*not under any discovered OneDrive account UserFolder*' }
    }
}

Describe 'Plan-then-execute architecture' -Tag 'Heavy' {
    It '-WhatIf renders the plan without invoking state-changing helpers' {
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = 'C:\Users\me\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\OneDrive' { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($acct) }
        Mock -CommandName Resolve-FreshSyncAccounts -MockWith { @() }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }
        }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Set-OneDriveUpdateRingPolicy -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Move-OneDriveFolder -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Update-OneDriveAccountRegistry -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Stop-OneDriveExe -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Start-OneDriveExe -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Update-KfmBindings -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Invoke-AppFixUps -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Remove-OneDriveAccountLink -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }

        { Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -FreshSync @() -WhatIf } |
            Should -Not -Throw

        Should -Invoke Move-OneDriveFolder -Times 0
        Should -Invoke Update-OneDriveAccountRegistry -Times 0
        Should -Invoke Stop-OneDriveExe -Times 0
        Should -Invoke Start-OneDriveExe -Times 0
    }

    It 'performs a same-volume move on the first run and is a no-op on the second run' {
        $script:firstRunComplete = $false
        $decision = [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }

        Mock -CommandName Get-OneDriveAccountList -MockWith {
            if (-not $script:firstRunComplete) {
                return @([pscustomobject]@{
                    Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
                    UserEmail = 'user@example.com'; UserFolder = 'C:\Users\me\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
                })
            }
            return @([pscustomobject]@{
                Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
                UserEmail = 'user@example.com'; UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
            })
        }
        Mock -CommandName Resolve-FreshSyncAccounts -MockWith { @() }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith { $decision }
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\OneDrive' { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                'C:\Users\me\OneDrive - IntelliTect' { -not $script:firstRunComplete; break }
                'C:\OneDrive\OneDrive - IntelliTect' { $script:firstRunComplete; break }
                default { $false }
            }
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param($Path, $Name)
            if ($Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -and $Name -eq 'UserFolder') {
                return [pscustomobject]@{ UserFolder = $(if ($script:firstRunComplete) { 'C:\OneDrive\OneDrive - IntelliTect' } else { 'C:\Users\me\OneDrive - IntelliTect' }) }
            }
            return [pscustomobject]@{}
        }
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\backup.reg' }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Move-OneDriveFolder -MockWith { $script:firstRunComplete = $true }
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { $null }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false | Out-Null
        $secondPlan = Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -FreshSync @() -Confirm:$false

        Should -Invoke Move-OneDriveFolder -Times 1
        @($secondPlan | Where-Object { $_.Type -eq 'MoveAccount' -and -not $_.Skipped }).Count | Should -Be 0
        @($secondPlan | Where-Object { $_.Type -eq 'UpdateAccountRegistry' -and -not $_.Skipped }).Count | Should -Be 0
    }

    It 'emits SharePoint move and cache-rewrite plan items for sibling and nested mounts' {
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $site = [pscustomobject]@{
            OwnerAccount = $acct; CurrentPath = 'C:\Users\Mark\IntelliTect - Engineering'; LeafName = 'IntelliTect - Engineering'; DesiredPath = 'C:\OneDrive\IntelliTect\IntelliTect - Engineering'
        }
        $decision = [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\OneDrive' { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                'C:\OneDrive\OneDrive - IntelliTect' { $true; break }
                'C:\Users\Mark\IntelliTect - Engineering' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param($Path, $Name)
            if ($Path -eq 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' -and $Name -eq 'tid-1') {
                return [pscustomobject]@{ 'tid-1' = 'C:\OneDrive\OneDrive - IntelliTect' }
            }
            if ($Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -and $Name -eq 'GPOSetUpdateRing') {
                return [pscustomobject]@{ GPOSetUpdateRing = 0 }
            }
            if ($Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -and $Name -eq 'UserFolder') {
                return [pscustomobject]@{ UserFolder = 'C:\OneDrive\OneDrive - IntelliTect' }
            }
            return [pscustomobject]@{}
        }

        $plan = New-OneDriveMigrationPlan -RootDir 'C:\OneDrive' -Accounts @($acct) -FreshSyncAccounts @() -SharePointSites @($site) -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        ($plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.Target -eq 'C:\OneDrive\IntelliTect\IntelliTect - Engineering' }).Count | Should -Be 1
        ($plan | Where-Object { $_.Type -eq 'RewriteSPCache' -and $_.CurrentValue -eq 'C:\Users\Mark\IntelliTect - Engineering' -and $_.DesiredValue -eq 'C:\OneDrive\IntelliTect\IntelliTect - Engineering' }).Count | Should -Be 1
    }

    It 'gates cross-volume placeholder moves unless -ForceHydrate is supplied' {
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = 'C:\Users\me\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $decision = [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'D:\OneDrive' { $true; break }
                'D:\OneDrive\IntelliTect' { $true; break }
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Test-IsSameVolume -MockWith { $false }
        Mock -CommandName Get-OneDrivePlaceholderCount -MockWith { 3 }
        Mock -CommandName Get-ItemProperty -MockWith { [pscustomobject]@{} }

        $plan = New-OneDriveMigrationPlan -RootDir 'D:\OneDrive' -Accounts @($acct) -FreshSyncAccounts @() -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        ($plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.SkipReason -like 'Refusing cross-volume move of 3 cloud-only files*' }).Count | Should -Be 1
    }

    It 'allows cross-volume placeholder moves with a hydration warning when -ForceHydrate is supplied' {
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = 'C:\Users\me\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $decision = [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'D:\OneDrive' { $true; break }
                'D:\OneDrive\IntelliTect' { $true; break }
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Test-IsSameVolume -MockWith { $false }
        Mock -CommandName Get-OneDrivePlaceholderCount -MockWith { 3 }
        Mock -CommandName Get-ItemProperty -MockWith { [pscustomobject]@{} }

        $plan = New-OneDriveMigrationPlan -RootDir 'D:\OneDrive' -Accounts @($acct) -FreshSyncAccounts @() -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false -ForceHydrate
        $move = $plan | Where-Object { $_.Type -eq 'MoveAccount' } | Select-Object -First 1

        $move.Skipped | Should -BeFalse
        @($move.Warnings) | Should -Contain 'Will hydrate 3 cloud-only files (~size unknown).'
    }

    It 'marks every plan item skipped on a second idempotent run' {
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $decision = [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\OneDrive' { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                'C:\OneDrive\OneDrive - IntelliTect' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param($Path, $Name)
            if ($Path -eq 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' -and $Name -eq 'tid-1') {
                return [pscustomobject]@{ 'tid-1' = 'C:\OneDrive\OneDrive - IntelliTect' }
            }
            if ($Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -and $Name -eq 'GPOSetUpdateRing') {
                return [pscustomobject]@{ GPOSetUpdateRing = 0 }
            }
            if ($Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -and $Name -eq 'UserFolder') {
                return [pscustomobject]@{ UserFolder = 'C:\OneDrive\OneDrive - IntelliTect' }
            }
            return [pscustomobject]@{}
        }

        $plan = New-OneDriveMigrationPlan -RootDir 'C:\OneDrive' -Accounts @($acct) -FreshSyncAccounts @() -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        @($plan).Count | Should -BeGreaterThan 0
        @($plan | Where-Object { -not $_.Skipped }).Count | Should -Be 0
    }
}

Describe 'Get-OneDriveMigrationSummaryLines' -Tag 'Light' {
    It 'renders the detailed summary sections in a stable grouped structure' {
        $accounts = @(
            [pscustomobject]@{ AccountType = 'Business'; DisplayName = 'IntelliTect'; UserFolder = 'C:\Users\me\OneDrive - IntelliTect' }
        )
        $sharePointSites = @(
            [pscustomobject]@{ CurrentPath = 'C:\Users\Mark\IntelliTect - Engineering'; DesiredPath = 'C:\OneDrive\IntelliTect\IntelliTect - Engineering' }
        )
        $plan = @(
            [pscustomobject]@{ Type='RegistryBackup'; Target='C:\Backup.reg'; CurrentValue=$null; DesiredValue=$null; Status='Done'; SkipReason=$null; FailureReason=$null },
            [pscustomobject]@{ Type='WritePolicy'; Target='HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir\tid-1'; CurrentValue='old'; DesiredValue='new'; Status='Done'; SkipReason=$null; FailureReason=$null },
            [pscustomobject]@{ Type='MoveAccount'; Target='C:\OneDrive\OneDrive - IntelliTect'; CurrentValue='C:\Users\me\OneDrive - IntelliTect'; DesiredValue='C:\OneDrive\OneDrive - IntelliTect'; Status='Skipped'; SkipReason='Current path already matches the canonical target.'; FailureReason=$null },
            [pscustomobject]@{ Type='RewriteSPCache'; Target='C:\OneDrive\IntelliTect\IntelliTect - Engineering'; CurrentValue='C:\Users\Mark\IntelliTect - Engineering'; DesiredValue='C:\OneDrive\IntelliTect\IntelliTect - Engineering'; Status='Done'; SkipReason=$null; FailureReason=$null },
            [pscustomobject]@{ Type='RewriteKfm'; Target='KFM'; CurrentValue='C:\Old\Documents'; DesiredValue='C:\New\Documents'; Status='Failed'; SkipReason=$null; FailureReason='boom' },
            [pscustomobject]@{ Type='Verify'; Target='C:\OneDrive\OneDrive - IntelliTect'; CurrentValue='old'; DesiredValue='new'; Status='Done'; SkipReason=$null; FailureReason=$null }
        )

        $summary = (Get-OneDriveMigrationSummaryLines -Accounts $accounts -SharePointSites $sharePointSites -Plan $plan -DeferredCleanupPaths @('C:\Old.migrated-123')) -join "`n"

        $summary | Should -Match 'Discovered Accounts:'
        $summary | Should -Match 'Discovered SharePoint Sites:'
        $summary | Should -Match 'Policy Writes:'
        $summary | Should -Match 'Moves:'
        $summary | Should -Match 'KFM Rewrites:'
        $summary | Should -Match 'SharePoint Cache Rewrites:'
        $summary | Should -Match 'Verification Results:'
        $summary | Should -Match 'Backup Location:'
        $summary | Should -Match 'MRU Warning:'
        $summary | Should -Match '\.migrated-\* directories awaiting cleanup:'
        $summary | Should -Match 'Failed: boom \| KFM'
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

