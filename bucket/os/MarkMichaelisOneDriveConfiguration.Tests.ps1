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

    function New-PassingVerificationResult {
        [pscustomobject]@{
            Checks        = @([pscustomobject]@{ Name = 'mock'; Status = 'Pass'; Detail = 'mock verification passed' })
            OverallStatus = 'Pass'
            FailedChecks  = @()
        }
    }
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
            -KfmOwner 'Michaelis Consulting'
        $result.Action | Should -Be 'Track'
        $result.OwnerAccount.Slot | Should -Be 'Business1'
    }

    It "does not track KFM under a sibling account whose root only shares the owner's prefix" {
        $prefixOwner = [pscustomobject]@{
            Slot        = 'Business1'
            AccountType = 'Business'
            DisplayName = 'Foo'
            UserFolder  = 'C:\OneDrive\OneDrive - Foo'
        }
        $prefixSibling = [pscustomobject]@{
            Slot        = 'Business2'
            AccountType = 'Business'
            DisplayName = 'FooBar'
            UserFolder  = 'C:\OneDrive\OneDrive - FooBar'
        }

        $result = Resolve-KfmRebindAction `
            -Accounts @($prefixOwner, $prefixSibling) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - FooBar\Documents' `
            -KfmOwner 'Foo'

        $result.Action | Should -Be 'WarnOnly'
        $result.OwnerAccount.Slot | Should -Be 'Business1'
    }

    It "returns Action='WarnOnly' when KFM is bound under a different account" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner, $script:other) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'Michaelis Consulting'
        $result.Action | Should -Be 'WarnOnly'
        $result.OwnerAccount.Slot | Should -Be 'Business1'
    }

    It "returns Action='None' when KFM is not currently active" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner) `
            -KfmCurrentPath $null `
            -KfmOwner 'Michaelis Consulting'
        $result.Action | Should -Be 'None'
    }

    It "returns Action='OwnerNotSignedIn' when no Business account has a matching DisplayName" {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:other, $script:personal) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'Michaelis Consulting'
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
            -KfmOwner 'Mark Michaelis'
        $result.Action | Should -Be 'OwnerNotSignedIn'
    }

    It 'returns Action=''None'' when KFM is inactive even if the owner is not signed in' {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:other, $script:personal) `
            -KfmCurrentPath $null `
            -KfmOwner 'Michaelis Consulting'
        $result.Action | Should -Be 'None'
        $result.OwnerAccount | Should -BeNullOrEmpty
    }

    It 'matches KfmOwner by case-insensitive substring by default' {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner, $script:other) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'michaelis'
        $result.Action | Should -Be 'WarnOnly'
        $result.OwnerAccount.Slot | Should -Be 'Business1'
    }

    It 'matches KfmOwner case-insensitively when the full display name is supplied' {
        $result = Resolve-KfmRebindAction `
            -Accounts @($script:owner, $script:other) `
            -KfmCurrentPath 'C:\OneDrive\OneDrive - IntelliTect\Documents' `
            -KfmOwner 'michaelis consulting'
        $result.Action | Should -Be 'WarnOnly'
        $result.OwnerAccount.Slot | Should -Be 'Business1'
    }

    It 'returns an empty-accounts result as None when KFM is inactive' {
        $result = Resolve-KfmRebindAction `
            -Accounts @() `
            -KfmCurrentPath $null `
            -KfmOwner 'Michaelis Consulting'
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

    It 'does not rewrite a SharePoint cache path under a sibling mount whose root only shares the old path prefix' {
        $account = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'Foo'; TenantId = 'tenant-1'
            UserFolder = 'C:\OneDrive\OneDrive - Foo'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }

        Mock -CommandName Get-OneDriveRegistryStringValuesUnderPath -MockWith {
            @([pscustomobject]@{ KeyPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'; ValueName = 'Site'; Value = 'C:\OneDrive\FooBar\Docs' })
        }
        Mock -CommandName Set-ItemProperty

        Update-OneDriveSharePointCache -Account $account -OldPath 'C:\OneDrive\Foo' -NewPath 'D:\OneDrive\Foo' -Confirm:$false

        Should -Invoke Set-ItemProperty -Times 0 -ParameterFilter {
            $Name -eq 'Site'
        }
    }
}

Describe 'Update-OneDriveAccountRegistry' -Tag 'Light' {
    It "does not rewrite account cache values under a sibling folder whose root only shares the account folder prefix" {
        $account = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'Foo'
            UserFolder = 'C:\OneDrive\OneDrive - Foo'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $cacheKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            $Path -eq $cacheKey
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            [pscustomobject]@{ Site = 'C:\OneDrive\OneDrive - FooBar\Docs' }
        }
        Mock -CommandName Set-ItemProperty

        Update-OneDriveAccountRegistry -Account $account -NewPath 'D:\OneDrive\OneDrive - Foo' -Confirm:$false

        Should -Invoke Set-ItemProperty -Times 0 -ParameterFilter {
            $Path -eq $cacheKey -and $Name -eq 'Site'
        }
    }
}

