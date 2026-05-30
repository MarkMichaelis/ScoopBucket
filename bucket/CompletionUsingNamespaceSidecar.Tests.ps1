#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Issue #216 -- Native completer payloads that begin with
    `using namespace System.Management.Automation` (clap/Rust completers
    like `rg --generate complete-powershell`) must be persisted to a
    sidecar .ps1 file so the leading `using` statement is legal. The
    profile block dot-sources the sidecar from inside its OnIdle
    Action body; the inline `using` regression that broke v2 must not
    return.
#>

Describe 'Register-PackageCompletion: payloads with `using namespace` go to sidecar .ps1' -Tag 'Light','SidecarCompletion' {

    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("Sidecar-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:profilePath    = Join-Path $script:sandbox 'Profile.ps1'
        $script:sidecarDir     = Join-Path $script:sandbox 'completions'
    }

    AfterAll {
        if (Test-Path $script:sandbox) { Remove-Item -Recurse -Force $script:sandbox -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        if (Test-Path $script:profilePath) { Remove-Item -Force $script:profilePath }
        if (Test-Path $script:sidecarDir)  { Remove-Item -Recurse -Force $script:sidecarDir }
    }

    It 'persists a payload that begins with `using namespace` to a sidecar .ps1 (no inline `using` in profile)' {
        $profilePath = $script:profilePath
        $sidecarDir  = $script:sidecarDir
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath; SidecarDir = $sidecarDir } {
            param($ProfilePath, $SidecarDir)
            # Synthesize the shape rg emits: leading `using namespace` then
            # Register-ArgumentCompleter referencing [CompletionResult] without FQN.
            $payload = @'
using namespace System.Management.Automation
Register-ArgumentCompleter -Native -CommandName demoUns -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    @([CompletionResult]::new('help', 'help', [CompletionResultType]::ParameterValue, 'help'))
}
'@
            $nc = [scriptblock]::Create("Write-Output @'`r`n$payload`r`n'@")
            Register-PackageCompletion -Cli demoUns -NativeCommand $nc -Mode native `
                -ProfilePath $ProfilePath -SidecarDirectory $SidecarDir -Confirm:$false | Out-Null
        }

        $raw = Get-Content -Raw -Path $script:profilePath
        # (a) profile must NOT contain a `using namespace` line anywhere.
        $raw | Should -Not -Match '(?m)^\s*using\s+namespace\b' -Because 'inline `using namespace` inside an if/Action block is a fatal parse error'
        # (b) v3 sentinel + OnIdle wrapper still present.
        $raw | Should -Match 'ScoopBucket:CliCompletion:demoUns:BEGIN v3'
        $raw | Should -Match 'Register-EngineEvent -SourceIdentifier PowerShell\.OnIdle'
        # (c) the OnIdle body is just a dot-source of the sidecar.
        $expectedSidecar = Join-Path $script:sidecarDir 'demoUns.ps1'
        $escSidecar = [regex]::Escape($expectedSidecar)
        $raw | Should -Match "(?m)\.\s+'$escSidecar'" -Because 'the OnIdle Action must dot-source the sidecar instead of inlining the payload'

        # (d) sidecar must exist and start with `using namespace`.
        Test-Path $expectedSidecar | Should -BeTrue -Because 'Register-PackageCompletion must write a sidecar .ps1 for every Native registration'
        $sideRaw = Get-Content -Raw -Path $expectedSidecar
        $firstNonEmpty = ($sideRaw -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1
        $firstNonEmpty | Should -Match '^\s*using\s+namespace\s+System\.Management\.Automation\s*$' -Because 'the sidecar preserves the payload verbatim, with `using` as the first statement'
        $sideRaw | Should -Match 'Register-ArgumentCompleter -Native -CommandName demoUns'
    }

    It 'profile written for a `using namespace` payload parses cleanly in a fresh pwsh' {
        $profilePath = $script:profilePath
        $sidecarDir  = $script:sidecarDir
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath; SidecarDir = $sidecarDir } {
            param($ProfilePath, $SidecarDir)
            $payload = @'
using namespace System.Management.Automation
Register-ArgumentCompleter -Native -CommandName demoUns2 -ScriptBlock {
    param($w,$c,$p)
    @([CompletionResult]::new('x','x',[CompletionResultType]::ParameterValue,'x'))
}
'@
            $nc = [scriptblock]::Create("Write-Output @'`r`n$payload`r`n'@")
            Register-PackageCompletion -Cli demoUns2 -NativeCommand $nc -Mode native `
                -ProfilePath $ProfilePath -SidecarDirectory $SidecarDir -Confirm:$false | Out-Null
        }

        # Probe: spawn pwsh -NoProfile, dot-source the freshly written profile,
        # report success or the parse error to stdout. v2 emit dies here with
        # "A 'using' statement must appear before any other statements".
        $probePath = Join-Path $script:sandbox 'probe.ps1'
        $probe = @"
`$ErrorActionPreference = 'Stop'
try {
    . '$($script:profilePath -replace "'","''")'
    Write-Output 'OK'
} catch {
    Write-Output "FAIL: `$(`$_.Exception.Message)"
}
"@
        Set-Content -Path $probePath -Value $probe -Encoding UTF8
        $pwsh = (Get-Process -Id $PID).Path
        if (-not $pwsh) { $pwsh = 'pwsh' }
        $out = & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath 2>&1 | Out-String
        $out | Should -Match '(?m)^OK\s*$' -Because "profile must parse without ParserError; got: $out"
        $out | Should -Not -Match "using' statement must appear"
    }

    It 'escapes apostrophes in the sidecar path so install dirs like ``C:\Users\O''Brien`` parse cleanly' {
        # Regression: Copilot review on PR #218 caught that the
        # generated `. '$sidecarPath'` was unsafe -- a sidecar dir whose
        # path contained a literal apostrophe would break the single-
        # quoted PowerShell string and abort profile parsing. Use a
        # sandbox dir whose name embeds an apostrophe to prove the fix.
        $apostropheDir = Join-Path $script:sandbox "O'Brien-completions"
        New-Item -ItemType Directory -Path $apostropheDir -Force | Out-Null
        $apostropheProfile = Join-Path $script:sandbox "ProfileApos.ps1"
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $apostropheProfile; SidecarDir = $apostropheDir } {
            param($ProfilePath, $SidecarDir)
            $nc = [scriptblock]::Create("Write-Output 'Register-ArgumentCompleter -Native -CommandName demoApos -ScriptBlock { ''hi'' }'")
            Register-PackageCompletion -Cli demoApos -NativeCommand $nc -Mode native `
                -ProfilePath $ProfilePath -SidecarDirectory $SidecarDir -Confirm:$false | Out-Null
        }

        $raw = Get-Content -Raw -Path $apostropheProfile
        # The path contains `'` which must be doubled in the single-
        # quoted PowerShell string literal that dot-sources the sidecar.
        $raw | Should -Match "O''Brien-completions" -Because 'embedded apostrophes in single-quoted dot-source paths must be doubled'

        # Tokenize the profile -- there must be no parse errors, and
        # the dot-source string must round-trip back to the original
        # path (with one apostrophe).
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($apostropheProfile, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty -Because "profile with apostrophe in sidecar path must parse cleanly; got: $($errs -join '; ')"
    }
}

