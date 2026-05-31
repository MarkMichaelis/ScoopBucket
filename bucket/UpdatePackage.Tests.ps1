<#
.SYNOPSIS
    Light-suite Pester coverage for Update-Package and the per-engine
    update dispatch (Invoke-PackageUpdate + Update-*Package).
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'Update engine dispatchers' -Tag 'Light','Module' {

    Context 'Update-WingetPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-WingetPackage }
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

        It 'invokes winget upgrade --id <Id> --silent with --scope machine for global' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id'; Scope='global' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'upgrade'
            ($script:captured -contains '--id')                          | Should -BeTrue
            ($script:captured -contains 'Test.Id')                       | Should -BeTrue
            ($script:captured -contains '--silent')                      | Should -BeTrue
            ($script:captured -contains '--accept-package-agreements')   | Should -BeTrue
            ($script:captured -contains '--accept-source-agreements')    | Should -BeTrue
            $hasScope = $false
            for ($i=0; $i -lt $script:captured.Count; $i++) {
                if ($script:captured[$i] -eq '--scope' -and $script:captured[$i+1] -eq 'machine') { $hasScope = $true }
            }
            $hasScope | Should -BeTrue
        }

        It 'maps exit -1978335212 (no applicable upgrade) to AlreadyLatest' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $global:LASTEXITCODE = -1978335212
                return ''
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'AlreadyLatest'
        }

        It 'appends WingetExtraArgs to the upgrade command' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id'; WingetExtraArgs=@('--skip-dependencies') }
            $null = & $script:Engine -Package $pkg
            ($script:captured -contains '--skip-dependencies') | Should -BeTrue
        }

        It 'returns Failed on unrecognized non-zero exit' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $global:LASTEXITCODE = 7
                return 'oops'
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match '7'
        }
    }

    Context 'Update-ScoopPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-ScoopPackage }
        }

        It 'strips bucket prefix and calls scoop update <app>' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                if ($args[0] -eq 'list') { return "ripgrep 13.0.0" }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return 'Updating ripgrep ... done.'
            }
            $pkg = [Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep' }
            $r = & $script:Engine -Package $pkg
            $r.State            | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'update'
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

        It 'maps "latest version" output to AlreadyLatest' {
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                if ($args[0] -eq 'list') { return "ripgrep 13.0.0" }
                $global:LASTEXITCODE = 0
                return "The latest version of 'ripgrep' (13.0.0) is already installed."
            }
            $pkg = [Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'AlreadyLatest'
        }
    }

    Context 'Update-ChocoPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-ChocoPackage }
        }

        It 'calls choco upgrade with -y --no-progress' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return 'nodejs 18.0.0' }
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State            | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'upgrade'
            $script:captured[1] | Should -Be 'nodejs'
            ($script:captured -contains '-y')            | Should -BeTrue
            ($script:captured -contains '--no-progress') | Should -BeTrue
        }

        It 'maps choco exit 2 to AlreadyLatest' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return 'nodejs 18.0.0' }
                $global:LASTEXITCODE = 2
                return ''
            }
            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'AlreadyLatest'
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

    Context 'Update-NpmGlobalPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-NpmGlobalPackage }
        }

        It 'returns Failed when npm.cmd not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'npm.cmd' }
            $pkg = [Package]@{ Name='claude-code'; Installer='npmGlobal'; Id='@anthropic-ai/claude-code' }
            $r = & $script:Engine -Package $pkg
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match 'npm'
        }
    }

    Context 'Update-DotnetToolPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-DotnetToolPackage }
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

