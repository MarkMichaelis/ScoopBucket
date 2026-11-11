#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    A bundle install continues past a failed package (#522).

.DESCRIPTION
    Bundle scripts -- the ones scoop runs -- call Invoke-PackageInstall with no
    -ErrorAction. The module runs with $ErrorActionPreference = 'Stop', so the
    first per-package WriteError used to be terminating: OSBasePackages stopped
    at 7-Zip and never reached the remaining packages.

    Contract pinned here:
      - no -ErrorAction: every package is attempted, every result row is
        emitted, then ONE summary error names the failures so scoop does not
        record the bundle as installed and retries next update;
      - an explicit -ErrorAction keeps its standard meaning (Install-Package
        passes Continue; a caller may pass Stop).
#>

BeforeAll {
    $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $psd1 -Force

    # BadOne fails validation (winget needs an Id). Reached is a custom
    # package whose install records that the sweep got to it.
    $script:newPackages = {
        [Package[]]@(
            [Package]@{ Name = 'BadOne'; Installer = 'winget' }
            [Package]@{ Name = 'Reached'; Installer = 'custom'
                        CustomInstallScript = { $global:InvokePackageInstallContinueReached = $true } }
            [Package]@{ Name = 'BadTwo'; Installer = 'winget' }
        )
    }
}

Describe 'Invoke-PackageInstall continues past a failed package (#522)' -Tag 'Light', 'Module' {

    BeforeEach {
        $global:InvokePackageInstallContinueReached = $false
    }

    AfterAll {
        Remove-Variable -Name InvokePackageInstallContinueReached -Scope Global -ErrorAction Ignore
    }

    Context 'called bare, as a bundle script calls it' {

        It 'installs the packages after a failure' {
            try {
                Invoke-PackageInstall -Packages (& $script:newPackages) -Bundle 'Probe' -SkipCompletion 2>$null | Out-Null
            } catch { }
            $global:InvokePackageInstallContinueReached | Should -BeTrue
        }

        It 'emits a result row for every package' {
            try {
                Invoke-PackageInstall -Packages (& $script:newPackages) -Bundle 'Probe' -SkipCompletion `
                    -OutVariable rows 2>$null | Out-Null
            } catch { }
            @($rows | ForEach-Object { "$($_.Name)=$($_.Status)" }) |
                Should -Be @('BadOne=Failed', 'Reached=Installed', 'BadTwo=Failed')
        }

        It 'ends with one terminating error naming every failed package' {
            $thrown = $null
            try {
                Invoke-PackageInstall -Packages (& $script:newPackages) -Bundle 'Probe' -SkipCompletion 2>$null | Out-Null
            } catch { $thrown = $_ }
            $thrown | Should -Not -BeNullOrEmpty -Because 'scoop must not record a partly-failed bundle as installed'
            $thrown.Exception.Message | Should -Match 'BadOne'
            $thrown.Exception.Message | Should -Match 'BadTwo'
            $thrown.Exception.Message | Should -Not -Match 'Reached'
        }

        It 'does not throw when every package succeeds' {
            $ok = [Package[]]@([Package]@{ Name = 'Reached'; Installer = 'custom'
                                           CustomInstallScript = { $global:InvokePackageInstallContinueReached = $true } })
            { Invoke-PackageInstall -Packages $ok -Bundle 'Probe' -SkipCompletion | Out-Null } | Should -Not -Throw
        }
    }

    Context 'with an explicit -ErrorAction' {

        It 'Continue: attempts every package, returns the rows, and does not throw' {
            $rows = @(Invoke-PackageInstall -Packages (& $script:newPackages) -Bundle 'Probe' -SkipCompletion `
                    -ErrorAction Continue 2>$null)
            $rows.Count | Should -Be 3
            $global:InvokePackageInstallContinueReached | Should -BeTrue
        }

        It 'Stop: stops at the first failure' {
            { Invoke-PackageInstall -Packages (& $script:newPackages) -Bundle 'Probe' -SkipCompletion `
                    -ErrorAction Stop } | Should -Throw '*BadOne*'
            $global:InvokePackageInstallContinueReached | Should -BeFalse
        }
    }
}
