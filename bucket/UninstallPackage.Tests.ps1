<#
.SYNOPSIS
    Light-suite Pester coverage for Uninstall-Package and the per-engine
    uninstall dispatch (Invoke-PackageUninstall + Uninstall-*Package).
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'Uninstall engine dispatchers' -Tag 'Light','Module' {

    Context 'Uninstall-WingetPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Uninstall-WingetPackage }
        }

        It 'returns NotInstalled when winget list returns non-zero' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $global:LASTEXITCODE = 1
                return ''
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'NotInstalled'
        }

        It 'invokes winget uninstall --id <Id> --silent and adds --scope machine for global' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id'; Scope='global' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Uninstalled'
            $script:captured[0] | Should -Be 'uninstall'
            ($script:captured -contains '--id')     | Should -BeTrue
            ($script:captured -contains 'Test.Id')  | Should -BeTrue
            ($script:captured -contains '--silent') | Should -BeTrue
            $hasScope = $false
            for ($i=0; $i -lt $script:captured.Count; $i++) {
                if ($script:captured[$i] -eq '--scope' -and $script:captured[$i+1] -eq 'machine') { $hasScope = $true }
            }
            $hasScope | Should -BeTrue
        }

        It 'omits --scope machine for user-scoped packages' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id'; Scope='user' }
            $null = & $script:Engine -Package $pkg
            ($script:captured -contains '--scope') | Should -BeFalse
        }

        It 'returns Failed when winget exits non-zero' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $global:LASTEXITCODE = 5
                return 'error'
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match '5'
        }
    }

    Context 'Uninstall-ScoopPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Uninstall-ScoopPackage }
        }

        It 'strips the bucket prefix and calls scoop uninstall with the bare app name' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                if ($args[0] -eq 'list') { return "ripgrep 13.0.0" }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep' }
            $r = & $script:Engine -Package $pkg
            $r.State           | Should -Be 'Uninstalled'
            $script:captured[0] | Should -Be 'uninstall'
            $script:captured[1] | Should -Be 'ripgrep'
        }

        It 'returns NotInstalled when scoop list has no row' {
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                if ($args[0] -eq 'list') { return '' }
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'NotInstalled'
        }
    }

    Context 'Uninstall-ChocoPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Uninstall-ChocoPackage }
        }

        It 'calls choco uninstall with -y flag when installed' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return 'nodejs 18.0.0' }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State           | Should -Be 'Uninstalled'
            $script:captured[0] | Should -Be 'uninstall'
            $script:captured[1] | Should -Be 'nodejs'
            ($script:captured -contains '-y') | Should -BeTrue
        }

        It 'returns NotInstalled when choco list has no row' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return '' }
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'NotInstalled'
        }

        It 'maps choco exit 1605 to NotInstalled' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return 'nodejs 18.0.0' }
                $global:LASTEXITCODE = 1605
                return ''
            }
            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'NotInstalled'
        }
    }

    Context 'Uninstall-NpmGlobalPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Uninstall-NpmGlobalPackage }
        }

        It 'returns Failed when npm not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -in @('npm','npm.cmd') }
            $pkg = [Package]@{ Name='claude-code'; Installer='npmGlobal'; Id='@anthropic-ai/claude-code' }
            $r = & $script:Engine -Package $pkg
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match 'npm'
        }
    }

    Context 'Uninstall-DotnetToolPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Uninstall-DotnetToolPackage }
        }

        It 'returns Failed when dotnet not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'dotnet' }
            $pkg = [Package]@{ Name='poshmcp'; Installer='dotnetTool'; Id='poshmcp' }
            $r = & $script:Engine -Package $pkg
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match 'dotnet'
        }
    }
}

