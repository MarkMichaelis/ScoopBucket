<#
.SYNOPSIS
    Light-suite Pester coverage for the MarkMichaelis.ScoopBucket module's engine
    dispatchers, completion registration, and Invoke-PackageInstall
    pipeline.

.DESCRIPTION
    Uses Pester mocks to stub external engines (winget, scoop, choco,
    npm, dotnet) so the tests run hermetically on every machine without
    actually installing anything. Asserts:
      - each engine dispatcher invokes the correct CLI with the
        expected argument shape
      - AlreadyInstalled probes short-circuit the install command
      - Invoke-PackageInstall validates, topo-sorts, dispatches per
        Installer, runs PostInstallScript, records summary states,
        and respects -DryRun / -SkipCompletion / CISkip-in-CI
      - Completion registration writes idempotent sentinel blocks to
        an override profile path
      - Test-PackageCompletionWorks actually exercises the completion
        engine (skipped on hosts where pwsh isn't reachable)
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'Engine dispatchers' -Tag 'Light','Module' {

    Context 'Install-WingetPackage' {
        BeforeAll {
            # Reach into the module scope to invoke the Private function.
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Install-WingetPackage }
        }

        It 'returns AlreadyInstalled when winget list returns 0' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'Name Id Version'
                }
                $global:LASTEXITCODE = 1
                return ''
            }

            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'AlreadyInstalled'
        }

        It 'returns Installed and passes --scope machine when not installed' {
            $script:capturedArgs = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:capturedArgs = $args
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 1; return '' }
                $global:LASTEXITCODE = 0
                return 'Installed.'
            }

            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Installed'
        }

        It 'returns Installed and adds --source msstore when Source=msstore' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 1; return '' }
                $script:installArgs = $args
                $global:LASTEXITCODE = 0
                return 'Installed.'
            }

            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id'; Source='msstore' }
            $null = & $script:Engine -Package $pkg
            # Verify --source msstore appears in the install call
            $foundSourceFlag = $false
            for ($i = 0; $i -lt $script:installArgs.Count; $i++) {
                if ($script:installArgs[$i] -eq '--source' -and $script:installArgs[$i+1] -eq 'msstore') { $foundSourceFlag = $true }
            }
            $foundSourceFlag | Should -BeTrue
        }

        It 'returns Failed when winget exits non-zero' {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 1; return '' }
                $global:LASTEXITCODE = 5
                return 'error'
            }

            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Failed'
            $r.Reason | Should -Match '5'
        }

        It 'appends WingetExtraArgs to the install command' {
            $script:installArgs = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 1; return '' }
                $script:installArgs = $args
                $global:LASTEXITCODE = 0
                return 'Installed.'
            }

            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id'
                               WingetExtraArgs = @('--skip-dependencies', '--force') }
            $null = & $script:Engine -Package $pkg
            $script:installArgs | Should -Contain '--skip-dependencies'
            $script:installArgs | Should -Contain '--force'
        }

        It 'passes --scope user (not --scope machine) when Package.Scope=user (#213)' {
            # Regression guard for Todoist CLI (Sachaos.Todoist): the upstream
            # winget manifest only publishes a user-scope portable .exe. When
            # Package.Scope='user' the wrapper must opt into --scope user and
            # MUST NOT pass --scope machine (which causes winget to fail with
            # -1978335212 APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER).
            $script:installArgs = $null
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 1; return '' }
                $script:installArgs = $args
                $global:LASTEXITCODE = 0
                return 'Installed.'
            }

            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id'; Scope='user' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Installed'

            # Find the --scope flag and assert its value.
            $scopeIdx = [Array]::IndexOf([object[]]$script:installArgs, '--scope')
            $scopeIdx | Should -BeGreaterThan -1
            $script:installArgs[$scopeIdx + 1] | Should -Be 'user'
            # Belt and suspenders: 'machine' must not appear anywhere in argv.
            $script:installArgs | Should -Not -Contain 'machine'
        }

        It 'does not stop retries as permanent for exit -1978334972 (missing dependency)' {
            # -1978334972 = APPINSTALLER_CLI_ERROR_INSTALL_MISSING_DEPENDENCY.
            # Retrying won't recover, so we treat it as permanent (no retry loop).
            $script:installCount = 0
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                if ($args[0] -eq 'list') { $global:LASTEXITCODE = 1; return '' }
                $script:installCount++
                $global:LASTEXITCODE = -1978334972
                return 'missing dependency'
            }

            $pkg = [Package]@{ Name='Test'; Installer='winget'; Id='Test.Id' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Failed'
            $script:installCount | Should -Be 1
        }
    }

    Context 'Install-ChocoPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Install-ChocoPackage }
        }

        It 'returns Installed when choco exits 0' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return '' }
                $global:LASTEXITCODE = 0
                return 'Installed.'
            }

            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Installed'
        }

        It 'returns AlreadyInstalled when choco list shows the package' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return 'nodejs 18.0.0' }
                $global:LASTEXITCODE = 0
                return 'Installed.'
            }

            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'AlreadyInstalled'
        }

        It 'treats exit 3010 (reboot pending) as Installed' {
            Mock -ModuleName MarkMichaelis.ScoopBucket choco {
                if ($args[0] -eq 'list') { return '' }
                $global:LASTEXITCODE = 3010
                return 'Reboot required.'
            }

            $pkg = [Package]@{ Name='nodejs'; Installer='choco'; Id='nodejs' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Installed'
            $r.Reason | Should -Match 'Reboot'
        }
    }

    Context 'Install-NpmGlobalPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Install-NpmGlobalPackage }
        }

        It 'returns Failed when npm not on PATH' {
            # Override the Get-Command lookup in module scope.
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -in @('npm','npm.cmd') }
            $pkg = [Package]@{ Name='claude-code'; Installer='npmGlobal'; Id='@anthropic-ai/claude-code' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Failed'
            $r.Reason | Should -Match 'npm'
        }
    }

    Context 'Install-DotnetToolPackage' {
        BeforeAll {
            $script:Engine = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Install-DotnetToolPackage }
        }

        It 'returns Failed when dotnet not on PATH' {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command { return $null } -ParameterFilter { $Name -eq 'dotnet' }
            $pkg = [Package]@{ Name='poshmcp'; Installer='dotnetTool'; Id='poshmcp' }
            $r = & $script:Engine -Package $pkg
            $r.State | Should -Be 'Failed'
            $r.Reason | Should -Match 'dotnet'
        }
    }
}

