#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Issue #212 -- Profile-block completion registration is deferred to
    PowerShell.OnIdle, native completer text is cached from
    NativeCommandOutputs, and Import-PackageCompletion stays synchronous.
#>

Describe 'Register-PackageCompletion: deferred OnIdle wrap + cached native text' -Tag 'Light','DeferredCompletion' {

    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("DCR-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:profilePath = Join-Path $script:sandbox 'Profile.ps1'

        function script:New-NativeFixture {
            param([string]$Cli)
            [scriptblock]::Create("Write-Output 'Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock { }'")
        }
    }

    AfterAll {
        if (Test-Path $script:sandbox) { Remove-Item -Recurse -Force $script:sandbox -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        if (Test-Path $script:profilePath) { Remove-Item -Force $script:profilePath }
    }

    It 'wraps the emitted block in Register-EngineEvent PowerShell.OnIdle (MaxTriggerCount 1)' {
        $profilePath = $script:profilePath
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath } {
            param($ProfilePath)
            $nc = [scriptblock]::Create("Write-Output 'Register-ArgumentCompleter -Native -CommandName demo1 -ScriptBlock { }'")
            Register-PackageCompletion -Cli demo1 -NativeCommand $nc -Mode native -ProfilePath $ProfilePath -Confirm:$false | Out-Null
        }
        $raw = Get-Content -Raw -Path $script:profilePath
        $raw | Should -Match 'ScoopBucket:CliCompletion:demo1:BEGIN v2'
        $raw | Should -Match 'Register-EngineEvent -SourceIdentifier PowerShell\.OnIdle -MaxTriggerCount 1'
    }

    It '-PreCapturedNative overrides NativeCommand (the scriptblock is not invoked)' {
        $profilePath = $script:profilePath
        $result = InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath } {
            param($ProfilePath)
            $script:invocations = 0
            $bad = [scriptblock]::Create("`$script:invocations++; throw 'NativeCommand should not run'")
            $cachedText = "Register-ArgumentCompleter -Native -CommandName demo2 -ScriptBlock { }"
            Register-PackageCompletion -Cli demo2 -NativeCommand $bad -PreCapturedNative $cachedText `
                -Mode native -ProfilePath $ProfilePath -Confirm:$false | Out-Null
            [pscustomobject]@{ Invocations = $script:invocations }
        }
        $result.Invocations | Should -Be 0
        $raw = Get-Content -Raw -Path $script:profilePath
        $raw | Should -Match 'Register-ArgumentCompleter -Native -CommandName demo2'
        $raw | Should -Match 'Register-EngineEvent -SourceIdentifier PowerShell\.OnIdle'
    }

    It 'rewrites an existing v1 block as v2 on re-register (transparent migration)' {
        $v1 = @"
# ScoopBucket:CliCompletion:demo3:BEGIN v1
if (Get-Command demo3 -ErrorAction SilentlyContinue) {
Register-ArgumentCompleter -Native -CommandName demo3 -ScriptBlock { }
}
# ScoopBucket:CliCompletion:demo3:END

"@
        [System.IO.File]::WriteAllText($script:profilePath, $v1, [System.Text.UTF8Encoding]::new($false))
        $profilePath = $script:profilePath
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath } {
            param($ProfilePath)
            $nc = [scriptblock]::Create("Write-Output 'Register-ArgumentCompleter -Native -CommandName demo3 -ScriptBlock { }'")
            Register-PackageCompletion -Cli demo3 -NativeCommand $nc -Mode native -ProfilePath $ProfilePath -Confirm:$false | Out-Null
        }
        $raw = Get-Content -Raw -Path $script:profilePath
        ([regex]::Matches($raw, 'ScoopBucket:CliCompletion:demo3:BEGIN').Count) | Should -Be 1
        $raw | Should -Match 'ScoopBucket:CliCompletion:demo3:BEGIN v2'
        $raw | Should -Match 'Register-EngineEvent -SourceIdentifier PowerShell\.OnIdle'
        $raw | Should -Not -Match 'ScoopBucket:CliCompletion:demo3:BEGIN v1'
    }

    It 'profile-load critical path contains no top-level subprocess call (subprocess body sits inside the deferred Action)' {
        $profilePath = $script:profilePath
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath } {
            param($ProfilePath)
            $subprocessy = [scriptblock]::Create('Write-Output "& warp.exe completions powershell | Invoke-Expression"')
            Register-PackageCompletion -Cli demo4 -NativeCommand $subprocessy -Mode native -ProfilePath $ProfilePath -Confirm:$false | Out-Null
        }
        $raw = Get-Content -Raw -Path $script:profilePath
        $m = [regex]::Match($raw, '(?ms)^\# ScoopBucket:CliCompletion:demo4:BEGIN v2\r?\n(.+?)^\# ScoopBucket:CliCompletion:demo4:END')
        $m.Success | Should -BeTrue
        $body = $m.Groups[1].Value

        $idx = $body.IndexOf('-Action {')
        $idx | Should -BeGreaterThan -1
        $criticalPath = $body.Substring(0, $idx)
        $criticalPath | Should -Not -Match '(?m)^\s*&\s'
        $criticalPath | Should -Not -Match 'Invoke-Expression'
    }
}

Describe 'Import-PackageCompletion: synchronous, no OnIdle deferral' -Tag 'Light','DeferredCompletion' {

    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    }

    It 'does not register a PowerShell.OnIdle subscriber when activating completers in-runspace' {
        # Drain any pre-existing subscribers we did not create.
        $pre = @(Get-EventSubscriber -SourceIdentifier 'PowerShell.OnIdle' -ErrorAction SilentlyContinue).Count

        $fakePkg = [pscustomobject]@{
            Name = 'demoImport'
            CliCommands = @('demoImport')
            Completion = 'native'
            NativeCommandOutputs = @{ demoImport = 'Register-ArgumentCompleter -Native -CommandName demoImport -ScriptBlock { }' }
            NativeCommandScript = $null
        }
        Import-PackageCompletion -Package @($fakePkg) | Out-Null

        $post = @(Get-EventSubscriber -SourceIdentifier 'PowerShell.OnIdle' -ErrorAction SilentlyContinue).Count
        $post | Should -Be $pre -Because 'Import-PackageCompletion activates completers in the current runspace immediately; it must not defer via OnIdle.'
    }
}

Describe 'Update-PackageCompletion: -Force rewrites stale v1 blocks as v2 + OnIdle' -Tag 'Light','DeferredCompletion' {

    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

        $script:sandbox2 = Join-Path ([System.IO.Path]::GetTempPath()) ("UPC212-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox2 -Force | Out-Null
        $script:profilePath2 = Join-Path $script:sandbox2 'Profile.ps1'

        # Pick a CLI that *is* on PATH so Update-PackageCompletion does not skip it.
        $script:realCli = $null
        foreach ($candidate in 'pwsh','git','code') {
            if (Get-Command $candidate -ErrorAction SilentlyContinue) { $script:realCli = $candidate; break }
        }
    }

    AfterAll {
        if (Test-Path $script:sandbox2) { Remove-Item -Recurse -Force $script:sandbox2 -ErrorAction SilentlyContinue }
    }

    It '-Force replaces a v1 block with a v2 OnIdle-wrapped block' {
        if (-not $script:realCli) {
            Set-ItResult -Skipped -Because 'No reference CLI on PATH for the test to anchor on.'
            return
        }
        $cli = $script:realCli
        $v1 = @"
# ScoopBucket:CliCompletion:$cli`:BEGIN v1
if (Get-Command $cli -ErrorAction SilentlyContinue) {
Register-ArgumentCompleter -Native -CommandName $cli -ScriptBlock { }
}
# ScoopBucket:CliCompletion:$cli`:END

"@
        [System.IO.File]::WriteAllText($script:profilePath2, $v1, [System.Text.UTF8Encoding]::new($false))

        # Synthesize the minimal package shape Update-PackageCompletion expects.
        $fakeBundle = [pscustomobject]@{
            Bundle = 'Test'
            Packages = @(
                [pscustomobject]@{
                    Name = "TestPkg"; CliCommands = @($cli); Completion = 'native'
                    HasNativeCommandScript = $true
                    NativeCommandOutputs = @{ $cli = "Register-ArgumentCompleter -Native -CommandName $cli -ScriptBlock { } # refreshed" }
                    NativeCommandScript = $null
                }
            )
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { @($fakeBundle) }

        Update-PackageCompletion -Force -ProfilePath $script:profilePath2 -Confirm:$false | Out-Null
        $raw = Get-Content -Raw -Path $script:profilePath2
        $raw | Should -Match "ScoopBucket:CliCompletion:$cli`:BEGIN v2"
        $raw | Should -Match 'Register-EngineEvent -SourceIdentifier PowerShell\.OnIdle'
        $raw | Should -Match 'refreshed'
    }
}