Describe 'Invoke-RobocopyMirror' -Tag 'Light' {
    It 'uses /E plus /ZB so cross-volume copies stay restartable without /MIR deletes' {
        $script:capturedRobocopyArgs = $null
        function global:robocopy {
            param([Parameter(ValueFromRemainingArguments = $true)] $Args)
            $script:capturedRobocopyArgs = @($Args)
            $global:LASTEXITCODE = 3
        }

        try {
            Invoke-RobocopyMirror -Source 'C:\Source' -Destination 'D:\Dest' | Should -Be 3
            $script:capturedRobocopyArgs | Should -Contain '/E'
            $script:capturedRobocopyArgs | Should -Contain '/ZB'
            $script:capturedRobocopyArgs | Should -Not -Contain '/MIR'
            $script:capturedRobocopyArgs | Should -Not -Contain '/B'
        }
        finally {
            Remove-Item function:\global:robocopy -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Update-KfmBindings' -Tag 'Light' {
    It 'rewrites User Shell Folders and Shell Folders values under the old root' {
        $oldRoot = 'C:\Users\me\OneDrive - IntelliTect'
        $newRoot = 'C:\OneDrive\OneDrive - IntelliTect'
        $userShellKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $shellKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'

        Mock -CommandName Test-Path -MockWith { param($Path) $Path -in @($userShellKey, $shellKey) }
        Mock -CommandName Get-ItemProperty -MockWith {
            param($Path)
            switch ($Path) {
                $userShellKey { [pscustomobject]@{ Personal = "$oldRoot\Documents" } ; break }
                $shellKey { [pscustomobject]@{ 'My Pictures' = "$oldRoot\Pictures" } ; break }
                default { [pscustomobject]@{} }
            }
        }
        Mock -CommandName Get-Item -MockWith {
            [pscustomobject]@{
                GetValueKind = { param($Name) if ($Name -eq 'Personal') { 'ExpandString' } else { 'String' } }
            }
        }
        Mock -CommandName Set-ItemProperty

        Update-KfmBindings -OldRoot $oldRoot -NewRoot $newRoot -Confirm:$false

        Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter { $Path -eq $userShellKey -and $Name -eq 'Personal' -and $Value -eq "$newRoot\Documents" }
        Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter { $Path -eq $shellKey -and $Name -eq 'My Pictures' -and $Value -eq "$newRoot\Pictures" }
    }

    It 'does not touch FolderDescriptions registry internals' {
        $folderKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{374DE290-123F-4565-9164-39C4925E467B}'

        Mock -CommandName Test-Path -MockWith { param($Path) $Path -eq $folderKey }
        Mock -CommandName Get-ItemProperty
        Mock -CommandName Set-ItemProperty

        Update-KfmBindings -OldRoot 'C:\Users\me\OneDrive - IntelliTect' -NewRoot 'C:\OneDrive\OneDrive - IntelliTect' -Confirm:$false

        Should -Invoke Get-ItemProperty -Times 0 -ParameterFilter { $Path -like '*FolderDescriptions*' }
        Should -Invoke Set-ItemProperty -Times 0 -ParameterFilter { $Path -like '*FolderDescriptions*' }
    }

    It "does not rewrite KFM values under a sibling folder whose root only shares the old root prefix" {
        $shellKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            $Path -eq $shellKey
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            [pscustomobject]@{ Personal = 'C:\OneDrive\OneDrive - FooBar\Documents' }
        }
        Mock -CommandName Get-Item
        Mock -CommandName Set-ItemProperty

        Update-KfmBindings -OldRoot 'C:\OneDrive\OneDrive - Foo' -NewRoot 'D:\OneDrive\OneDrive - Foo' -Confirm:$false

        Should -Invoke Set-ItemProperty -Times 0 -ParameterFilter {
            $Path -eq $shellKey -and $Name -eq 'Personal'
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

    It 'preserves the renamed source after successful cross-volume copy verification by default' {
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
        Should -Invoke Remove-Item -Times 0 -ParameterFilter {
            $LiteralPath -eq 'C:\Users\me\OneDrive - IntelliTect.migrated-20240102-030405'
        }
    }

    It 'deletes the renamed source after verification when -DeleteSourceOnSuccess is supplied' {
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

        { Move-OneDriveFolder -Source 'C:\Users\me\OneDrive - IntelliTect' -Destination 'D:\OneDrive\OneDrive - IntelliTect' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*Original data was preserved*'

        Should -Invoke Move-Item -Times 1
        Should -Invoke Remove-Item -Times 0
    }

    It 'moves into an existing but empty destination by removing the empty directory first' {
        # A partial prior run -- or OneDrive re-creating an empty sync folder --
        # can leave an empty target. An empty destination is safe to move into.
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                'C:\OneDrive\OneDrive - IntelliTect' { $true; break }
                'C:\OneDrive' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-Item -MockWith { param($Path) [pscustomobject]@{ FullName = $Path } }
        Mock -CommandName Get-ChildItem -MockWith { @() }
        Mock -CommandName Test-IsSameVolume -MockWith { $true }
        Mock -CommandName Move-Item
        Mock -CommandName Remove-Item

        { Move-OneDriveFolder -Source 'C:\Users\me\OneDrive - IntelliTect' -Destination 'C:\OneDrive\OneDrive - IntelliTect' -Confirm:$false } |
            Should -Not -Throw

        Should -Invoke Remove-Item -Times 1 -ParameterFilter {
            $LiteralPath -eq 'C:\OneDrive\OneDrive - IntelliTect'
        }
        Should -Invoke Move-Item -Times 1 -ParameterFilter {
            $LiteralPath -eq 'C:\Users\me\OneDrive - IntelliTect' -and
            $Destination -eq 'C:\OneDrive\OneDrive - IntelliTect'
        }
    }

    It 'refuses to move into an existing non-empty destination' {
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\Users\me\OneDrive - IntelliTect' { $true; break }
                'C:\OneDrive\OneDrive - IntelliTect' { $true; break }
                'C:\OneDrive' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-Item -MockWith { param($Path) [pscustomobject]@{ FullName = $Path } }
        Mock -CommandName Get-ChildItem -MockWith { [pscustomobject]@{ Name = 'leftover.txt' } }
        Mock -CommandName Move-Item
        Mock -CommandName Remove-Item

        { Move-OneDriveFolder -Source 'C:\Users\me\OneDrive - IntelliTect' -Destination 'C:\OneDrive\OneDrive - IntelliTect' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*already exists and is not empty*'

        Should -Invoke Move-Item -Times 0
        Should -Invoke Remove-Item -Times 0
    }
}

Describe 'Invoke-OneDriveMigrationVerification' -Tag 'Light' {
    BeforeAll {
        function New-VerifyTestPlan {
            param([switch]$StartSkipped)
            @(
                [pscustomobject]@{ Type = 'CreateDir'; Target = 'C:\OneDrive'; DesiredValue = 'C:\OneDrive'; Account = $null },
                [pscustomobject]@{ Type = 'CreateDir'; Target = 'C:\OneDrive\IntelliTect'; DesiredValue = 'C:\OneDrive\IntelliTect'; Account = $script:verifyBusiness },
                [pscustomobject]@{ Type = 'WritePolicy'; PolicyKind = 'DefaultRootDir'; Account = $script:verifyBusiness; DesiredValue = 'C:\OneDrive\OneDrive - IntelliTect' },
                [pscustomobject]@{ Type = 'MoveAccount'; SharePointSite = $true; Status = 'Done'; CurrentValue = 'C:\Users\Mark\IntelliTect - Engineering'; DesiredValue = 'C:\OneDrive\IntelliTect\IntelliTect - Engineering'; Account = $script:verifyBusiness },
                [pscustomobject]@{ Type = 'RewriteKfm'; CurrentValue = 'C:\Users\me\OneDrive - IntelliTect'; DesiredValue = 'C:\OneDrive\OneDrive - IntelliTect'; Account = $script:verifyBusiness },
                [pscustomobject]@{ Type = 'StartOneDrive'; Skipped = [bool]$StartSkipped; Status = $(if ($StartSkipped) { 'Skipped' } else { 'Done' }) }
            )
        }

        $script:verifyBusiness = [pscustomobject]@{
            Slot         = 'Business1'
            AccountType  = 'Business'
            DisplayName  = 'IntelliTect'
            TenantId     = 'tid-1'
            UserFolder   = 'C:\OneDrive\OneDrive - IntelliTect'
            RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $script:verifyPersonal = [pscustomobject]@{
            Slot         = 'Personal'
            AccountType  = 'Personal'
            DisplayName  = $null
            TenantId     = $null
            UserFolder   = 'C:\OneDrive\OneDrive - Personal'
            RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal'
        }
    }

    BeforeEach {
        $script:verifyFailure = $null
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($script:verifyBusiness, $script:verifyPersonal) }
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            if ($Path -eq 'C:\OneDrive\IntelliTect') {
                return ($script:verifyFailure -ne 'B')
            }
            return $true
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param($Path, $Name)
            switch ("$Path|$Name") {
                'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1|UserFolder' {
                    [pscustomobject]@{ UserFolder = $(if ($script:verifyFailure -eq 'A') { 'C:\Wrong' } else { 'C:\OneDrive\OneDrive - IntelliTect' }) }
                    break
                }
                'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal|UserFolder' {
                    [pscustomobject]@{ UserFolder = 'C:\OneDrive\OneDrive - Personal' }
                    break
                }
                'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders|Personal' {
                    [pscustomobject]@{ Personal = $(if ($script:verifyFailure -eq 'C') { 'C:\Elsewhere\Documents' } else { 'C:\OneDrive\OneDrive - IntelliTect\Documents' }) }
                    break
                }
                'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir|tid-1' {
                    [pscustomobject]@{ 'tid-1' = $(if ($script:verifyFailure -eq 'D') { 'C:\Elsewhere' } else { 'C:\OneDrive\OneDrive - IntelliTect' }) }
                    break
                }
                default { [pscustomobject]@{} }
            }
        }
        Mock -CommandName Get-OneDriveRegistryStringValuesUnderPath -MockWith {
            param($Path)
            if ($script:verifyFailure -eq 'E' -and $Path -like '*ScopeIdToMountPointPathCache*') {
                return @([pscustomobject]@{
                    KeyPath   = $Path
                    ValueName = 'Site'
                    Value     = 'C:\Users\Mark\IntelliTect - Engineering\Docs'
                })
            }
            return @()
        }
        Mock -CommandName Get-Process -MockWith {
            if ($script:verifyFailure -eq 'F') { return $null }
            return [pscustomobject]@{ Name = 'OneDrive' }
        }
    }

    It 'returns Pass when all verification checks succeed' {
        $result = Invoke-OneDriveMigrationVerification -Plan (New-VerifyTestPlan)

        $result.OverallStatus | Should -Be 'Pass'
        $result.FailedChecks | Should -BeNullOrEmpty
        @($result.Checks | Where-Object Status -eq 'Pass').Count | Should -Be 6
    }

    It 'fails check A when an account UserFolder registry value does not match its target path' {
        $script:verifyFailure = 'A'

        $result = Invoke-OneDriveMigrationVerification -Plan (New-VerifyTestPlan)

        $result.OverallStatus | Should -Be 'Fail'
        ($result.FailedChecks | Select-Object -ExpandProperty Name) | Should -Contain 'A. Account UserFolder registry targets'
    }

    It 'fails check B when a planned tenant directory is missing' {
        $script:verifyFailure = 'B'

        $result = Invoke-OneDriveMigrationVerification -Plan (New-VerifyTestPlan)

        $result.OverallStatus | Should -Be 'Fail'
        ($result.FailedChecks | Select-Object -ExpandProperty Name) | Should -Contain 'B. Tenant directory existence'
    }

    It 'fails check C when Documents no longer resolves under the KFM owner target path' {
        $script:verifyFailure = 'C'

        $result = Invoke-OneDriveMigrationVerification -Plan (New-VerifyTestPlan)

        $result.OverallStatus | Should -Be 'Fail'
        ($result.FailedChecks | Select-Object -ExpandProperty Name) | Should -Contain 'C. KFM owner binding'
    }

    It 'fails check D when DefaultRootDir policy does not match the planned target path' {
        $script:verifyFailure = 'D'

        $result = Invoke-OneDriveMigrationVerification -Plan (New-VerifyTestPlan)

        $result.OverallStatus | Should -Be 'Fail'
        ($result.FailedChecks | Select-Object -ExpandProperty Name) | Should -Contain 'D. DefaultRootDir policy'
    }

    It 'fails check E when a SharePoint cache value still references the old root' {
        $script:verifyFailure = 'E'

        $result = Invoke-OneDriveMigrationVerification -Plan (New-VerifyTestPlan)

        $result.OverallStatus | Should -Be 'Fail'
        ($result.FailedChecks | Select-Object -ExpandProperty Name) | Should -Contain 'E. SharePoint cache old-root purge'
    }

    It 'fails check F when OneDrive.exe running state does not match the completed StartOneDrive plan item' {
        $script:verifyFailure = 'F'

        $result = Invoke-OneDriveMigrationVerification -Plan (New-VerifyTestPlan)

        $result.OverallStatus | Should -Be 'Fail'
        ($result.FailedChecks | Select-Object -ExpandProperty Name) | Should -Contain 'F. OneDrive.exe running state'
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
        Mock -CommandName Set-RootDirAclFromHome
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName Invoke-OneDriveMigrationVerification -MockWith { New-PassingVerificationResult }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir $rootDir -KfmOwner 'Michaelis' -Confirm:$false

        $createdPaths | Should -Contain $rootDir
        $createdPaths | Should -Contain $tenantDir
        $createdPaths | Should -Not -Contain $targetDir
        Should -Invoke Set-RootDirAclFromHome -Times 1 -ParameterFilter {
            $Path -eq $rootDir
        }
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
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }
        }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Set-RootDirAclFromHome
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName Invoke-OneDriveMigrationVerification -MockWith { New-PassingVerificationResult }
        Mock -CommandName New-Item
    }

    It 'does not restart OneDrive when it was not running before the script started' {
        Mock -CommandName Get-Process -MockWith { $null }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -Confirm:$false

        Should -Invoke Start-OneDriveExe -Times 0
    }

    It 'restarts OneDrive when it was running before the script started' {
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -Confirm:$false

        Should -Invoke Start-OneDriveExe -Times 1
    }
}

Describe 'Invoke-MarkMichaelisOneDriveConfiguration verification failure' -Tag 'Heavy' {
    It 'throws with the registry backup path when post-migration verification fails' {
        $rootDir = 'C:\OneDrive'
        $oldPath = 'C:\Users\me\OneDrive - IntelliTect'
        $newPath = 'C:\OneDrive\OneDrive - IntelliTect'
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = $oldPath; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $failedCheck = [pscustomobject]@{ Name = 'A. Account UserFolder registry targets'; Status = 'Fail'; Detail = 'mocked verification failure' }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                $rootDir { $true; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                $oldPath { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-OneDriveAccountList -MockWith { @($acct) }
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }
        }
        Mock -CommandName Get-ItemProperty -MockWith { [pscustomobject]@{} }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Set-RootDirAclFromHome
        Mock -CommandName Move-OneDriveFolder -MockWith { [pscustomobject]@{ SameVolume = $true; DeferredDeletePath = $null } }
        Mock -CommandName Get-OneDriveAccountRegistrySnapshot -MockWith { [pscustomobject]@{ UserFolder = $oldPath; CacheValues = @{} } }
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Invoke-OneDriveMigrationVerification -MockWith {
            [pscustomobject]@{
                Checks        = @($failedCheck)
                OverallStatus = 'Fail'
                FailedChecks  = @($failedCheck)
            }
        }
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName New-Item
        Mock -CommandName Write-OneDriveMigrationVerificationSummary
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }

        {
            Invoke-MarkMichaelisOneDriveConfiguration -RootDir $rootDir -KfmOwner 'Michaelis' -Confirm:$false
        } | Should -Throw -ExpectedMessage '*Start-Process*OneDrive.exe*'
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
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }
        }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Set-RootDirAclFromHome
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

        { Invoke-MarkMichaelisOneDriveConfiguration -RootDir $rootDir -KfmOwner 'Michaelis' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*registry write failed*'

        Should -Invoke Move-Item -Times 1 -ParameterFilter {
            $LiteralPath -eq $newPath -and $Destination -eq $oldPath
        }
        Should -Invoke Restore-OneDriveAccountRegistrySnapshot -Times 1
        Should -Invoke Start-OneDriveExe -Times 0
        Should -Invoke Write-Error -Times 1 -ParameterFilter { $Message -like '*Start-Process*OneDrive.exe*' }
    }
}

