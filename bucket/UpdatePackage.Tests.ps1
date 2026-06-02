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
            $r = & $script:Engine -Package $pkg -TimeoutMinutes 0
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
            $null = & $script:Engine -Package $pkg -TimeoutMinutes 0
            ($script:captured -contains '--skip-dependencies') | Should -BeTrue
        }

        It 'returns Failed on unrecognized non-zero exit' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $global:LASTEXITCODE = 7
                return 'oops'
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg -TimeoutMinutes 0
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match '7'
        }

        It 'returns Failed with "timed out" when Invoke-WithTimeout reports timeout (#269)' {
            # Update-WingetPackage normally calls winget directly via `&`,
            # but with a non-zero timeout it must route through
            # Invoke-WithTimeout so a hang on one app does not block
            # the rest of the bucket-scoped sweep.
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                throw 'should not be called when timeout is in effect; route through Invoke-WithTimeout'
            }
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-WithTimeout {
                return @{ ExitCode = -1; TimedOut = $true; DurationSeconds = 900 }
            }
            $pkg = [Package]@{ Name='Warp'; Installer='winget'; Id='Warp.Warp' }
            $r = & $script:Engine -Package $pkg -TimeoutMinutes 15
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match 'timed out'
            $r.Reason | Should -Match '15'
        }

        It 'threads the upgrade args through Invoke-WithTimeout when timeout is enabled (#269)' {
            $script:passed = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-WithTimeout {
                $script:passed = @{ FilePath = $FilePath; Args = $Arguments; TimeoutSeconds = $TimeoutSeconds }
                return @{ ExitCode = 0; TimedOut = $false }
            }
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $global:LASTEXITCODE = 0; return ''
            }
            $pkg = [Package]@{ Name='Warp'; Installer='winget'; Id='Warp.Warp'; Scope='user' }
            $r = & $script:Engine -Package $pkg -TimeoutMinutes 7
            $r.State                       | Should -Be 'Updated'
            $script:passed.FilePath        | Should -Be 'winget'
            $script:passed.TimeoutSeconds  | Should -Be (7 * 60)
            $script:passed.Args[0]         | Should -Be 'upgrade'
            ($script:passed.Args -contains 'Warp.Warp') | Should -BeTrue
        }

        It '[Package].UpdateTimeoutMinutes overrides the caller default per-package (#271)' {
            $script:passed = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-WithTimeout {
                $script:passed = @{ TimeoutSeconds = $TimeoutSeconds }
                return @{ ExitCode = 0; TimedOut = $false }
            }
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $global:LASTEXITCODE = 0; return ''
            }
            $pkg = [Package]@{ Name='VS'; Installer='winget'; Id='Microsoft.VisualStudio'; UpdateTimeoutMinutes=30 }
            # Caller default is 5; the per-package override bumps it to
            # 30 -- the helper sees 30*60 = 1800s.
            $r = & $script:Engine -Package $pkg -TimeoutMinutes 5
            $r.State                      | Should -Be 'Updated'
            $script:passed.TimeoutSeconds | Should -Be (30 * 60)
        }

        It 'with -TimeoutMinutes 0 calls winget directly (timeout disabled, #269)' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-WithTimeout {
                throw 'should not be called when timeout is disabled'
            }
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
                $script:captured = $args
                $global:LASTEXITCODE = 0; return ''
            }
            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg -TimeoutMinutes 0
            $r.State            | Should -Be 'Updated'
            $script:captured[0] | Should -Be 'upgrade'
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-WithTimeout -Times 0 -Exactly
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

    Context 'Update-ScoopBucket' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Update-ScoopBucket }
        }

        It 'invokes "scoop update" with no app arguments and returns Refreshed' {
            $script:captured = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                $script:captured = $args
                $global:LASTEXITCODE = 0
                return 'Updating Scoop...'
            }
            $r = & $script:Engine
            $r.State            | Should -Be 'Refreshed'
            $script:captured.Count | Should -Be 1
            $script:captured[0] | Should -Be 'update'
        }

        It 'returns Skipped when scoop CLI is not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'scoop' }
            $r = & $script:Engine
            $r.State  | Should -Be 'Skipped'
            $r.Reason | Should -Match 'scoop'
        }

        It 'returns Failed when scoop update exits non-zero' {
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                $global:LASTEXITCODE = 1
                return 'oops'
            }
            $r = & $script:Engine
            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match '1'
        }

        It 'honors -WhatIf without invoking scoop' {
            Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
                throw 'should not be called under -WhatIf'
            }
            $r = & $script:Engine -WhatIf
            $r.State | Should -Be 'Refreshed'
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -Times 0 -Exactly
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
        # The version probe runs a bulk CLI query per installer. Stub it out
        # by default so real-run pipeline tests stay fast and deterministic;
        # individual tests that exercise -WhatIf accuracy override it (#283).
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex { @{} }
    }

    It 'threads -PackageTimeoutMinutes to Update-WingetPackage (#269)' {
        $script:capturedTimeout = $null
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            $script:capturedTimeout = $TimeoutMinutes
            return @{ State='Updated'; Reason=$null }
        }
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion -PackageTimeoutMinutes 9
        $script:capturedTimeout | Should -Be 9
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

    It 'runs ConfigScript after an Updated package' {
        $script:configRan = $false
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'
                        ConfigScript = { $script:configRan = $true } }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:configRan | Should -BeTrue
    }

    It 'runs ConfigScript even when the engine reports AlreadyLatest' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            return @{ State='AlreadyLatest'; Reason='same' }
        }
        $script:configRan = $false
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'
                        ConfigScript = { $script:configRan = $true } }
        )
        $r = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion
        ($r | Where-Object Name -eq 'A').Status | Should -Be 'AlreadyLatest'
        $script:configRan | Should -BeTrue
    }

    It 'does NOT run ConfigScript when the package is NotInstalled' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            return @{ State='NotInstalled'; Reason='probe said no' }
        }
        $script:configRan = $false
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'
                        ConfigScript = { $script:configRan = $true } }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:configRan | Should -BeFalse
    }

    It 'fails the package when ConfigScript throws during update' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'
                        ConfigScript = { throw 'cfgboom' } }
        )
        $r = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion `
            -ErrorAction SilentlyContinue -ErrorVariable errs
        ($r | Where-Object Name -eq 'A').Status | Should -Be 'Failed'
        ($r | Where-Object Name -eq 'A').Reason | Should -Match 'ConfigScript threw'
        $ours = @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'PackageUpdateFailed*' })
        $ours.Count | Should -Be 1
    }

    It 'does not run ConfigScript under -WhatIf' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage { throw 'engine must not run under -WhatIf' }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex {
            @{ 'Foo.A' = [pscustomobject]@{ Installed='1.0'; Available='1.0' } }
        }
        $script:configRan = $false
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'
                        ConfigScript = { $script:configRan = $true } }
        )
        $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion -WhatIf
        $script:configRan | Should -BeFalse
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

    It 'under -WhatIf, probes the index instead of invoking the engine and reports the version transition (#283)' {
        # New contract: a dry run no longer calls the engine -- it consults the
        # pre-built version index. An available upgrade reports Updated with a
        # from -> to transition.
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage { throw 'engine must not run under -WhatIf' }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex {
            @{ winget = @{ 'foo.a' = @{ Installed = '1.0'; Available = '2.0' } } }
        }
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $r = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -WhatIf -SkipCompletion)
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 0 -Exactly
        $r[0].Status      | Should -Be 'Updated'
        $r[0].VersionFrom | Should -Be '1.0'
        $r[0].VersionTo   | Should -Be '2.0'
    }

    It 'under -WhatIf, an already-current package reports AlreadyLatest not Updated (#283)' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage { throw 'engine must not run under -WhatIf' }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex {
            @{ winget = @{ 'foo.a' = @{ Installed = '2.0'; Available = '' } } }
        }
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $r = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -WhatIf -SkipCompletion)
        $r[0].Status | Should -Be 'AlreadyLatest'
    }
}

Describe 'Invoke-PackageUpdate emits PackageResult objects (#274, #276)' -Tag 'Light','Module' {

    It 'emits one PackageResult per package carrying Status/Installer/Scope/Id/Name' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-WingetPackage    { return @{ State='Updated'; Reason=$null } }
            Mock Update-PathFromRegistry { }
            Mock Register-PackageCompletion { }

            $pkgs = [Package[]]@(
                [Package]@{ Name='Claude Desktop'; Installer='winget'; Id='Anthropic.Claude'; Scope='user' }
            )
            $result = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion)

            $result.Count               | Should -Be 1
            $result[0].GetType().Name   | Should -Be 'PackageResult'
            $result[0].Operation        | Should -Be 'Update'
            $result[0].Status           | Should -Be 'Updated'
            $result[0].Installer        | Should -Be 'winget'
            $result[0].Scope            | Should -Be 'user'
            $result[0].Id               | Should -Be 'Anthropic.Claude'
            $result[0].Name             | Should -Be 'Claude Desktop'
            $result[0].Bundle           | Should -Be 'Test'
            # Status is a plain string, programmatically filterable.
            ($result | Where-Object Status -eq 'Updated').Count | Should -Be 1
        }
    }

    It 'emits a Failed PackageResult carrying Reason and a populated Error, plus an error-stream record' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-WingetPackage    { return @{ State='Failed'; Reason='winget upgrade timed out' } }
            Mock Update-PathFromRegistry { }

            $pkgs = [Package[]]@(
                [Package]@{ Name='Warp'; Installer='winget'; Id='Warp.Warp'; Scope='user' }
            )
            $result = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion `
                -ErrorAction SilentlyContinue -ErrorVariable ev)

            $failed = $result | Where-Object Status -eq 'Failed'
            $failed                       | Should -Not -BeNullOrEmpty
            $failed.Name                  | Should -Be 'Warp'
            $failed.Reason                | Should -Match 'winget upgrade timed out'
            # The structured error is available on the object for inspection.
            $failed.Error                 | Should -Not -BeNullOrEmpty
            $failed.Error.GetType().Name  | Should -Be 'ErrorRecord'
            # AND the error stream still carries a PackageUpdateFailed record.
            ($ev | Where-Object { $_.FullyQualifiedErrorId -like 'PackageUpdateFailed*' }) |
                Should -Not -BeNullOrEmpty
        }
    }
    It 'fails one invalid package but continues updating the rest of the batch (#276)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-ChocoPackage     { return @{ State='Updated'; Reason=$null } }
            Mock Update-WingetPackage    { return @{ State='Updated'; Reason=$null } }
            Mock Update-PathFromRegistry { }

            # Middle package is malformed: Installer='custom' but its
            # CustomInstallScript was stripped (the metadata round-trip case
            # that previously aborted the whole sweep with a terminating throw).
            $bad = [Package]::new()
            $bad.Name = 'Readwise Reader'; $bad.Installer = 'custom'; $bad.UpdateMode = 'Reinstall'
            $pkgs = @(
                [Package]@{ Name='nodejs'; Installer='choco';  Id='nodejs' }
                $bad
                [Package]@{ Name='Warp';   Installer='winget'; Id='Warp.Warp'; Scope='user' }
            )

            $result = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'ClientBasePackages' -SkipCompletion `
                -ErrorAction SilentlyContinue -ErrorVariable ev)

            # All three packages produce a row -- the bad one did not abort the sweep.
            $result.Count | Should -Be 3
            ($result | Where-Object Name -eq 'nodejs').Status | Should -Be 'Updated'
            ($result | Where-Object Name -eq 'Warp').Status   | Should -Be 'Updated'

            $failed = $result | Where-Object Name -eq 'Readwise Reader'
            $failed.Status | Should -Be 'Failed'
            $failed.Reason | Should -Match 'Invalid package declaration'
            $failed.Reason | Should -Match 'CustomInstallScript is required'
            $failed.Error  | Should -Not -BeNullOrEmpty

            ($ev | Where-Object { $_.FullyQualifiedErrorId -like 'PackageUpdateFailed*' }).Count |
                Should -Be 1
        }
    }

    It 'reports "Reinstall unavailable" when a metadata-only Reinstall package reaches the engine (#276)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            # When validation is bypassed (e.g. a stale [Package] instance whose
            # GetValidationError method predates the current module), a Reinstall
            # package that lost its CustomInstallScript on the metadata round-trip
            # reaches the UpdateMode switch with no script. It must NOT throw and
            # must surface the reworded, visible reason -- not silently vanish.
            Mock Get-PackageValidationError { return $null }
            Mock Update-PathFromRegistry { }

            $pkg = [Package]::new()
            $pkg.Name = 'Readwise Reader'; $pkg.Installer = 'custom'; $pkg.UpdateMode = 'Reinstall'

            $result = @(Invoke-PackageUpdate -Packages @($pkg) -Bundle 'ClientBasePackages' -SkipCompletion)

            $result.Count | Should -Be 1
            $result[0].Status | Should -Be 'NoAutoUpdateSupport'
            $result[0].Reason | Should -Match 'Reinstall unavailable'
        }
    }
}

Describe 'Quiet-by-default update output (#276)' -Tag 'Light','Module' {

    It 'emits PackageResult objects and no Write-Host chatter by default' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-WingetPackage    { return @{ State='Updated'; Reason=$null } }
            Mock Update-PathFromRegistry { }
            Mock Register-PackageCompletion { }
            Mock Get-PackageUpdateIndex { @{} }
            $captured = New-Object System.Collections.Generic.List[object]
            Mock Write-Host -MockWith {
                $captured.Add([pscustomobject]@{ Message = [string]$Object })
            }

            $pkgs = [Package[]]@(
                [Package]@{ Name='Claude Desktop'; Installer='winget'; Id='Anthropic.Claude'; Scope='user' }
            )
            $result = @(Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion)

            # The result object is the sole output channel.
            $result.Count    | Should -Be 1
            $result[0].Status | Should -Be 'Updated'

            # No Write-Host chatter reaches the host at all -- not a summary
            # table, not the section header, not the per-package progress line.
            $lines = @($captured | ForEach-Object { [string]$_.Message })
            ($lines | Where-Object { $_ -match 'Invoke-PackageUpdate:' }) | Should -BeNullOrEmpty
            ($lines | Where-Object { $_ -match 'update summary' })        | Should -BeNullOrEmpty
            ($lines | Where-Object { $_ -match 'Updating Claude Desktop' }) | Should -BeNullOrEmpty
        }
    }

    It 'reports the current package as a transient Write-Progress status' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-WingetPackage    { return @{ State='Updated'; Reason=$null } }
            Mock Update-PathFromRegistry { }
            Mock Register-PackageCompletion { }
            Mock Get-PackageUpdateIndex { @{} }
            Mock Write-Host { }
            $statuses = New-Object System.Collections.Generic.List[object]
            Mock Write-Progress -MockWith {
                if ($Status) { $statuses.Add([string]$Status) }
            }

            $pkgs = [Package[]]@(
                [Package]@{ Name='Claude Desktop'; Installer='winget'; Id='Anthropic.Claude'; Scope='user' }
            )
            $null = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion

            ($statuses | Where-Object { $_ -match 'Updating Claude Desktop' -and $_ -match 'winget' }) |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'reveals the chatter on the verbose stream when -Verbose is passed' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-WingetPackage    { return @{ State='Updated'; Reason=$null } }
            Mock Update-PathFromRegistry { }
            Mock Register-PackageCompletion { }
            Mock Get-PackageUpdateIndex { @{} }
            Mock Write-Host { }
            Mock Write-Progress { }

            $pkgs = [Package[]]@(
                [Package]@{ Name='Claude Desktop'; Installer='winget'; Id='Anthropic.Claude'; Scope='user' }
            )
            $verbose = Invoke-PackageUpdate -Packages $pkgs -Bundle 'Test' -SkipCompletion -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                ForEach-Object { [string]$_.Message }

            ($verbose | Where-Object { $_ -match 'Updating Claude Desktop' }) |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-CapturedOutputTail (#276)' -Tag 'Light','Module' {

    It 'returns empty string for empty or whitespace input' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Get-CapturedOutputTail ''          | Should -BeExactly ''
            Get-CapturedOutputTail "  `n  `n " | Should -BeExactly ''
        }
    }

    It 'folds a tail of captured output into a single line for the failure Reason' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $captured = "line1`nline2`nline3`nERROR: boom"
            $tail = Get-CapturedOutputTail $captured

            $tail | Should -Match 'Last output:'
            $tail | Should -Match 'ERROR: boom'
            # Folded to a single line (no embedded newlines).
            $tail | Should -Not -Match "`n"
        }
    }
}