Describe 'Invoke-PackageUpdate pipeline' -Tag 'Light','Module' {

    BeforeEach {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage     { return @{ State='Updated'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-ScoopPackage      { return @{ State='Updated'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-ChocoPackage      { return @{ State='Updated'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-NpmGlobalPackage  { return @{ State='Updated'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-DotnetToolPackage { return @{ State='Updated'; Reason=$null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-PathFromRegistry  { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion { }
    }

    It 'dispatches packages to the correct per-installer update' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A' }
            [Package]@{ Name='B'; Installer='choco';  Id='b' }
            [Package]@{ Name='C'; Installer='scoop';  Id='main/c' }
        )
        $r = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion)
        $r.Count | Should -Be 3
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-ChocoPackage  -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-ScoopPackage  -Times 1 -Exactly
    }

    It 'emits a Failed ErrorRecord when an engine returns Failed' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            return @{ State='Failed'; Reason='boom' }
        }
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $errs = $null
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion -ErrorVariable errs -ErrorAction SilentlyContinue
        $errs.Count | Should -BeGreaterThan 0
        $errs[0].FullyQualifiedErrorId | Should -Match 'PackageUpdateFailed'
    }

    It 'skips custom installs without PostUpdateScript' {
        $pkgs = [Package[]]@(
            [Package]@{
                Name='Readwise'; Installer='custom'
                CustomInstallScript = { }
            }
        )
        $r = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion)
        # Skipped packages emit on the success stream with the [Package]
        # itself; assert via the host-stream summary by re-running
        # behaviorally — the package surfaces and no engine was called.
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 0 -Exactly
    }

    It 'runs PostUpdateScript for custom installs that set it' {
        $script:hookRan = $false
        $pkgs = [Package[]]@(
            [Package]@{
                Name='Readwise'; Installer='custom'
                CustomInstallScript = { }
                PostUpdateScript    = { $script:hookRan = $true }
            }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:hookRan | Should -BeTrue
    }

    It 'runs PostUpdateScript after engine update for declarative installs' {
        $script:hookRan = $false
        $pkgs = [Package[]]@(
            [Package]@{
                Name='A'; Installer='winget'; Id='Foo.A'
                PostUpdateScript = { $script:hookRan = $true }
            }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:hookRan | Should -BeTrue
    }

    It 'short-circuits NotInstalled without re-registering completion' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            return @{ State='NotInstalled'; Reason='probe said no' }
        }
        $pkgs = [Package[]]@(
            [Package]@{
                Name='A'; Installer='winget'; Id='Foo.A'
                CliCommands=@('a'); Completion='native'
                NativeCommandScript = { 'x' }
                ExpectedCompletions = @{ a = @('--help') }
            }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 0 -Exactly
    }

    It 'does NOT re-register completion when engine reports AlreadyLatest' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            return @{ State='AlreadyLatest'; Reason='same' }
        }
        $pkgs = [Package[]]@(
            [Package]@{
                Name='A'; Installer='winget'; Id='Foo.A'
                CliCommands=@('a'); Completion='native'
                NativeCommandScript = { 'x' }
                ExpectedCompletions = @{ a = @('--help') }
            }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 0 -Exactly
    }

    It 'AlreadyLatest short-circuits PATH refresh and PostUpdateScript' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            return @{ State='AlreadyLatest'; Reason='same' }
        }
        $script:hookRan = $false
        $pkgs = [Package[]]@(
            [Package]@{
                Name='A'; Installer='winget'; Id='Foo.A'
                PostUpdateScript = { $script:hookRan = $true }
            }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:hookRan | Should -BeFalse
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-PathFromRegistry -Times 0 -Exactly
    }

    It 'DOES re-register completion when engine reports Updated' {
        $pkgs = [Package[]]@(
            [Package]@{
                Name='A'; Installer='winget'; Id='Foo.A'
                CliCommands=@('a','b'); Completion='native'
                NativeCommandScript = { 'x' }
                ExpectedCompletions = @{ a = @('--help'); b = @('--help') }
            }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 2 -Exactly
    }

    It 'engines receive -WhatIf when -DryRun is set' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -ParameterFilter { $WhatIf } { return @{ State='Updated'; Reason='(WhatIf)' } }
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -DryRun -SkipCompletion
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 1 -Exactly -ParameterFilter { $WhatIf }
    }

    It 'engines receive -WhatIf when the cmdlet is called with -WhatIf (folds into DryRun)' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -ParameterFilter { $WhatIf } { return @{ State='Updated'; Reason='(WhatIf)' } }
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -WhatIf -SkipCompletion
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 1 -Exactly -ParameterFilter { $WhatIf }
    }
}

Describe 'Update-Package dispatcher' -Tag 'Light','Module' {

    BeforeEach {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate { }
    }

    It 'expands the literal "*" into every declarative bundle' {
        $fakeBundles = @(
            [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@([pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }) }
            [pscustomobject]@{ Bundle='Beta';  BundlePath='C:\fake\Beta.ps1';  Packages=@([pscustomobject]@{ Name='b'; Installer='scoop'; Id='main/b' }) }
        )
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages    { return $fakeBundles }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='dummy'; Installer='winget'; Id='X' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath    { return $null }

        Update-Package -Name '*' -SkipCompletion

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate -Times 2 -Exactly
    }

    It 'throws when -Name does not resolve to any package, bundle, or manifest' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { return @() }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath { return $null }
        { Update-Package -Name 'nope-no-such-thing' -SkipCompletion } | Should -Throw '*nope-no-such-thing*'
    }

    It 'cross-dedups: a per-package match in the same bundle as a "*" sweep dispatches the bundle once' {
        $fakeBundles = @(
            [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@([pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }) }
            [pscustomobject]@{ Bundle='Beta';  BundlePath='C:\fake\Beta.ps1';  Packages=@([pscustomobject]@{ Name='b'; Installer='scoop'; Id='main/b' }) }
        )
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages    { return $fakeBundles }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='dummy'; Installer='winget'; Id='X' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath    { return $null }

        # '*' AND 'a' (which lives inside the Alpha bundle): full-bundle
        # sweep should subsume the per-package entry, so total dispatch
        # count is 2 (Alpha + Beta), not 3.
        Update-Package -Name '*','a' -SkipCompletion

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate -Times 2 -Exactly
    }

    It 'bare manifest names emit a Warning instead of silently being skipped' {
        $fakeBundles = @()
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { return $fakeBundles }
        # Pretend the bucket directory exists and contains 'foo.json'
        # but no declarative bundle declares 'foo'.
        $tmpBucket = Join-Path $TestDrive 'bucket'
        New-Item -ItemType Directory -Force -Path $tmpBucket | Out-Null
        Set-Content -Path (Join-Path $tmpBucket 'foo.json') -Value '{}'
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath { return $tmpBucket }

        $warnings = @()
        Update-Package -Name 'foo' -SkipCompletion -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join "`n") | Should -Match 'bare manifest'
    }

    It '-WhatIf on Update-Package folds into -DryRun (engines see WhatIf, no real install)' {
        $fakeBundles = @(
            [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@([pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }) }
        )
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages    { return $fakeBundles }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='a'; Installer='winget'; Id='A.A' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath    { return $null }

        Update-Package -Name 'a' -SkipCompletion -WhatIf

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate -Times 1 -Exactly -ParameterFilter { $DryRun }
    }

    It 'bucket-wide "*" sweep dispatches bundles in deterministic (sorted) order' {
        $fakeBundles = @(
            [pscustomobject]@{ Bundle='Zulu';  BundlePath='C:\fake\Zulu.ps1';  Packages=@([pscustomobject]@{ Name='z'; Installer='winget'; Id='Z.Z' }) }
            [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@([pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }) }
            [pscustomobject]@{ Bundle='Mike';  BundlePath='C:\fake\Mike.ps1';  Packages=@([pscustomobject]@{ Name='m'; Installer='winget'; Id='M.M' }) }
        )
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='x'; Installer='winget'; Id='X.X' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath       { return $null }

        $script:dispatched = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate {
            param($Packages, $Bundle)
            $script:dispatched.Add($Bundle)
        }

        Update-Package -Name '*' -SkipCompletion

        $script:dispatched -join ',' | Should -Be 'Alpha,Mike,Zulu'
    }

    It 'ConvertTo-PackageFromMetadata round-trips WingetExtraArgs' {
        # When Get-BundlePackageObjects can't dot-source the bundle in-
        # process, Update-Package falls back to reconstructing [Package]
        # objects from the JSON-deserialized metadata via
        # ConvertTo-PackageFromMetadata. That helper used to drop the
        # WingetExtraArgs field, so a bundle declaring
        # `WingetExtraArgs=@('--skip-dependencies')` would silently lose
        # the flag on the update / uninstall path. Regression test.
        $helper = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command ConvertTo-PackageFromMetadata }
        $meta = [pscustomobject]@{
            Name='X'; Installer='winget'; Id='Foo.X'; Source=''; Scope='global'
            CliCommands=@(); Completion='none'; DependsOn=@(); Companions=@()
            CISkip=''; Notes=''
            WingetExtraArgs=@('--skip-dependencies','--silent')
        }
        $pkg = & $helper -Metadata $meta
        $pkg.WingetExtraArgs | Should -Be @('--skip-dependencies','--silent')
    }
}