Describe 'Invoke-PackageUninstall pipeline' -Tag 'Light','Module' {

    BeforeEach {
        Mock -ModuleName MarkMichaelis.ScoopBucket Uninstall-WingetPackage     { return @{ State='Uninstalled'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Uninstall-ScoopPackage      { return @{ State='Uninstalled'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Uninstall-ChocoPackage      { return @{ State='Uninstalled'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Uninstall-NpmGlobalPackage  { return @{ State='Uninstalled'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Uninstall-DotnetToolPackage { return @{ State='Uninstalled'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Remove-PackageCompletionBlock { return [pscustomobject]@{ Cli=$Cli; Action='Removed' } }
    }

    It 'dispatches packages to the correct per-installer uninstall' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A' }
            [Package]@{ Name='B'; Installer='choco';  Id='b' }
            [Package]@{ Name='C'; Installer='scoop';  Id='main/c' }
        )
        $r = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $r.Count | Should -Be 3
        ($r | ForEach-Object State) -join ',' | Should -Be 'Uninstalled,Uninstalled,Uninstalled'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Uninstall-WingetPackage -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Uninstall-ChocoPackage  -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Uninstall-ScoopPackage  -Times 1 -Exactly
    }

    It 'records NotInstalled when the engine reports NotInstalled' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Uninstall-WingetPackage {
            return @{ State='NotInstalled'; Reason='probe said no' }
        }
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $r = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $r[0].State  | Should -Be 'NotInstalled'
        $r[0].Reason | Should -Match 'probe said no'
    }

    It 'invokes CustomUninstallScript for Installer=custom' {
        $script:customRan = $false
        $pkgs = [Package[]]@(
            [Package]@{
                Name='Readwise'; Installer='custom'
                CustomInstallScript   = { }
                CustomUninstallScript = { $script:customRan = $true }
            }
        )
        $r = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:customRan | Should -BeTrue
        $r[0].State | Should -Be 'Uninstalled'
    }

    It 'records Skipped when Installer=custom has no CustomUninstallScript' {
        $pkgs = [Package[]]@(
            [Package]@{
                Name='Readwise'; Installer='custom'
                CustomInstallScript = { }
            }
        )
        $r = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $r[0].State  | Should -Be 'Skipped'
        $r[0].Reason | Should -Match 'no CustomUninstallScript'
    }

    It 'honors -DryRun: engines receive -WhatIf and presence probe is skipped' {
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $r = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -SkipCompletion -DryRun
        $r[0].State | Should -Be 'Uninstalled'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Uninstall-WingetPackage -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
    }

    It '-DryRun does not strip completion blocks' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'; CliCommands=@('gh'); Completion='pscompletions'; ExpectedCompletions=@{ gh = @('auth','repo','pr') } }
        )
        $null = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -DryRun
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Remove-PackageCompletionBlock -Times 0
    }

    It '-KeepCompletion skips Remove-PackageCompletionBlock' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'; CliCommands=@('gh'); Completion='pscompletions'; ExpectedCompletions=@{ gh = @('auth','repo','pr') } }
        )
        $null = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -KeepCompletion
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Remove-PackageCompletionBlock -Times 0
    }

    It 'removes completion blocks for every CliCommand by default' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'; CliCommands=@('foo','bar'); Completion='pscompletions'; ExpectedCompletions=@{ foo = @('a','b','c'); bar = @('a','b','c') } }
        )
        $null = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Remove-PackageCompletionBlock -Times 2
    }

    It 'skips CISkip packages when $env:CI is truthy' {
        $oldCi = $env:CI
        $env:CI = 'true'
        try {
            $pkgs = [Package[]]@(
                [Package]@{ Name='Pushbullet'; Installer='winget'; Id='Foo.PB'; CISkip='no machine-scope installer' }
                [Package]@{ Name='Other';      Installer='winget'; Id='Foo.X' }
            )
            $r = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
            ($r | Where-Object Name -eq 'Pushbullet').State | Should -Be 'Skipped'
            ($r | Where-Object Name -eq 'Other').State      | Should -Be 'Uninstalled'
        } finally {
            if ($null -eq $oldCi) { Remove-Item Env:\CI -ErrorAction Ignore }
            else { $env:CI = $oldCi }
        }
    }

    It 'stores the result on $global:LASTUNINSTALLREPORT' {
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $null = Invoke-PackageUninstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $global:LASTUNINSTALLREPORT | Should -Not -BeNullOrEmpty
        $global:LASTUNINSTALLREPORT[0].Bundle | Should -Be 'Test'
    }
}

Describe 'Remove-PackageCompletionBlock' -Tag 'Light','Module' {

    BeforeAll {
        $script:Register   = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Register-PackageCompletion }
        $script:RemoveFn   = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Remove-PackageCompletionBlock }
        $script:profileDir = Join-Path $TestDrive 'uninstall-profile-dir'
        New-Item -ItemType Directory -Path $script:profileDir -Force | Out-Null
    }

    BeforeEach {
        $script:profilePath = Join-Path $script:profileDir "profile-$([guid]::NewGuid()).ps1"
    }

    It 'strips a previously registered sentinel block' {
        $null = & $script:Register -Cli 'rmcli' `
            -NativeCommand { 'Register-ArgumentCompleter -CommandName rmcli -ScriptBlock { ''hi'' }' } `
            -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false
        (Get-Content $script:profilePath -Raw) | Should -Match 'ScoopBucket:CliCompletion:rmcli:BEGIN'

        $r = & $script:RemoveFn -Cli 'rmcli' -ProfilePath $script:profilePath -Confirm:$false
        $r.Action | Should -Be 'Removed'
        (Get-Content $script:profilePath -Raw) | Should -Not -Match 'ScoopBucket:CliCompletion:rmcli:BEGIN'
    }

    It 'returns NotPresent when the profile has no matching block' {
        Set-Content -Path $script:profilePath -Value '# nothing here' -Encoding UTF8
        $r = & $script:RemoveFn -Cli 'nope' -ProfilePath $script:profilePath -Confirm:$false
        $r.Action | Should -Be 'NotPresent'
    }

    It 'returns NotPresent when the profile file does not exist' {
        $r = & $script:RemoveFn -Cli 'nope' -ProfilePath (Join-Path $TestDrive 'absent.ps1') -Confirm:$false
        $r.Action | Should -Be 'NotPresent'
    }

    It 'leaves blocks for other CLIs untouched' {
        $null = & $script:Register -Cli 'keepme' -NativeCommand { 'Register-ArgumentCompleter -CommandName keepme -ScriptBlock { } ' } `
            -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false
        $null = & $script:Register -Cli 'goaway' -NativeCommand { 'Register-ArgumentCompleter -CommandName goaway -ScriptBlock { } ' } `
            -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false

        $null = & $script:RemoveFn -Cli 'goaway' -ProfilePath $script:profilePath -Confirm:$false

        $after = Get-Content $script:profilePath -Raw
        $after | Should -Match 'ScoopBucket:CliCompletion:keepme:BEGIN'
        $after | Should -Not -Match 'ScoopBucket:CliCompletion:goaway:BEGIN'
    }
}