Describe 'Remove-PackageCompletionBlock: deletes the sidecar .ps1 alongside the profile block' -Tag 'Light','SidecarCompletion' {

    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

        $script:sandbox2    = Join-Path ([System.IO.Path]::GetTempPath()) ("SidecarRm-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox2 -Force | Out-Null
        $script:profilePath2 = Join-Path $script:sandbox2 'Profile.ps1'
        $script:sidecarDir2  = Join-Path $script:sandbox2 'completions'
    }

    AfterAll {
        if (Test-Path $script:sandbox2) { Remove-Item -Recurse -Force $script:sandbox2 -ErrorAction SilentlyContinue }
    }

    It 'deletes <cli>.ps1 when Remove-PackageCompletionBlock strips the block' {
        $profilePath = $script:profilePath2
        $sidecarDir  = $script:sidecarDir2
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath; SidecarDir = $sidecarDir } {
            param($ProfilePath, $SidecarDir)
            $nc = [scriptblock]::Create("Write-Output 'Register-ArgumentCompleter -Native -CommandName demoRm -ScriptBlock { }'")
            Register-PackageCompletion -Cli demoRm -NativeCommand $nc -Mode native `
                -ProfilePath $ProfilePath -SidecarDirectory $SidecarDir -Confirm:$false | Out-Null
        }
        $sidecar = Join-Path $script:sidecarDir2 'demoRm.ps1'
        Test-Path $sidecar | Should -BeTrue -Because 'sanity check: Register-PackageCompletion wrote the sidecar'

        $result = InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ ProfilePath = $profilePath; SidecarDir = $sidecarDir } {
            param($ProfilePath, $SidecarDir)
            Remove-PackageCompletionBlock -Cli demoRm -ProfilePath $ProfilePath -SidecarDirectory $SidecarDir -Confirm:$false
        }
        $result.Action | Should -Be 'Removed'
        Test-Path $sidecar | Should -BeFalse -Because 'Remove-PackageCompletionBlock must delete the matching sidecar .ps1 (#216)'
    }
}