Describe 'Update-All<engine>Packages sweep engines' -Tag 'Light','Module' {

    Context 'Update-AllWingetPackages' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-AllWingetPackages }
        }

        It 'returns Skipped when winget not on PATH (no invocation)' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'winget' }
            Mock -ModuleName MarkMichaelis.ScoopBucket winget { throw 'should not run' }
            $r = & $script:Engine
            $r.State  | Should -Be 'Skipped'
            $r.Engine | Should -Be 'winget'
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket winget -Times 0 -Exactly
        }

        It 'with -WhatIf prints the bulk command and does not invoke winget' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='winget' } } -ParameterFilter { $Name -eq 'winget' }
            Mock -ModuleName MarkMichaelis.ScoopBucket winget { throw 'should not run' }
            $r = & $script:Engine -WhatIf
            $r.State  | Should -Be 'Updated'
            $r.Reason | Should -Match 'WhatIf'
            $r.Engine | Should -Be 'winget'
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket winget -Times 0 -Exactly
        }

        It 'invokes winget upgrade --all with required flags and returns Updated on exit 0' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='winget' } } -ParameterFilter { $Name -eq 'winget' }
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $r = & $script:Engine
            $r.State | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'upgrade'
            ($script:captured -contains '--all')                         | Should -BeTrue
            ($script:captured -contains '--include-unknown')             | Should -BeTrue
            ($script:captured -contains '--silent')                      | Should -BeTrue
            ($script:captured -contains '--accept-package-agreements')   | Should -BeTrue
            ($script:captured -contains '--accept-source-agreements')    | Should -BeTrue
        }

        It 'returns Failed on non-zero exit' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='winget' } } -ParameterFilter { $Name -eq 'winget' }
            Mock -ModuleName MarkMichaelis.ScoopBucket winget { $global:LASTEXITCODE = 7; return 'boom' }
            $r = & $script:Engine
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match '7'
        }
    }

    Context 'Update-AllScoopPackages' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-AllScoopPackages }
        }

        It 'returns Skipped when scoop not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'scoop' }
            $r = & $script:Engine
            $r.State  | Should -Be 'Skipped'
            $r.Engine | Should -Be 'scoop'
        }

        It 'invokes scoop update * (not bare scoop update which only updates scoop+buckets)' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $r = & $script:Engine
            $r.State | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'update'
            $script:captured[1] | Should -Be '*'
        }

        It 'with -WhatIf prints the bulk command and does not invoke scoop' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop { throw 'should not run' }
            $r = & $script:Engine -WhatIf
            $r.State  | Should -Be 'Updated'
            $r.Reason | Should -Match 'WhatIf'
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -Times 0 -Exactly
        }
    }

    Context 'Update-AllChocoPackages' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-AllChocoPackages }
        }

        It 'returns Skipped when choco not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'choco' }
            $r = & $script:Engine
            $r.State  | Should -Be 'Skipped'
            $r.Engine | Should -Be 'choco'
        }

        It 'invokes choco upgrade all -y --no-progress' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='choco' } } -ParameterFilter { $Name -eq 'choco' }
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $r = & $script:Engine
            $r.State | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'upgrade'
            $script:captured[1] | Should -Be 'all'
            ($script:captured -contains '-y')            | Should -BeTrue
            ($script:captured -contains '--no-progress') | Should -BeTrue
        }
    }

    Context 'Update-AllNpmGlobalPackages' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-AllNpmGlobalPackages }
        }

        It 'returns Skipped when npm.cmd not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'npm.cmd' }
            $r = & $script:Engine
            $r.State  | Should -Be 'Skipped'
            $r.Engine | Should -Be 'npmGlobal'
        }

        It 'invokes npm update -g via npm.cmd' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='npm.cmd' } } -ParameterFilter { $Name -eq 'npm.cmd' }
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket npm.cmd {
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return ''
            }
            $r = & $script:Engine
            $r.State | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'update'
            ($script:captured -contains '-g') | Should -BeTrue
        }
    }

    Context 'Update-AllDotnetToolPackages' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-AllDotnetToolPackages }
        }

        It 'returns Skipped when dotnet not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'dotnet' }
            $r = & $script:Engine
            $r.State  | Should -Be 'Skipped'
            $r.Engine | Should -Be 'dotnetTool'
        }

        It 'invokes dotnet tool update -g --all on supported SDKs' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
            $script:allCalls = New-Object System.Collections.Generic.List[object]
            Mock -ModuleName MarkMichaelis.ScoopBucket dotnet {
                $script:allCalls.Add(@($args))
                $global:LASTEXITCODE = 0
                return 'Tools restored.'
            }
            $r = & $script:Engine
            $r.State | Should -Be 'Updated'
            # First call should be `dotnet tool update -g --all`.
            $first = $script:allCalls[0]
            $first[0] | Should -Be 'tool'
            $first[1] | Should -Be 'update'
            ($first -contains '-g')    | Should -BeTrue
            ($first -contains '--all') | Should -BeTrue
        }

        It 'falls back to per-tool enumeration when --all is unrecognized' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return [pscustomobject]@{ Name='dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
            $script:allCalls = New-Object System.Collections.Generic.List[object]
            Mock -ModuleName MarkMichaelis.ScoopBucket dotnet {
                $script:allCalls.Add(@($args))
                $argList = @($args)
                # First call with --all: simulate older SDK that rejects the flag.
                if ($argList -contains '--all') {
                    $global:LASTEXITCODE = 1
                    return "Unrecognized option '--all'"
                }
                # `dotnet tool list -g` fallback enumeration.
                if ($argList[0] -eq 'tool' -and $argList[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return @(
                        'Package Id      Version      Commands',
                        '----------------------------------------',
                        'foo             1.0.0        foo',
                        'bar             2.0.0        bar'
                    )
                }
                # Per-tool updates.
                $global:LASTEXITCODE = 0
                return ''
            }
            $r = & $script:Engine
            $r.State | Should -Be 'Updated'
            # Expect: 1 (--all probe) + 1 (list -g) + 2 (foo + bar per-tool) = 4 calls.
            $script:allCalls.Count | Should -BeGreaterOrEqual 3
            # Confirm fallback per-tool updates happened.
            $perTool = $script:allCalls | Where-Object { $_ -contains 'update' -and $_ -notcontains '--all' -and $_ -notcontains 'list' }
            $perTool.Count | Should -BeGreaterOrEqual 2
        }
    }
}