Describe 'Invoke-MarkMichaelisOneDriveConfiguration KFM mismatch handling' -Tag 'Heavy' {
    It 'warns and leaves KFM for the OneDrive UI when bound to another account for <Suffix>' -ForEach @(
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
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $kfmCurrent }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Set-RootDirAclFromHome
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName Invoke-OneDriveMigrationVerification -MockWith { New-PassingVerificationResult }
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Update-KfmBindings
        Mock -CommandName Write-Warning

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir $rootDir -KfmOwner 'Michaelis Consulting' -Confirm:$false

        Should -Invoke Update-KfmBindings -Times 0
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*leaving it for the OneDrive UI to reconfigure*' }
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
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { 'D:\Elsewhere\Documents' }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Set-RootDirAclFromHome
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName Invoke-OneDriveMigrationVerification -MockWith { New-PassingVerificationResult }
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Update-KfmBindings
        Mock -CommandName Write-Warning

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis Consulting' -Confirm:$false

        Should -Invoke Update-KfmBindings -Times 0
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*leaving it for the OneDrive UI to reconfigure*' }
    }
}

Describe 'New-OneDriveMigrationPlan root ACL hardening (#328)' -Tag 'Light' {
    It 're-asserts ACL hardening on the root even when it already exists' {
        # A pre-existing root may have inherited the world-readable drive-root
        # ACL (e.g. created by a plain mkdir). The hardening must run anyway so
        # the sync root is never left readable by every local account, while
        # the root CreateDir stays skipped because the directory is already there.
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
        Mock -CommandName Get-ItemProperty -MockWith { [pscustomobject]@{} }

        $plan = New-OneDriveMigrationPlan -RootDir 'C:\OneDrive' -Accounts @($acct) -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        $harden = @($plan | Where-Object { $_.Type -eq 'HardenRootDirAcl' -and $_.Target -eq 'C:\OneDrive' })
        $harden.Count | Should -Be 1
        $harden[0].Skipped | Should -BeFalse
        $rootCreate = @($plan | Where-Object { $_.Type -eq 'CreateDir' -and $_.Target -eq 'C:\OneDrive' })
        $rootCreate[0].Skipped | Should -BeTrue
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
        Mock -CommandName Set-RootDirAclFromHome -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Start-OneDriveExe -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Update-KfmBindings -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Invoke-AppFixUps -MockWith { throw 'state change not allowed under WhatIf' }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'OneDrive' } }

        { Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -WhatIf } |
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
        Mock -CommandName Set-RootDirAclFromHome
        Mock -CommandName Move-OneDriveFolder -MockWith { $script:firstRunComplete = $true }
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName Invoke-OneDriveMigrationVerification -MockWith { New-PassingVerificationResult }
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { $null }

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -Confirm:$false | Out-Null
        $secondPlan = Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -Confirm:$false

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
                return [pscustomobject]@{ GPOSetUpdateRing = 5 }
            }
            if ($Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -and $Name -eq 'UserFolder') {
                return [pscustomobject]@{ UserFolder = 'C:\OneDrive\OneDrive - IntelliTect' }
            }
            return [pscustomobject]@{}
        }

        $plan = New-OneDriveMigrationPlan -RootDir 'C:\OneDrive' -Accounts @($acct) -SharePointSites @($site) -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        ($plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.Target -eq 'C:\OneDrive\IntelliTect\IntelliTect - Engineering' }).Count | Should -Be 1
        ($plan | Where-Object { $_.Type -eq 'RewriteSPCache' -and $_.CurrentValue -eq 'C:\Users\Mark\IntelliTect - Engineering' -and $_.DesiredValue -eq 'C:\OneDrive\IntelliTect\IntelliTect - Engineering' }).Count | Should -Be 1
    }

    It 'gates cross-volume placeholder moves because cloud-only files must remain cloud-only' {
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

        $plan = New-OneDriveMigrationPlan -RootDir 'D:\OneDrive' -Accounts @($acct) -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        ($plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.SkipReason -like 'Refusing cross-volume move of 3 cloud-only files*' }).Count | Should -Be 1
    }

    It 'plans ACL hardening for a newly created RootDir' {
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'IntelliTect'
            UserEmail = 'user@example.com'; UserFolder = 'C:\OneDrive\OneDrive - IntelliTect'; TenantId = 'tid-1'; RegistryPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        }
        $decision = [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }

        Mock -CommandName Test-Path -MockWith {
            param($Path)
            switch ($Path) {
                'C:\OneDrive' { $false; break }
                'C:\OneDrive\IntelliTect' { $true; break }
                'C:\OneDrive\OneDrive - IntelliTect' { $true; break }
                default { $false }
            }
        }
        Mock -CommandName Get-ItemProperty -MockWith { [pscustomobject]@{} }

        $plan = New-OneDriveMigrationPlan -RootDir 'C:\OneDrive' -Accounts @($acct) -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        ($plan | Where-Object { $_.Type -eq 'HardenRootDirAcl' -and -not $_.Skipped -and $_.Target -eq 'C:\OneDrive' }).Count | Should -Be 1
    }

    It 'marks every plan item except the root ACL re-assertion skipped on a second idempotent run' {
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
                return [pscustomobject]@{ GPOSetUpdateRing = 5 }
            }
            if ($Path -eq 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -and $Name -eq 'UserFolder') {
                return [pscustomobject]@{ UserFolder = 'C:\OneDrive\OneDrive - IntelliTect' }
            }
            return [pscustomobject]@{}
        }

        $plan = New-OneDriveMigrationPlan -RootDir 'C:\OneDrive' -Accounts @($acct) -KfmCurrentPath $null -KfmDecision $decision -WasRunning:$false

        @($plan).Count | Should -BeGreaterThan 0
        $nonSkipped = @($plan | Where-Object { -not $_.Skipped })
        $nonSkipped.Count | Should -Be 1
        $nonSkipped[0].Type | Should -Be 'HardenRootDirAcl'
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
        $summary | Should -Match "Remove-Item -LiteralPath 'C:\\Old\.migrated-123' -Recurse -Force"
        $summary | Should -Match 'Failed: boom \| KFM'
    }

    It 'does not mention FreshSync in the user-facing summary' {
        $acct = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'; DisplayName = 'Michaelis'; UserFolder = 'C:\Users\Mark\OneDrive - Michaelis'
        }
        $plan = @(
            [pscustomobject]@{ Type='MoveAccount'; Target='C:\Users\Mark\OneDrive - Michaelis'; CurrentValue='C:\Users\Mark\OneDrive - Michaelis'; DesiredValue='C:\OneDrive\OneDrive - Michaelis'; Status='Done'; SkipReason=$null; FailureReason=$null; Account=$acct }
        )

        $summary = (Get-OneDriveMigrationSummaryLines -Accounts @($acct) -SharePointSites @() -Plan $plan) -join "`n"

        $summary | Should -Not -Match 'FreshSync'
        $summary | Should -Not -Match 'ACTION REQUIRED'
        $summary | Should -Match 'Michaelis'
    }
}

