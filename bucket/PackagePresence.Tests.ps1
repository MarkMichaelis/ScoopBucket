#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Get-PackagePresence answers "is this package installed?" without installing
# anything (#454). Install-Package -Name '*' asks it about optional packages,
# and the install engines use it for their own AlreadyInstalled check, so the
# two can never disagree. Present is $true, $false, or $null when the answer is
# unknowable (a probe that failed, or a custom package with nothing to check).

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
    $script:Probe = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Get-PackagePresence }
}

Describe 'Get-PackagePresence (#454)' -Tag 'Light', 'Module' {
    Context 'winget' {
        It 'reports installed when the winget probe finds the package' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Test-WingetPackageInstalled {
                @{ Installed = $true; Id = 'Test.App'; ExitCode = 0; Command = 'winget list --id Test.App --exact'
                   Reason = 'winget list --id Test.App --exact returned 0.' }
            }
            $r = & $script:Probe -Package ([Package]@{ Name = 'app'; Installer = 'winget'; Id = 'Test.App' })
            $r.Present | Should -BeTrue
            $r.Reason  | Should -Match 'winget list --id Test.App --exact'
        }

        It 'reports not installed when the winget probe does not' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Test-WingetPackageInstalled {
                @{ Installed = $false; Id = ''; ExitCode = -1978335212; Command = 'winget list --id Test.App'
                   Reason = 'winget list --id Test.App returned -1978335212.' }
            }
            $r = & $script:Probe -Package ([Package]@{ Name = 'app'; Installer = 'winget'; Id = 'Test.App' })
            $r.Present | Should -BeFalse
        }

        It 'reports unknown when the probe throws' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Test-WingetPackageInstalled { throw 'winget is broken' }
            $r = & $script:Probe -Package ([Package]@{ Name = 'app'; Installer = 'winget'; Id = 'Test.App' })
            $r.Present | Should -BeNullOrEmpty
            $r.Reason  | Should -Match 'winget is broken'
        }
    }

    Context 'scoop' {
        It 'reports installed when scoop list returns a row for the app, ignoring the bucket prefix' {
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop { "Name    Version`n----    -------`nripgrep 14.1.0" }
            $r = & $script:Probe -Package ([Package]@{ Name = 'rg'; Installer = 'scoop'; Id = 'main/ripgrep' })
            $r.Present | Should -BeTrue
        }

        It 'reports not installed when scoop list returns no row' {
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop { '' }
            $r = & $script:Probe -Package ([Package]@{ Name = 'rg'; Installer = 'scoop'; Id = 'main/ripgrep' })
            $r.Present | Should -BeFalse
        }
    }

    Context 'choco' {
        It 'reports installed when choco list shows the package' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco { 'nodejs 18.0.0' }
            $r = & $script:Probe -Package ([Package]@{ Name = 'node'; Installer = 'choco'; Id = 'nodejs' })
            $r.Present | Should -BeTrue
        }

        It 'reports not installed when choco list does not' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco { '0 packages installed.' }
            $r = & $script:Probe -Package ([Package]@{ Name = 'node'; Installer = 'choco'; Id = 'nodejs' })
            $r.Present | Should -BeFalse
        }
    }

    Context 'npmGlobal and dotnetTool' {
        It 'reports an npm package as not installed when npm itself is missing' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { $null } -ParameterFilter { $Name -in @('npm', 'npm.cmd') }
            $r = & $script:Probe -Package ([Package]@{ Name = 'cc'; Installer = 'npmGlobal'; Id = '@anthropic-ai/claude-code' })
            $r.Present | Should -BeFalse
        }

        It 'reports a dotnet tool as not installed when dotnet itself is missing' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet' }
            $r = & $script:Probe -Package ([Package]@{ Name = 'tool'; Installer = 'dotnetTool'; Id = 'Some.Tool' })
            $r.Present | Should -BeFalse
        }

        It 'reports a dotnet tool as installed when dotnet tool list shows it' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { [pscustomobject]@{ Name = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
            Mock -ModuleName MarkMichaelis.ScoopBucket dotnet { "Package Id      Version      Commands`n---------------------`nsome.tool       1.2.3        st" }
            $r = & $script:Probe -Package ([Package]@{ Name = 'tool'; Installer = 'dotnetTool'; Id = 'some.tool' })
            $r.Present | Should -BeTrue
        }
    }

    Context 'custom' {
        It 'asks the VerifyScript' {
            $yes = [Package]@{ Name = 'c'; CustomInstallScript = { }; VerifyScript = { $true } }
            $no  = [Package]@{ Name = 'c'; CustomInstallScript = { }; VerifyScript = { $false } }
            (& $script:Probe -Package $yes).Present | Should -BeTrue
            (& $script:Probe -Package $no).Present  | Should -BeFalse
        }

        It 'reports unknown when there is nothing to check' {
            $r = & $script:Probe -Package ([Package]@{ Name = 'c'; CustomInstallScript = { } })
            $r.Present | Should -BeNullOrEmpty
        }
    }
}