Describe 'Uninstall-Package dispatch (bundle + name)' -Tag 'Light','Module' {

    BeforeAll {
        $script:repoRoot   = Split-Path -Parent $PSScriptRoot
        $script:psd1       = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'

        $script:tmpBucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-uninstall-test-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpBucket | Out-Null

        $bundleText = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{ Name = 'alpha'; Installer = 'winget'; Id = 'Test.Alpha' }
    [Package]@{ Name = 'bravo'; Installer = 'winget'; Id = 'Test.Bravo' }
    [Package]@{ Name = 'charlie'; Installer = 'choco'; Id = 'charlie' }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'UninstTestBundle'
"@
        Set-Content -Path (Join-Path $script:tmpBucket 'UninstTestBundle.ps1') -Value $bundleText -Encoding UTF8

        $bundleManifest = @{
            '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
            version   = '1.00.000'
            url       = @('https://example.invalid/test-bundle')
            installer = @{ script = @('& "$dir\\UninstTestBundle.ps1"') }
        }
        Set-Content -LiteralPath (Join-Path $script:tmpBucket 'UninstTestBundle.json') `
            -Value ($bundleManifest | ConvertTo-Json -Depth 4) -Encoding UTF8
    }

    AfterAll {
        if ($script:tmpBucket -and (Test-Path $script:tmpBucket)) {
            Remove-Item -LiteralPath $script:tmpBucket -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'dispatches a single package by Name (DryRun plans without invoking engines)' {
        $output = Uninstall-Package -Name 'alpha' -DryRun -SkipCompletion -BucketPath $script:tmpBucket *>&1 | Out-String
        $output | Should -Match "dispatching alpha via UninstTestBundle"
        $output | Should -Match "=== Invoke-PackageUninstall: UninstTestBundle \(1 packages\) ==="
        $output | Should -Match "\[uninstall\] \[winget\] alpha"
        $output | Should -Not -Match "\[uninstall\] \[winget\] bravo"
    }

    It 'dispatches every package when given the bundle name' {
        $output = Uninstall-Package -Name 'UninstTestBundle' -DryRun -SkipCompletion -BucketPath $script:tmpBucket *>&1 | Out-String
        $output | Should -Match "dispatching bundle 'UninstTestBundle' \(all packages\)"
        $output | Should -Match "\[uninstall\] \[winget\] alpha"
        $output | Should -Match "\[uninstall\] \[winget\] bravo"
        $output | Should -Match "\[uninstall\] \[choco\] charlie"
    }

    It 'throws a helpful error when neither package, bundle, nor manifest matches' {
        { Uninstall-Package -Name 'NoSuchPkg' -DryRun -SkipCompletion -BucketPath $script:tmpBucket } |
            Should -Throw -ExpectedMessage "*no bundle declares a package named 'NoSuchPkg'*"
    }
}