Describe 'Format-OneDriveMigrationPlan' -Tag 'Light' {
    BeforeAll {
        $script:b1 = [pscustomobject]@{
            Slot = 'Business1'; AccountType = 'Business'
            DisplayName = 'Michaelis'; UserEmail = 'mark@example.com'
            UserFolder = 'C:\Users\Mark\OneDrive - Michaelis'
        }
        $script:b2 = [pscustomobject]@{
            Slot = 'Business2'; AccountType = 'Business'
            DisplayName = 'IntelliTect'; UserEmail = 'mark@intellitect.com'
            UserFolder = 'C:\Users\Mark\OneDrive - IntelliTect'
        }
        $script:personal = [pscustomobject]@{
            Slot = 'Personal'; AccountType = 'Personal'
            DisplayName = $null; UserEmail = 'mark@outlook.com'
            UserFolder = 'C:\Users\Mark\OneDrive'
        }
        $script:allAccounts = @($script:b1, $script:b2, $script:personal)
    }

    BeforeEach {
        $script:capturedPlanLines = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Write-Host -MockWith {
            param($Object)
            $script:capturedPlanLines.Add([string]$Object) | Out-Null
        }
    }

    It "writes '[PLAN | -WhatIf]' under -WhatIf and '[APPLY]' otherwise" {
        Format-OneDriveMigrationPlan -Plan @() -Accounts $script:allAccounts `
            -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' `
            -WhatIfMode -HomeDir 'C:\Users\Mark'
        ($script:capturedPlanLines -join "`n") | Should -Match '\[PLAN \| -WhatIf\]'

        $script:capturedPlanLines.Clear()
        Format-OneDriveMigrationPlan -Plan @() -Accounts $script:allAccounts `
            -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' `
            -HomeDir 'C:\Users\Mark'
        ($script:capturedPlanLines -join "`n") | Should -Match '\[APPLY\]'
    }

    It 'mentions cross-volume warning when RootDir is on a different drive than HomeDir' {
        Format-OneDriveMigrationPlan -Plan @() -Accounts $script:allAccounts `
            -RootDir 'D:\OneDrive' -KfmOwner 'Michaelis' `
            -HomeDir 'C:\Users\Mark'
        ($script:capturedPlanLines -join "`n") | Should -Match 'cross-volume'
        ($script:capturedPlanLines -join "`n") | Should -Match 'cloud-only files are skipped'
    }

    It 'does NOT mention cross-volume when RootDir is on the same drive as HomeDir' {
        Format-OneDriveMigrationPlan -Plan @() -Accounts $script:allAccounts `
            -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' `
            -HomeDir 'C:\Users\Mark'
        ($script:capturedPlanLines -join "`n") | Should -Not -Match 'cross-volume'
    }

    It 'reports NOT ELEVATED without advertising a bypass' {
        Format-OneDriveMigrationPlan -Plan @() -Accounts $script:allAccounts `
            -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' `
            -IsElevated $false `
            -HomeDir 'C:\Users\Mark'
        ($script:capturedPlanLines -join "`n") | Should -Match 'NOT ELEVATED'
        ($script:capturedPlanLines -join "`n") | Should -Not -Match 'bypassed'
    }

    It 'reports elevation OK when running elevated' {
        Format-OneDriveMigrationPlan -Plan @() -Accounts $script:allAccounts `
            -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' `
            -IsElevated $true -HomeDir 'C:\Users\Mark'
        ($script:capturedPlanLines -join "`n") | Should -Match 'Elevation:\s+OK \(Administrator\)'
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

    It 'does not expose removed advanced script parameters' {
        $command = Get-Command $script:bundlePath

        $command.Parameters.Keys | Should -Contain 'DeleteSourceOnSuccess'

        foreach ($name in 'KfmOwnerContains','NoKfmRebind','NoFolderDescriptionsWrite','FreshSync','ForceHydrate','SkipElevationCheck') {
            $command.Parameters.Keys | Should -Not -Contain $name
        }
    }
}

Describe 'Script entry output (#334)' -Tag 'Heavy' {
    # End-to-end script-entry behavior: requires a machine with real OneDrive
    # accounts so the bundle runs through to returning its plan. Tagged Heavy
    # (excluded from the CI Light suite) for the same reason as the other
    # full-execution tests -- the CI runner has no OneDrive accounts, so
    # Get-OneDriveAccountList returns nothing and the orchestrator cannot build
    # a plan. Validated locally.
    BeforeAll {
        $script:bundlePath = "$PSScriptRoot\MarkMichaelisOneDriveConfiguration.ps1"
    }

    AfterEach {
        if (Test-Path 'Variable:Global:__MMOD_ForceIsElevated') {
            Remove-Variable -Name '__MMOD_ForceIsElevated' -Scope Global -Force
        }
    }

    It 'does not echo the raw plan object dump to the success stream when run as a script' {
        # The bundle already prints a human-readable plan summary via Write-Host
        # (the information stream). It must not ALSO emit the returned plan array
        # to the success stream, which PowerShell would auto-format into a second
        # raw object dump on the console.
        $global:__MMOD_ForceIsElevated = $true

        # Information (6) and warning (3) streams carry the intended summary and
        # the internal-API caveat; discard them so only the success stream
        # (stream 1) -- where an accidental object dump would land -- is captured.
        $successOutput = & $script:bundlePath -RootDir 'TestDrive:\OD' -WhatIf 3>$null 6>$null

        @($successOutput).Count | Should -Be 0
    }
}

Describe 'Test-OneDrivePathUnderRoot' -Tag 'Light' {
    It 'matches the root itself' {
        Test-OneDrivePathUnderRoot -Path 'C:\Users\me\OneDrive - Foo' -Root 'C:\Users\me\OneDrive - Foo' |
            Should -BeTrue
    }

    It 'matches a descendant of the root' {
        Test-OneDrivePathUnderRoot -Path 'C:\Users\me\OneDrive - Foo\Docs\a.txt' -Root 'C:\Users\me\OneDrive - Foo' |
            Should -BeTrue
    }

    It 'is case-insensitive' {
        Test-OneDrivePathUnderRoot -Path 'c:\users\ME\onedrive - foo\a.txt' -Root 'C:\Users\me\OneDrive - Foo' |
            Should -BeTrue
    }

    It 'does NOT treat a sibling sharing a name prefix as being under the root' {
        # 'OneDrive - Michaelis' must not be considered under 'OneDrive'.
        Test-OneDrivePathUnderRoot -Path 'C:\Users\me\OneDrive - Michaelis\a.txt' -Root 'C:\Users\me\OneDrive' |
            Should -BeFalse
    }
}

Describe 'ConvertFrom-OneDriveHandleOutput' -Tag 'Light' {
    It 'returns a blocker for a process holding a file under a root' {
        $lines = @(
            'SnagitEditor.exe   pid: 42672  type: File           424: C:\Users\me\OneDrive - Foo\shot.snagx'
        )
        $result = @(ConvertFrom-OneDriveHandleOutput -Line $lines -Root @('C:\Users\me\OneDrive - Foo'))

        $result.Count | Should -Be 1
        $result[0].Process | Should -Be 'SnagitEditor.exe'
        $result[0].Id | Should -Be 42672
        $result[0].Path | Should -Be 'C:\Users\me\OneDrive - Foo\shot.snagx'
    }

    It 'excludes OneDrive helper processes by default' {
        $lines = @(
            'OneDrive.exe              pid: 100  type: File           10: C:\Users\me\OneDrive - Foo\a.txt'
            'OneDrive.Sync.Service.exe pid: 101  type: File           11: C:\Users\me\OneDrive - Foo\b.txt'
            'FileCoAuth.exe            pid: 102  type: File           12: C:\Users\me\OneDrive - Foo\c.txt'
        )
        @(ConvertFrom-OneDriveHandleOutput -Line $lines -Root @('C:\Users\me\OneDrive - Foo')).Count |
            Should -Be 0
    }

    It 'includes OneDrive helper processes when -IncludeOneDriveProcesses is set' {
        $lines = @(
            'OneDrive.exe pid: 100  type: File           10: C:\Users\me\OneDrive - Foo\a.txt'
        )
        @(ConvertFrom-OneDriveHandleOutput -Line $lines -Root @('C:\Users\me\OneDrive - Foo') -IncludeOneDriveProcesses).Count |
            Should -Be 1
    }

    It 'does not report a handle under a name-prefixed sibling root (boundary)' {
        # Only the personal 'OneDrive' root is being moved; a handle under
        # 'OneDrive - Michaelis' must NOT be reported as blocking it.
        $lines = @(
            'Code.exe pid: 200  type: File           20: C:\Users\me\OneDrive - Michaelis\notes.md'
        )
        @(ConvertFrom-OneDriveHandleOutput -Line $lines -Root @('C:\Users\me\OneDrive')).Count |
            Should -Be 0
    }

    It 'ignores non-File and malformed handle lines' {
        $lines = @(
            'explorer.exe pid: 300  type: Key            30: \REGISTRY\MACHINE\SOFTWARE'
            'some banner text that is not a handle line'
            ''
        )
        @(ConvertFrom-OneDriveHandleOutput -Line $lines -Root @('C:\Users\me\OneDrive - Foo')).Count |
            Should -Be 0
    }
}

Describe 'Get-OneDriveMoveBlocker' -Tag 'Light' {
    It 'parses blockers from the scanned handle output' {
        Mock -CommandName Resolve-OneDriveHandleExe -MockWith { 'C:\tools\handle64.exe' }
        Mock -CommandName Invoke-OneDriveOpenHandleScan -MockWith {
            @('WINWORD.EXE pid: 5555  type: File           50: C:\Users\me\OneDrive - Foo\report.docx')
        }

        $result = @(Get-OneDriveMoveBlocker -Root @('C:\Users\me\OneDrive - Foo'))

        $result.Count | Should -Be 1
        $result[0].Process | Should -Be 'WINWORD.EXE'
        $result[0].Id | Should -Be 5555
    }

    It 'warns and returns nothing when handle.exe is not installed' {
        Mock -CommandName Resolve-OneDriveHandleExe -MockWith { $null }
        Mock -CommandName Invoke-OneDriveOpenHandleScan

        $result = @(Get-OneDriveMoveBlocker -Root @('C:\Users\me\OneDrive - Foo') -WarningAction SilentlyContinue)

        $result.Count | Should -Be 0
        Should -Invoke Invoke-OneDriveOpenHandleScan -Times 0
    }
}

Describe 'Invoke-MarkMichaelisOneDriveConfiguration open-handle pre-flight' -Tag 'Heavy' {
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
        Mock -CommandName Get-OneDriveSharePointSiteList -MockWith { @() }
        Mock -CommandName Get-CurrentKfmPath -MockWith { $null }
        Mock -CommandName Resolve-KfmRebindAction -MockWith {
            [pscustomobject]@{ Action = 'None'; OwnerAccount = $null; Reason = 'KFM inactive' }
        }
        Mock -CommandName Set-OneDriveTenantDefaultRootDirPolicy
        Mock -CommandName Set-OneDriveUpdateRingPolicy
        Mock -CommandName Export-OneDriveRegistryBackup -MockWith { 'C:\backup.reg' }
        Mock -CommandName Stop-OneDriveExe
        Mock -CommandName Set-RootDirAclFromHome
        Mock -CommandName Move-OneDriveFolder
        Mock -CommandName Update-OneDriveAccountRegistry
        Mock -CommandName Test-OneDriveFolderMoveVerification -MockWith { $true }
        Mock -CommandName Invoke-AppFixUps
        Mock -CommandName Start-OneDriveExe
        Mock -CommandName Invoke-OneDriveMigrationVerification -MockWith { New-PassingVerificationResult }
        Mock -CommandName New-Item
        Mock -CommandName Get-Process -MockWith { $null }
    }

    It 'aborts before any mutation when the user aborts at the blocker prompt' {
        Mock -CommandName Invoke-OneDriveMoveBlockerResolution -MockWith {
            throw 'Open file handles still block the OneDrive folder move. Close the listed applications and re-run. No changes were made.'
        }

        {
            Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -Confirm:$false -WarningAction SilentlyContinue
        } | Should -Throw -ExpectedMessage '*still block the OneDrive folder move*'

        Should -Invoke Stop-OneDriveExe -Times 0
        Should -Invoke Move-OneDriveFolder -Times 0
        Should -Invoke Export-OneDriveRegistryBackup -Times 0
    }

    It 'proceeds with the migration after the blocker resolution returns clear' {
        Mock -CommandName Invoke-OneDriveMoveBlockerResolution

        Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -Confirm:$false

        Should -Invoke Invoke-OneDriveMoveBlockerResolution -Times 1
        Should -Invoke Move-OneDriveFolder -Times 1
    }

    It 'reports blockers informationally under -WhatIf without prompting or throwing' {
        Mock -CommandName Get-OneDriveMoveBlocker -MockWith {
            @([pscustomobject]@{ Process = 'SnagitEditor.exe'; Id = 999; Path = 'C:\Users\me\OneDrive - IntelliTect\x.snagx' })
        }
        Mock -CommandName Invoke-OneDriveMoveBlockerResolution

        {
            Invoke-MarkMichaelisOneDriveConfiguration -RootDir 'C:\OneDrive' -KfmOwner 'Michaelis' -WhatIf -WarningAction SilentlyContinue
        } | Should -Not -Throw

        Should -Invoke Invoke-OneDriveMoveBlockerResolution -Times 0
        Should -Invoke Move-OneDriveFolder -Times 0
    }
}