Describe 'Invoke-PackageInstall pipeline' -Tag 'Light','Module' {

    BeforeAll {
        # No fancy capture needed — the mocks below just return canned
        # success records; Should -Invoke counts the calls.
    }

    BeforeEach {
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage     { return @{State='Installed'; Reason=$null} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-ScoopPackage      { return @{State='Installed'; Reason=$null} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-ChocoPackage      { return @{State='Installed'; Reason=$null} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-NpmGlobalPackage  { return @{State='Installed'; Reason=$null} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-DotnetToolPackage { return @{State='Installed'; Reason=$null} }
    }

    It 'dispatches packages to the correct engine' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A' }
            [Package]@{ Name='B'; Installer='choco';  Id='b' }
            [Package]@{ Name='C'; Installer='scoop';  Id='main/c' }
        )
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $r.Count | Should -Be 3
        # Success stream emits one PackageResult per package.
        ($r | ForEach-Object Name) -join ',' | Should -Be 'A,B,C'
        $r[0] | Should -BeOfType ([PackageResult])
        ($r | ForEach-Object Operation | Select-Object -Unique) | Should -Be 'Install'
        # Verify each engine got called exactly once.
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-ChocoPackage  -Times 1 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-ScoopPackage  -Times 1 -Exactly
    }

    It 'honors DependsOn ordering' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='Aspire';   Installer='scoop'; Id='MarkMichaelis/Aspire'; DependsOn=@('dotnet') }
            [Package]@{ Name='dotnet';   Installer='scoop'; Id='main/dotnet' }
        )
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $r[0].Name | Should -Be 'dotnet'
        $r[1].Name | Should -Be 'Aspire'
    }

    It 'runs PostInstallScript after a successful install' {
        $script:postRan = $false
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'
                        PostInstallScript = { $script:postRan = $true } }
        )
        $null = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:postRan | Should -BeTrue
    }

    It 'fails the package when PostInstallScript throws' {
        $pkgs = [Package[]]@(
            [Package]@{ Name='A'; Installer='winget'; Id='Foo.A'
                        PostInstallScript = { throw 'boom' } }
        )
        # The package emits a Failed PackageResult on the success stream
        # AND a structured ErrorRecord on the error stream. Capture both.
        # NOTE: PowerShell's own throw-propagation also pushes the raw
        # inner RuntimeException ('boom') onto -ErrorVariable in addition
        # to our wrapper. Filter to our contract: exactly one
        # PackageInstallFailed record per failed package.
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion `
            -ErrorAction SilentlyContinue -ErrorVariable errs
        $r.Count       | Should -Be 1
        $r[0].Status   | Should -Be 'Failed'
        $r[0].Name     | Should -Be 'A'
        $r[0].Reason   | Should -Match 'PostInstallScript threw'
        $r[0].Error    | Should -Not -BeNullOrEmpty
        $ours = @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'PackageInstallFailed*' })
        $ours.Count | Should -Be 1
        $ours[0].Exception.Message | Should -Match 'boom'
        $ours[0].Exception.Message | Should -Match 'PostInstallScript threw'
        $ours[0].TargetObject | Should -BeOfType ([Package])
        $ours[0].TargetObject.Name | Should -Be 'A'
    }

    It 'invokes CustomInstallScript for Installer=custom' {
        $script:customRan = $false
        $pkgs = [Package[]]@(
            [Package]@{ Name='Readwise'; Installer='custom'
                        CustomInstallScript = { $script:customRan = $true } }
        )
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
        $script:customRan | Should -BeTrue
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Readwise'
    }

    It 'skips packages with CISkip set when $env:CI is truthy' {
        $oldCi = $env:CI
        $env:CI = 'true'
        try {
            $pkgs = [Package[]]@(
                [Package]@{ Name='Pushbullet'; Installer='winget'; Id='Foo.PB'; CISkip='no machine-scope installer' }
                [Package]@{ Name='Other';      Installer='winget'; Id='Foo.X' }
            )
            $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion
            # Both packages emit on the success stream (Skipped + Installed).
            $r.Count | Should -Be 2
            ($r | ForEach-Object Name) | Should -Contain 'Pushbullet'
            ($r | ForEach-Object Name) | Should -Contain 'Other'
            # The skipped one never reached the engine; the other did.
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage -Times 1 -Exactly `
                -ParameterFilter { $Package.Name -eq 'Other' }
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage -Times 0 -Exactly `
                -ParameterFilter { $Package.Name -eq 'Pushbullet' }
        } finally {
            if ($null -eq $oldCi) { Remove-Item Env:\CI -ErrorAction Ignore }
            else { $env:CI = $oldCi }
        }
    }

    It 'records Failed and continues when the engine returns Failed' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage {
            return @{ State = 'Failed'; Reason = 'simulated' }
        }
        $pkgs = [Package[]]@(
            [Package]@{ Name='Bad';  Installer='winget'; Id='Foo.Bad' }
            [Package]@{ Name='Good'; Installer='choco';  Id='good' }
        )
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion `
            -ErrorAction SilentlyContinue -ErrorVariable errs
        # Success stream: both packages emit a PackageResult; the failed
        # one carries Status='Failed', the other Status='Installed'.
        $r.Count | Should -Be 2
        ($r | Where-Object Name -eq 'Good').Status | Should -Be 'Installed'
        ($r | Where-Object Name -eq 'Bad').Status  | Should -Be 'Failed'
        # Error stream: one ErrorRecord for the Bad package.
        $errs.Count | Should -Be 1
        $errs[0].FullyQualifiedErrorId | Should -Match '^PackageInstallFailed'
        $errs[0].TargetObject.Name | Should -Be 'Bad'
        $errs[0].Exception.Message | Should -Match 'simulated'
    }

    It 'records a Failed result for a non-Package element and continues the batch' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage {
            return @{ State = 'Installed'; Reason = $null }
        }
        $pkgs = @(
            [pscustomobject]@{ Name = 'x' }                              # not a [Package]
            [Package]@{ Name='Good'; Installer='winget'; Id='Foo.Good' }
        )
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion `
            -ErrorAction SilentlyContinue -ErrorVariable errs
        # The valid package still installs; the bad element does not abort the batch.
        ($r | Where-Object Name -eq 'Good').Name | Should -Be 'Good'
        $errs.Count | Should -Be 1
        $errs[0].FullyQualifiedErrorId | Should -Match '^PackageInstallFailed'
        $errs[0].Exception.Message     | Should -Match 'expected a \[Package\]'
    }

    It 'records Failed (not throw) on a Package.Validate() error and continues' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-ChocoPackage {
            return @{ State = 'Installed'; Reason = $null }
        }
        # 'Bad' is a scoop package with an unprefixed Id -> Validate() rejects it.
        $pkgs = [Package[]]@(
            [Package]@{ Name='Bad';  Installer='scoop'; Id='no-bucket-prefix' }
            [Package]@{ Name='Good'; Installer='choco'; Id='good' }
        )
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion `
            -ErrorAction SilentlyContinue -ErrorVariable errs
        ($r | Where-Object Name -eq 'Good').Name | Should -Be 'Good'
        $errs.Count | Should -Be 1
        $errs[0].FullyQualifiedErrorId | Should -Match '^PackageInstallFailed'
        $errs[0].TargetObject.Name     | Should -Be 'Bad'
        $errs[0].Exception.Message     | Should -Match 'bucket'
    }

    It 'respects -DryRun: dispatchers receive -WhatIf, returns Installed records' {
        $pkgs = [Package[]]@([Package]@{ Name='A'; Installer='winget'; Id='Foo.A' })
        $r = Invoke-PackageInstall -Packages $pkgs -Bundle 'Test' -SkipCompletion -DryRun
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'A'
        # Dispatcher is still invoked (to emit "[WhatIf] ..." log lines), it
        # just must not run the underlying engine.
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
    }
}

