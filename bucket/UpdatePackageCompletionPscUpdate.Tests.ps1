#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Issue #223: Update-PackageCompletion should auto-run `psc update *` once
# at the START of an invocation when the resolved package set has any
# pscompletions-mode entries, and squelch PSCompletions nag banner via
# `psc config enable_completions_update 0`. When no pscompletions-mode
# entries exist, skip entirely (no Import-Module PSCompletions, no
# banner).

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    Import-Module $script:psd1 -Force

    $script:onPathCli  = 'pwsh'
    $script:offPathCli = 'def-not-real-' + [guid]::NewGuid().ToString('N').Substring(0,8)

    function New-TestBucket {
        param([string]$BundleBody)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-pscupdate-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $dir | Out-Null
        $header = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

"@
        Set-Content -Path (Join-Path $dir 'TestBundle.ps1') -Value ($header + $BundleBody) -Encoding UTF8
        $dir
    }

    # Bucket with two pscompletions-mode entries.
    $script:bucketWithPsc = New-TestBucket -BundleBody @"
`$Packages = [Package[]]@(
    [Package]@{ Name='PscOne'; Installer='winget'; Id='Test.PscOne'; CliCommands=@('$($script:onPathCli)');        Completion='pscompletions' }
    [Package]@{ Name='PscTwo'; Installer='winget'; Id='Test.PscTwo'; CliCommands=@('$($script:onPathCli)-twin');  Completion='pscompletions' }
)
Invoke-PackageInstall -Packages `$Packages -Bundle 'PscBundle'
"@

    # Bucket with NO pscompletions-mode entries (only native + none).
    $script:bucketNoPsc = New-TestBucket -BundleBody @"
`$Packages = [Package[]]@(
    [Package]@{ Name='NativeOnly'; Installer='winget'; Id='Test.NativeOnly'; CliCommands=@('$($script:onPathCli)-nativeonly'); Completion='native'; NativeCommandScript={ 'native-completion-source' } }
    [Package]@{ Name='NoneOnly';   Installer='winget'; Id='Test.NoneOnly';   CliCommands=@('$($script:onPathCli)-none');       Completion='none' }
)
Invoke-PackageInstall -Packages `$Packages -Bundle 'NoPscBundle'
"@

    # Shim PATH so the synthetic CLIs resolve via Get-Command.
    $script:shimDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pscupdate-shims-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:shimDir | Out-Null
    foreach ($shim in @("$($script:onPathCli)-twin.ps1", "$($script:onPathCli)-nativeonly.ps1", "$($script:onPathCli)-none.ps1")) {
        Set-Content -Path (Join-Path $script:shimDir $shim) -Value '# stub' -Encoding UTF8
    }
    $script:savedPath = $env:PATH
    $env:PATH = "$script:shimDir;$env:PATH"
}