Describe 'Invoke-AllEnginesUpdate orchestrator' -Tag 'Light','Module' {

    BeforeEach {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllScoopPackages      { return @{ State='Updated'; Reason=$null; Engine='scoop' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllWingetPackages     { return @{ State='Updated'; Reason=$null; Engine='winget' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllChocoPackages      { return @{ State='Skipped'; Reason='not installed'; Engine='choco' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllNpmGlobalPackages  { return @{ State='Updated'; Reason=$null; Engine='npmGlobal' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllDotnetToolPackages { return @{ State='Updated'; Reason=$null; Engine='dotnetTool' } }
    }

    It 'runs all five engines in scoop->winget->choco->npmGlobal->dotnetTool order' {
        $script:order = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllScoopPackages      { $script:order.Add('scoop');      return @{ State='Updated'; Reason=$null; Engine='scoop' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllWingetPackages     { $script:order.Add('winget');     return @{ State='Updated'; Reason=$null; Engine='winget' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllChocoPackages      { $script:order.Add('choco');      return @{ State='Updated'; Reason=$null; Engine='choco' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllNpmGlobalPackages  { $script:order.Add('npmGlobal');  return @{ State='Updated'; Reason=$null; Engine='npmGlobal' } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllDotnetToolPackages { $script:order.Add('dotnetTool'); return @{ State='Updated'; Reason=$null; Engine='dotnetTool' } }

        $orch = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Invoke-AllEnginesUpdate }
        $null = & $orch

        $script:order -join ',' | Should -Be 'scoop,winget,choco,npmGlobal,dotnetTool'
    }

    It 'does NOT short-circuit when one engine fails' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllWingetPackages { return @{ State='Failed'; Reason='boom'; Engine='winget' } }
        $orch = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Invoke-AllEnginesUpdate }
        $null = & $orch
        # All five engines must still run despite winget failure.
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-AllScoopPackages      -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-AllWingetPackages     -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-AllChocoPackages      -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-AllNpmGlobalPackages  -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-AllDotnetToolPackages -Times 1 -Exactly
    }

    It 'propagates -DryRun to each engine as -WhatIf' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-AllScoopPackages -ParameterFilter { $WhatIf } { return @{ State='Updated'; Reason='(WhatIf)'; Engine='scoop' } }
        $orch = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Invoke-AllEnginesUpdate }
        $null = & $orch -DryRun
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-AllScoopPackages -Times 1 -Exactly -ParameterFilter { $WhatIf }
    }

    It 'prints the completer-refresh hint at the end' {
        $orch = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Invoke-AllEnginesUpdate }
        $out = & $orch 6>&1 | Out-String
        $out | Should -Match 'Update-PackageCompletion'
    }
}

Describe 'Update-Package -MachineWide dispatcher (#263)' -Tag 'Light','Module' {

    BeforeEach {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages      { throw 'should not be called under -MachineWide' }
    }

    It '-MachineWide skips bundle resolution entirely (Get-BundlePackages NOT called)' {
        Update-Package -MachineWide -SkipCompletion
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate -Times 1 -Exactly
    }

    It '-MachineWide -DryRun propagates DryRun to Invoke-AllEnginesUpdate' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate -ParameterFilter { $DryRun } { }
        Update-Package -MachineWide -DryRun -SkipCompletion
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate -Times 1 -Exactly -ParameterFilter { $DryRun }
    }

    It '-Name foo -MachineWide errors (mutually exclusive parameter sets)' {
        { Update-Package -Name 'foo' -MachineWide -SkipCompletion } | Should -Throw
    }

    It '-MachineWide -WhatIf folds into -DryRun (orchestrator sees DryRun)' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate -ParameterFilter { $DryRun } { }
        Update-Package -MachineWide -WhatIf -SkipCompletion
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate -Times 1 -Exactly -ParameterFilter { $DryRun }
    }
}

Describe 'Update-Package legacy names are removed (#263)' -Tag 'Light','Module' {

    # Safety net: if production still has the old parameters (e.g. mid-rename),
    # mock the orchestrator so an accidental successful bind cannot trigger a
    # real machine-wide sweep on the developer's box.
    BeforeEach {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate { }
    }

    It '-All throws ParameterBindingException (alias removed)' {
        { Update-Package -All -SkipCompletion -ErrorAction Stop } |
            Should -Throw -ErrorId 'NamedParameterNotFound,Update-Package'
    }

    It '-AllInstalled throws ParameterBindingException (old name removed)' {
        { Update-Package -AllInstalled -SkipCompletion -ErrorAction Stop } |
            Should -Throw -ErrorId 'NamedParameterNotFound,Update-Package'
    }
}

Describe 'Update-Package help documents -MachineWide explicitly (#263)' -Tag 'Light','Module' {

    BeforeAll {
        $script:help = Get-Help Update-Package -Full
    }

    It 'MachineWide parameter help enumerates all five engines verbatim' {
        $param = $script:help.parameters.parameter | Where-Object { $_.name -eq 'MachineWide' }
        $param | Should -Not -BeNullOrEmpty -Because '-MachineWide must be the documented parameter name'
        $text = ($param.description | ForEach-Object { $_.Text }) -join "`n"
        $text | Should -Match 'winget'
        $text | Should -Match 'scoop'
        $text | Should -Match 'choco'      # matches both "choco" and "chocolatey"
        $text | Should -Match 'npm'
        $text | Should -Match 'dotnet'
    }

    It 'DESCRIPTION explicitly warns that machine-wide sweep covers packages NOT installed by this bucket' {
        $desc = ($script:help.description | ForEach-Object { $_.Text }) -join "`n"
        $desc | Should -Match 'not installed by this bucket'
    }
}