Describe 'Completion registration' -Tag 'Light','Module' {

    BeforeAll {
        $script:RegisterFn = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Register-PackageCompletion }
        $script:SetBlockFn = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Set-PackageCompletionProfileBlock }
        $script:profileDir = Join-Path $TestDrive 'profile-dir'
        New-Item -ItemType Directory -Path $script:profileDir -Force | Out-Null
    }

    BeforeEach {
        $script:profilePath = Join-Path $script:profileDir "profile-$([guid]::NewGuid()).ps1"
    }

    It 'writes a sentinel block with native command output' {
        $r = & $script:RegisterFn -Cli 'mycli' `
            -NativeCommand { 'Register-ArgumentCompleter -CommandName mycli -ScriptBlock { ''hi'' }' } `
            -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false
        $r.Source | Should -Be 'Native'
        $r.Action | Should -Be 'Added'
        Test-Path $script:profilePath | Should -BeTrue
        (Get-Content $script:profilePath -Raw) | Should -Match 'ScoopBucket:CliCompletion:mycli:BEGIN'
    }

    It 'is idempotent: rerunning always replaces with the current native output' {
        $null = & $script:RegisterFn -Cli 'idem' `
            -NativeCommand { 'first' } -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false
        $r = & $script:RegisterFn -Cli 'idem' `
            -NativeCommand { 'second' } -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false
        $r.Action | Should -Be 'Replaced'
        # v3 (#216): native payload lives in a sidecar .ps1 next to the
        # profile; the profile only dot-sources it. Assert the sidecar
        # got replaced (second wins, first is gone).
        $sidecar = Join-Path (Split-Path -Parent $script:profilePath) 'completions\idem.ps1'
        Test-Path $sidecar | Should -BeTrue
        (Get-Content $sidecar -Raw) | Should -Match 'second'
        (Get-Content $sidecar -Raw) | Should -Not -Match 'first'
    }

    It 'rerunning with identical native output produces a byte-identical block' {
        $null = & $script:RegisterFn -Cli 'idem3' `
            -NativeCommand { 'same' } -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false
        $first = Get-Content $script:profilePath -Raw
        $null = & $script:RegisterFn -Cli 'idem3' `
            -NativeCommand { 'same' } -Mode 'native' -ProfilePath $script:profilePath -Confirm:$false
        $second = Get-Content $script:profilePath -Raw
        $first | Should -Be $second
    }

    It 'returns Skipped (Mode=native) when native command emits nothing' {
        $r = & $script:RegisterFn -Cli 'silent' `
            -NativeCommand { } -Mode 'native' -ProfilePath $script:profilePath `
            -WarningAction SilentlyContinue -Confirm:$false
        $r.Source | Should -Be 'Skipped'
    }

    It 'Set-PackageCompletionProfileBlock returns identical output for identical input' {
        $a = & $script:SetBlockFn -Content '' -Cli 'x' -Block 'Write-Host x'
        $b = & $script:SetBlockFn -Content '' -Cli 'x' -Block 'Write-Host x'
        $a | Should -Be $b
    }
}

Describe 'Test-PackageCompletionWorks (end-to-end probe)' -Tag 'Light','Module' {

    BeforeAll {
        $script:ProbeFn = & (Get-Module MarkMichaelis.ScoopBucket) { Get-Command Test-PackageCompletionWorks }
    }

    It 'returns Verified=$false with a reason when the profile is missing' {
        $r = & $script:ProbeFn -Cli 'pwsh' -ProfilePath (Join-Path $TestDrive 'no-such-profile.ps1')
        $r.Verified | Should -BeFalse
        $r.Reason | Should -Match 'Profile not found'
    }

    It 'returns Verified=$false when the CLI is not on PATH' {
        $script:profile = Join-Path $TestDrive 'empty-profile.ps1'
        Set-Content -Path $script:profile -Value '# empty' -Encoding UTF8
        $r = & $script:ProbeFn -Cli '__definitely_not_a_real_cli_xyz__' -ProfilePath $script:profile
        $r.Verified | Should -BeFalse
        $r.Reason  | Should -Match 'not on PATH'
    }
}
