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
        # Stand up a fake `PSCompletions` module that exports a stub
        # `psc` function. Production code now verifies that the command
        # it invokes actually comes from a module named PSCompletions
        # (not just any `psc` on PATH), so we cannot inject the stub
        # via plain `function script:psc` in the bucket module scope.
        $script:fakePscModule = New-Module -Name PSCompletions -ScriptBlock {
            $script:PscUpdateCalls = 0
            $script:PscConfigCalls = 0
            $script:PscLastUpdateArg = $null
            $script:PscLastConfigArgs = $null
            $script:PscThrows = $false
            $script:PscThrowsOnUpdate = $false
            function psc {
                param()
                if ($args.Count -ge 1 -and $args[0] -eq 'update') {
                    $script:PscUpdateCalls++
                    if ($args.Count -ge 2) { $script:PscLastUpdateArg = [string]$args[1] }
                    if ($script:PscThrows -or $script:PscThrowsOnUpdate) { throw 'simulated psc throw on update' }
                } elseif ($args.Count -ge 1 -and $args[0] -eq 'config') {
                    $script:PscConfigCalls++
                    $script:PscLastConfigArgs = @($args | ForEach-Object { [string]$_ })
                    if ($script:PscThrows) { throw 'simulated psc throw on config' }
                }
            }
            Export-ModuleMember -Function psc -Variable PscUpdateCalls,PscConfigCalls,PscLastUpdateArg,PscLastConfigArgs,PscThrows,PscThrowsOnUpdate
        } | Import-Module -PassThru
    }

    AfterEach {
        if ($script:fakePscModule) {
            Remove-Module -ModuleInfo $script:fakePscModule -Force -ErrorAction Ignore
            $script:fakePscModule = $null
        }
    }

    It 'invokes `psc config enable_completions_update 0` after a successful `psc update *`' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Invoke-PscCatalogUpdate -WarningAction SilentlyContinue
        }

        $script:fakePscModule.SessionState.PSVariable.GetValue('PscUpdateCalls') | Should -Be 1
        $script:fakePscModule.SessionState.PSVariable.GetValue('PscLastUpdateArg') | Should -Be '*'
        $script:fakePscModule.SessionState.PSVariable.GetValue('PscConfigCalls') | Should -BeGreaterOrEqual 1
        $cfg = @($script:fakePscModule.SessionState.PSVariable.GetValue('PscLastConfigArgs'))
        $cfg | Should -Not -BeNullOrEmpty
        $cfg[1] | Should -Be 'enable_completions_update'
        $cfg[2] | Should -Be '0'
    }

    It 'does not throw under -WarningAction Stop (best-effort contract)' {
        $script:fakePscModule.SessionState.PSVariable.Set('PscThrows', $true)

        $threw = $false
        try {
            InModuleScope MarkMichaelis.ScoopBucket {
                Invoke-PscCatalogUpdate -WarningAction Stop
            }
        } catch {
            $threw = $true
        }
        $threw | Should -BeFalse
    }

    It 'emits Write-Warning and returns when `psc update *` throws (does not propagate)' {
        $script:fakePscModule.SessionState.PSVariable.Set('PscThrowsOnUpdate', $true)

        $warnings = $null
        $threw = $false
        try {
            InModuleScope MarkMichaelis.ScoopBucket {
                Invoke-PscCatalogUpdate -WarningVariable warnings -WarningAction SilentlyContinue
                $script:CapturedWarnings = $warnings
            }
            $warnings = InModuleScope MarkMichaelis.ScoopBucket { $script:CapturedWarnings }
        } catch {
            $threw = $true
        }
        $threw | Should -BeFalse
        $warnings = @($warnings)
        $warnings.Count | Should -BeGreaterOrEqual 1
        ($warnings | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'psc update'
    }

    It 'edits the JSON config file directly when `psc config` itself throws (fallback path)' {
        $script:fakePscModule.SessionState.PSVariable.Set('PscThrows', $true)

        # Stage a config.json under our fake module's ModuleBase. Since
        # `New-Module` does not give the module an on-disk ModuleBase,
        # we have to stub `Get-Module PSCompletions` inside the helper
        # to return a hand-crafted object whose ModuleBase points at a
        # real directory.
        $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("PscFake-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $stage | Out-Null
        $configPath = Join-Path $stage 'config.json'
        '{ "enable_completions_update": "1", "other": "keep" }' | Set-Content -Path $configPath -Encoding UTF8

        try {
            InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Stage = $stage } {
                param($Stage)
                $script:FakePscBase = [pscustomobject]@{ ModuleBase = $Stage; Name = 'PSCompletions' }
                # Override only the *single-argument* `Get-Module PSCompletions`
                # call inside the fallback. Other call sites (e.g. resolving the
                # imported test module) still hit the real Get-Module via splat.
                function script:Get-Module {
                    [CmdletBinding()] param(
                        [Parameter(ValueFromPipeline=$true,Position=0)][string[]]$Name,
                        [switch]$ListAvailable,
                        [Parameter(ValueFromRemainingArguments=$true)][object[]]$Rest
                    )
                    if ($Name -contains 'PSCompletions' -and -not $ListAvailable) {
                        return $script:FakePscBase
                    }
                    Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
                }
                try {
                    Invoke-PscCatalogUpdate -WarningAction SilentlyContinue
                } finally {
                    Remove-Item function:script:Get-Module -ErrorAction Ignore
                    $script:FakePscBase = $null
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