AfterAll {
    if ($script:savedPath) { $env:PATH = $script:savedPath }
    foreach ($d in @($script:bucketWithPsc, $script:bucketNoPsc, $script:shimDir)) {
        if ($d -and (Test-Path $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Ignore }
    }
}

Describe 'Update-PackageCompletion auto psc update (issue #223)' -Tag 'Light' {

    It 'invokes Invoke-PscCatalogUpdate exactly once when bucket has pscompletions-mode entries' {
        $profilePath = Join-Path ([System.IO.Path]::GetTempPath()) ("pscupd-profile-$([guid]::NewGuid().ToString('N')).ps1")
        try {
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PscCatalogUpdate { } -Verifiable
            # Mock Register-PackageCompletion so the test does not write
            # the real profile and stays focused on the catalog gate.
            Mock -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion { [pscustomobject]@{ Source='PSCompletions'; Reason='mock' } }

            Update-PackageCompletion -BucketPath $script:bucketWithPsc -ProfilePath $profilePath -Confirm:$false | Out-Null

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket -CommandName Invoke-PscCatalogUpdate -Times 1 -Exactly
        } finally {
            if (Test-Path $profilePath) { Remove-Item -LiteralPath $profilePath -Force -ErrorAction Ignore }
        }
    }

    It 'does NOT invoke Invoke-PscCatalogUpdate under -WhatIf (catalog has observable side effects)' {
        $profilePath = Join-Path ([System.IO.Path]::GetTempPath()) ("pscupd-profile-$([guid]::NewGuid().ToString('N')).ps1")
        try {
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PscCatalogUpdate { }

            Update-PackageCompletion -BucketPath $script:bucketWithPsc -ProfilePath $profilePath -WhatIf | Out-Null

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket -CommandName Invoke-PscCatalogUpdate -Times 0 -Exactly
        } finally {
            if (Test-Path $profilePath) { Remove-Item -LiteralPath $profilePath -Force -ErrorAction Ignore }
        }
    }

    It 'does NOT invoke Invoke-PscCatalogUpdate when bucket has no pscompletions-mode entries' {
        $profilePath = Join-Path ([System.IO.Path]::GetTempPath()) ("pscupd-profile-$([guid]::NewGuid().ToString('N')).ps1")
        try {
            Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PscCatalogUpdate { }
            # Mock registration so the test exercises the no-pscompletions
            # predicate itself, not the -WhatIf gate.
            Mock -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion { [pscustomobject]@{ Source='Native'; Reason='mock' } }

            Update-PackageCompletion -BucketPath $script:bucketNoPsc -ProfilePath $profilePath -Confirm:$false | Out-Null

            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket -CommandName Invoke-PscCatalogUpdate -Times 0 -Exactly
        } finally {
            if (Test-Path $profilePath) { Remove-Item -LiteralPath $profilePath -Force -ErrorAction Ignore }
        }
    }
}

Describe 'Invoke-PscCatalogUpdate helper (issue #223)' -Tag 'Light' {

    BeforeEach {
        # Inject a stub `psc` function in the module scope so production
        # code's `Get-Command psc` and `& psc ...` find it. Records
        # invocation summaries (joined arg strings) in module-scope flags.
        InModuleScope MarkMichaelis.ScoopBucket {
            $script:PscUpdateCalls = 0
            $script:PscConfigCalls = 0
            $script:PscLastUpdateArg = $null
            $script:PscLastConfigArgs = $null
            function script:psc {
                param()
                if ($args.Count -ge 1 -and $args[0] -eq 'update') {
                    $script:PscUpdateCalls++
                    if ($args.Count -ge 2) { $script:PscLastUpdateArg = [string]$args[1] }
                } elseif ($args.Count -ge 1 -and $args[0] -eq 'config') {
                    $script:PscConfigCalls++
                    $script:PscLastConfigArgs = @($args | ForEach-Object { [string]$_ })
                }
            }
        }
    }

    AfterEach {
        InModuleScope MarkMichaelis.ScoopBucket {
            Remove-Item function:script:psc -ErrorAction Ignore
            $script:PscUpdateCalls = $null
            $script:PscConfigCalls = $null
            $script:PscLastUpdateArg = $null
            $script:PscLastConfigArgs = $null
        }
    }

    It 'invokes `psc config enable_completions_update 0` after a successful `psc update *`' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Invoke-PscCatalogUpdate

            $script:PscUpdateCalls | Should -Be 1
            $script:PscLastUpdateArg | Should -Be '*'
            $script:PscConfigCalls | Should -BeGreaterOrEqual 1
            $script:PscLastConfigArgs | Should -Not -BeNullOrEmpty
            $script:PscLastConfigArgs[1] | Should -Be 'enable_completions_update'
            $script:PscLastConfigArgs[2] | Should -Be '0'
        }
    }

    It 'does not throw under -WarningAction Stop (best-effort contract)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            # Force every code path that emits a Write-Warning:
            #   1. psc update throws -> warning
            #   2. psc config throws -> warning + fallback
            function script:psc {
                param()
                throw 'simulated psc failure'
            }

            $threw = $false
            try {
                Invoke-PscCatalogUpdate -WarningAction Stop
            } catch {
                $threw = $true
            }
            $threw | Should -BeFalse
        }
    }

    It 'emits Write-Warning and returns when `psc update *` throws (does not propagate)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            # Override stub: throw on `update`, succeed on `config`.
            function script:psc {
                param()
                if ($args.Count -ge 1 -and $args[0] -eq 'update') {
                    $script:PscUpdateCalls++
                    throw 'simulated __need_update_data exception'
                }
            }

            $warnings = $null
            $threw = $false
            try {
                Invoke-PscCatalogUpdate -WarningVariable warnings -WarningAction SilentlyContinue
            } catch {
                $threw = $true
            }
            $threw | Should -BeFalse
            $warnings = @($warnings)
            $warnings.Count | Should -BeGreaterOrEqual 1
            ($warnings | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'psc update'
        }
    }

    It 'edits the JSON config file directly when `psc config` itself throws (fallback path)' {
        # Stage a fake PSCompletions module on disk so the fallback can
        # find a `config.json` under (Get-Module).ModuleBase.
        $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("PscFake-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $stage | Out-Null
        $configPath = Join-Path $stage 'config.json'
        '{ "enable_completions_update": "1", "other": "keep" }' | Set-Content -Path $configPath -Encoding UTF8

        try {
            InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Stage = $stage } {
                param($Stage)

                # psc command always throws so both update + config hit
                # the catch path; the catch then runs the direct edit.
                function script:psc { param() throw 'simulated psc throw' }

                # Replace Get-Module so the helper resolves to our stage
                # dir without polluting the real module loader.
                $script:FakePscModule = [pscustomobject]@{ ModuleBase = $Stage; Name = 'PSCompletions' }
                function script:Get-Module {
                    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)][object[]]$Rest)
                    return $script:FakePscModule
                }

                try {
                    Invoke-PscCatalogUpdate -WarningAction SilentlyContinue
                } finally {
                    Remove-Item function:script:Get-Module -ErrorAction Ignore
                    $script:FakePscModule = $null
                }
            }

            $after = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [string]$after.enable_completions_update | Should -Be '0'
            [string]$after.other                     | Should -Be 'keep'
        } finally {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Ignore
        }
    }
}