Describe 'Invoke-OneDriveMoveBlockerResolution' -Tag 'Light' {
    BeforeEach {
        Mock -CommandName Stop-Process
        Mock -CommandName Start-Sleep
        Mock -CommandName Read-OneDriveBlockerAction -MockWith { 'Recheck' }
    }

    It 'returns without prompting when the first scan is clear' {
        Mock -CommandName Get-OneDriveMoveBlocker -MockWith { @() }

        Invoke-OneDriveMoveBlockerResolution -Root @('C:\Users\me\OneDrive - Foo') -Confirm:$false

        Should -Invoke Read-OneDriveBlockerAction -Times 0
        Should -Invoke Stop-Process -Times 0
    }

    It 'stops each blocking process when the user chooses Kill, then returns once clear' {
        $script:scanCount = 0
        Mock -CommandName Get-OneDriveMoveBlocker -MockWith {
            $script:scanCount++
            if ($script:scanCount -eq 1) {
                @([pscustomobject]@{ Process = 'SnagitEditor.exe'; Id = 999; Path = 'C:\Users\me\OneDrive - Foo\a.snagx' })
            } else { @() }
        }
        Mock -CommandName Read-OneDriveBlockerAction -MockWith { 'Kill' }

        Invoke-OneDriveMoveBlockerResolution -Root @('C:\Users\me\OneDrive - Foo') -Confirm:$false -WarningAction SilentlyContinue

        Should -Invoke Stop-Process -Times 1 -ParameterFilter { $Id -eq 999 }
    }

    It 'rescans without killing when the user chooses Recheck' {
        $script:scanCount = 0
        Mock -CommandName Get-OneDriveMoveBlocker -MockWith {
            $script:scanCount++
            if ($script:scanCount -eq 1) {
                @([pscustomobject]@{ Process = 'Code.exe'; Id = 222; Path = 'C:\Users\me\OneDrive - Foo\notes.md' })
            } else { @() }
        }
        Mock -CommandName Read-OneDriveBlockerAction -MockWith { 'Recheck' }

        Invoke-OneDriveMoveBlockerResolution -Root @('C:\Users\me\OneDrive - Foo') -Confirm:$false -WarningAction SilentlyContinue

        Should -Invoke Read-OneDriveBlockerAction -Times 1
        Should -Invoke Stop-Process -Times 0
    }

    It 'throws when the user chooses Abort' {
        Mock -CommandName Get-OneDriveMoveBlocker -MockWith {
            @([pscustomobject]@{ Process = 'WINWORD.EXE'; Id = 333; Path = 'C:\Users\me\OneDrive - Foo\report.docx' })
        }
        Mock -CommandName Read-OneDriveBlockerAction -MockWith { 'Abort' }

        {
            Invoke-OneDriveMoveBlockerResolution -Root @('C:\Users\me\OneDrive - Foo') -Confirm:$false -WarningAction SilentlyContinue
        } | Should -Throw -ExpectedMessage '*still block the OneDrive folder move*'

        Should -Invoke Stop-Process -Times 0
    }

    It 'does not stop processes under -WhatIf (ShouldProcess gate)' {
        Mock -CommandName Get-OneDriveMoveBlocker -MockWith {
            @([pscustomobject]@{ Process = 'SnagitEditor.exe'; Id = 999; Path = 'C:\Users\me\OneDrive - Foo\a.snagx' })
        }
        Mock -CommandName Read-OneDriveBlockerAction -MockWith { 'Kill' }

        {
            Invoke-OneDriveMoveBlockerResolution -Root @('C:\Users\me\OneDrive - Foo') -WhatIf -WarningAction SilentlyContinue
        } | Should -Throw

        Should -Invoke Stop-Process -Times 0
    }
}

Describe 'Get-OneDriveBlockerProcess' -Tag 'Light' {
    It 'collapses per-handle records into one record per process with a handle count' {
        $blockers = @(
            [pscustomobject]@{ Process = 'SnagitEditor.exe'; Id = 999; Path = 'C:\Users\me\OneDrive - Foo\a.snagx' }
            [pscustomobject]@{ Process = 'SnagitEditor.exe'; Id = 999; Path = 'C:\Users\me\OneDrive - Foo\b.snagx' }
            [pscustomobject]@{ Process = 'Code.exe'; Id = 222; Path = 'C:\Users\me\OneDrive - Foo\notes.md' }
        )

        $result = @(Get-OneDriveBlockerProcess -Blocker $blockers)

        $result.Count | Should -Be 2
        ($result | Where-Object Id -eq 999).HandleCount | Should -Be 2
        ($result | Where-Object Id -eq 222).HandleCount | Should -Be 1
    }
}