Describe 'Update engines hide installer output by default (#276)' -Tag 'Light','Module' {

    It 'Update-ScoopPackage routes scoop output to verbose, not the host' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Get-Command { $true } -ParameterFilter { $Name -eq 'scoop' }
            function scoop {
                if ($args -contains 'list') { 'ripgrep 14.0.0'; $global:LASTEXITCODE = 0; return }
                'ripgrep: 14.0.0 (latest version)'; $global:LASTEXITCODE = 0
            }
            Mock Write-Host { }
            Mock Write-Progress { }

            $pkg = [Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep'; Scope='global' }
            $r = Update-ScoopPackage -Package $pkg

            $r.State | Should -Be 'AlreadyLatest'
            # The raw scoop output must not have been echoed to the host.
            Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -match 'latest version' }
        }
    }

    It 'Update-ScoopPackage folds failing scoop output into the Reason' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Get-Command { $true } -ParameterFilter { $Name -eq 'scoop' }
            function scoop {
                if ($args -contains 'list') { 'ripgrep 14.0.0'; $global:LASTEXITCODE = 0; return }
                'Could not download manifest'; $global:LASTEXITCODE = 1
            }
            Mock Write-Host { }
            Mock Write-Progress { }

            $pkg = [Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep'; Scope='global' }
            $r = Update-ScoopPackage -Package $pkg

            $r.State  | Should -Be 'Failed'
            $r.Reason | Should -Match 'Could not download manifest'
        }
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

    It '-WhatIf on Update-Package propagates to engines (no real install)' {
        $fakeBundles = @(
            [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@([pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }) }
        )
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages    { return $fakeBundles }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='a'; Installer='winget'; Id='A.A' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath    { return $null }

        Update-Package -Name 'a' -SkipCompletion -WhatIf

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate -Times 1 -Exactly -ParameterFilter { $WhatIf }
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

    Context 'auto bucket refresh (#267)' {
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate { }
            Mock -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket { return @{ State = 'Refreshed'; Reason = $null } }
            Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath { return $null }
        }

        It 'refreshes scoop buckets exactly once when the dispatch plan contains a scoop package' {
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='S';  BundlePath='C:\fake\S.ps1'; Packages=@(
                    [pscustomobject]@{ Name='s1'; Installer='scoop'; Id='main/s1' },
                    [pscustomobject]@{ Name='s2'; Installer='scoop'; Id='main/s2' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects {
                return @(
                    [Package]@{ Name='s1'; Installer='scoop'; Id='main/s1' },
                    [Package]@{ Name='s2'; Installer='scoop'; Id='main/s2' }
                )
            }

            Update-Package -Name 'S' -SkipCompletion

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket -Times 1 -Exactly
        }

        It 'does NOT refresh when the dispatch plan has no scoop packages' {
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='W'; BundlePath='C:\fake\W.ps1'; Packages=@(
                    [pscustomobject]@{ Name='w'; Installer='winget'; Id='W.W' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects {
                return @([Package]@{ Name='w'; Installer='winget'; Id='W.W' })
            }

            Update-Package -Name 'w' -SkipCompletion

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket -Times 0 -Exactly
        }

        It 'does NOT refresh under -WhatIf' {
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='S'; BundlePath='C:\fake\S.ps1'; Packages=@(
                    [pscustomobject]@{ Name='s1'; Installer='scoop'; Id='main/s1' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects {
                return @([Package]@{ Name='s1'; Installer='scoop'; Id='main/s1' })
            }

            Update-Package -Name 's1' -SkipCompletion -WhatIf

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket -Times 0 -Exactly
        }

        It 'does NOT refresh when -SkipBucketRefresh is set' {
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='S'; BundlePath='C:\fake\S.ps1'; Packages=@(
                    [pscustomobject]@{ Name='s1'; Installer='scoop'; Id='main/s1' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects {
                return @([Package]@{ Name='s1'; Installer='scoop'; Id='main/s1' })
            }

            Update-Package -Name 's1' -SkipCompletion -SkipBucketRefresh

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket -Times 0 -Exactly
        }

        It 'continues dispatch and warns when bucket refresh fails' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket {
                return @{ State = 'Failed'; Reason = 'scoop update exited with 1.' }
            }
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='S'; BundlePath='C:\fake\S.ps1'; Packages=@(
                    [pscustomobject]@{ Name='s1'; Installer='scoop'; Id='main/s1' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects {
                return @([Package]@{ Name='s1'; Installer='scoop'; Id='main/s1' })
            }

            $warnings = @()
            Update-Package -Name 's1' -SkipCompletion -WarningVariable warnings -WarningAction SilentlyContinue

            ($warnings -join "`n") | Should -Match 'bucket refresh'
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate -Times 1 -Exactly
        }

        It 'refreshes exactly once across multiple bundles with scoop packages' {
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='A'; BundlePath='C:\fake\A.ps1'; Packages=@(
                    [pscustomobject]@{ Name='a'; Installer='scoop'; Id='main/a' }
                )}
                [pscustomobject]@{ Bundle='B'; BundlePath='C:\fake\B.ps1'; Packages=@(
                    [pscustomobject]@{ Name='b'; Installer='scoop'; Id='main/b' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects {
                param($BundlePath)
                if ($BundlePath -like '*A.ps1') { return @([Package]@{ Name='a'; Installer='scoop'; Id='main/a' }) }
                else                            { return @([Package]@{ Name='b'; Installer='scoop'; Id='main/b' }) }
            }

            Update-Package -Name '*' -SkipCompletion

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket -Times 1 -Exactly
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate -Times 2 -Exactly
        }
    }

    Context 'per-package winget timeout (#269)' {
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket Update-ScoopBucket { return @{ State='Skipped'; Reason='test' } }
        }

        It 'threads -PackageTimeoutMinutes through to Invoke-PackageUpdate' {
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@(
                    [pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='a'; Installer='winget'; Id='A.A' }) }
            Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath       { return $null }
            $script:capturedTimeout = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate {
                $script:capturedTimeout = $PackageTimeoutMinutes
            }

            Update-Package -Name 'a' -SkipCompletion -PackageTimeoutMinutes 7

            $script:capturedTimeout | Should -Be 7
        }

        It 'default -PackageTimeoutMinutes is 5' {
            $fakeBundles = @(
                [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@(
                    [pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }
                )}
            )
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='a'; Installer='winget'; Id='A.A' }) }
            Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath       { return $null }
            $script:capturedTimeout = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate {
                $script:capturedTimeout = $PackageTimeoutMinutes
            }

            Update-Package -Name 'a' -SkipCompletion

            $script:capturedTimeout | Should -Be 5
        }
    }
}

Describe 'Update-Package pipeline emission (#276)' -Tag 'Light','Module' {

    BeforeEach {
        $fakeBundles = @(
            [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@(
                [pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }
            )}
        )
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages       { return $fakeBundles }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects { return @([Package]@{ Name='a'; Installer='winget'; Id='A.A'; Scope='user' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath       { return $null }
        # Stand in for the real engine sweep: emit a PackageResult on
        # the success stream exactly like Invoke-PackageUpdate does.
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageUpdate {
            [PackageResult]@{ Operation='Update'; Status='Updated'; Name='a'; Installer='winget'; Id='A.A'; Scope='user'; Bundle='Alpha' }
        }
    }

    It 'emits the PackageResult objects on the pipeline' {
        $out = @(Update-Package -Name 'a' -SkipCompletion -WhatIf)
        $out.Count                | Should -Be 1
        $out[0].GetType().Name    | Should -Be 'PackageResult'
        $out[0].Status            | Should -Be 'Updated'
        $out[0].Id                | Should -Be 'A.A'
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

    It '-MachineWide -WhatIf propagates DryRun to Invoke-AllEnginesUpdate' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate -ParameterFilter { $DryRun } { }
        Update-Package -MachineWide -WhatIf -SkipCompletion
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-AllEnginesUpdate -Times 1 -Exactly -ParameterFilter { $DryRun }
    }

    It '-Name foo -MachineWide errors (mutually exclusive parameter sets)' {
        { Update-Package -Name 'foo' -MachineWide -SkipCompletion } | Should -Throw
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


Describe 'Update-Package sweep continues past failed packages (#272)' -Tag 'Light','Module' {

    It 'continues dispatching remaining bundles when an earlier package fails, even with $ErrorActionPreference=Stop' {
        # Use REAL Invoke-PackageUpdate so that -ErrorAction Continue bound by
        # the dispatch call is honored exactly as it is in production. Mocking
        # Invoke-PackageUpdate directly does not faithfully reproduce
        # common-parameter binding through Pester's mock wrapper.
        $fakeBundles = @(
            [pscustomobject]@{ Bundle='Alpha'; BundlePath='C:\fake\Alpha.ps1'; Packages=@([pscustomobject]@{ Name='a'; Installer='winget'; Id='A.A' }) }
            [pscustomobject]@{ Bundle='Beta';  BundlePath='C:\fake\Beta.ps1';  Packages=@([pscustomobject]@{ Name='b'; Installer='winget'; Id='B.B' }) }
            [pscustomobject]@{ Bundle='Gamma'; BundlePath='C:\fake\Gamma.ps1'; Packages=@([pscustomobject]@{ Name='c'; Installer='winget'; Id='C.C' }) }
        )
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { return $fakeBundles }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects -ParameterFilter { $BundlePath -eq 'C:\fake\Alpha.ps1' } { return @([Package]@{ Name='a'; Installer='winget'; Id='A.A' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects -ParameterFilter { $BundlePath -eq 'C:\fake\Beta.ps1'  } { return @([Package]@{ Name='b'; Installer='winget'; Id='B.B' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackageObjects -ParameterFilter { $BundlePath -eq 'C:\fake\Gamma.ps1' } { return @([Package]@{ Name='c'; Installer='winget'; Id='C.C' }) }
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-BucketPath { return $null }
        # Simulate the Warp-style failure: first bundle's package fails (e.g., timeout).
        # The other two should still execute despite caller's ErrorActionPreference=Stop.
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -ParameterFilter { $Package.Id -eq 'A.A' } {
            return @{ State='Failed'; Reason='winget upgrade --id A.A timed out (simulated for #272)' }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -ParameterFilter { $Package.Id -ne 'A.A' } {
            return @{ State='Updated'; Reason='ok' }
        }

        $prior = $ErrorActionPreference
        try {
            # Reproduce user's setup: ErrorActionPreference=Stop in the session
            # (common in modern PowerShell profiles). The dispatcher must still
            # complete its sweep even though Invoke-PackageUpdate would emit
            # a non-terminating error for the failed package.
            $ErrorActionPreference = 'Stop'
            Update-Package -Name '*' -SkipCompletion 2>$null
        } finally {
            $ErrorActionPreference = $prior
        }

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 1 -Exactly -ParameterFilter { $Package.Id -eq 'A.A' }
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 1 -Exactly -ParameterFilter { $Package.Id -eq 'B.B' }
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 1 -Exactly -ParameterFilter { $Package.Id -eq 'C.C' }
    }
}
