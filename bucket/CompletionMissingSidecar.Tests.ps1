#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# A completion block whose sidecar is missing or broken must say so (#532).
#
# The blocks live in $PROFILE.CurrentUserAllHosts, which commonly roams through
# OneDrive, while the payload each block dot-sources lives in per-machine
# %ProgramData%\ScoopBucket\completions. A block written on one machine
# therefore arrives on another where the CLI is installed but the sidecar was
# never generated. The block only guarded on Get-Command, so it dot-sourced a
# missing file, and the shared OnIdle drain swallowed the error: Tab silently
# fell back to file names.
#
# These tests load a generated profile in a child pwsh, run the OnIdle
# subscriber's Action exactly as the engine would, and check what reaches the
# warning stream.
# ----------------------------------------------------------------------------

BeforeAll {
    $script:psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
    $script:pwsh = (Get-Process -Id $PID).Path

    # Load $ProfilePath in a fresh pwsh, then run every PowerShell.OnIdle
    # subscriber's Action (OnIdle never fires in a non-interactive child).
    # Returns the warnings raised during profile load and the drain, plus the
    # completion matches for "$Probe" when one is given. Each name in
    # -Commands is defined as a function first so the blocks' Get-Command
    # guard sees an installed CLI.
    function script:Invoke-ProfileInChild {
        param(
            [Parameter(Mandatory)][string]$ProfilePath,
            [string[]]$Commands = @(),
            [string[]]$ExtraQueued = @(),
            [string]$Probe
        )
        $defs = ($Commands | ForEach-Object { "function global:$_ { }" }) -join "`n"
        $extra = ($ExtraQueued | ForEach-Object { "`$Global:__ScoopBucketCompletionQueue.Add({ $_ }) | Out-Null" }) -join "`n"
        $escaped = $ProfilePath -replace "'", "''"
        $probeLine = if ($Probe) {
            "`$cc = TabExpansion2 -inputScript '$Probe' -cursorColumn $($Probe.Length); foreach (`$m in `$cc.CompletionMatches) { 'MATCH:' + `$m.CompletionText }"
        } else { '' }
        $script = @"
`$ErrorActionPreference = 'Continue'
$defs
& { . '$escaped' } 3>&1 | ForEach-Object { if (`$_ -is [System.Management.Automation.WarningRecord]) { 'WARN:' + `$_.Message } }
$extra
foreach (`$sub in @(Get-EventSubscriber -SourceIdentifier PowerShell.OnIdle -ErrorAction SilentlyContinue)) {
    & ([scriptblock]::Create(`$sub.Action.Command)) 3>&1 | ForEach-Object {
        if (`$_ -is [System.Management.Automation.WarningRecord]) { 'WARN:' + `$_.Message }
    }
}
$probeLine
"@
        $file = Join-Path $TestDrive ("child-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -Path $file -Value $script -Encoding UTF8
        $out = @(& $script:pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{
            Warnings = @($out | Where-Object { $_ -like 'WARN:*' } | ForEach-Object { $_.Substring(5) })
            Matches  = @($out | Where-Object { $_ -like 'MATCH:*' } | ForEach-Object { $_.Substring(6) })
            Raw      = $out
        }
    }

    # Register a deferred block for $Cli into a sandbox profile and return the
    # profile and sidecar paths.
    function script:New-RegisteredProfile {
        param([Parameter(Mandatory)][string]$Cli, [string]$Payload)
        if (-not $Payload) {
            $Payload = "Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock { 'alpha'; 'beta' }"
        }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $profilePath = Join-Path $dir 'profile.ps1'
        $sidecarDir = Join-Path $dir 'completions'
        & $script:mod {
            param($p, $s, $c, $text)
            Register-PackageCompletion -Cli $c -Mode native -ProfilePath $p -SidecarDirectory $s `
                -PreCapturedNative $text -Confirm:$false
        } $profilePath $sidecarDir $Cli $Payload | Out-Null
        [pscustomobject]@{ Profile = $profilePath; Sidecar = (Join-Path $sidecarDir "$Cli.ps1") }
    }
}

Describe 'Deferred completion block reports a broken sidecar' -Tag 'Light','Completion' {

    It 'loads a healthy sidecar silently and the completer works' {
        $reg = script:New-RegisteredProfile -Cli 'demohealthy'
        $r = script:Invoke-ProfileInChild -ProfilePath $reg.Profile -Commands 'demohealthy' -Probe 'demohealthy '
        $r.Warnings | Should -BeNullOrEmpty
        $r.Matches | Should -Contain 'alpha'
    }

    It 'warns, naming the CLI, the missing path and the repair command, when the sidecar is missing' {
        $reg = script:New-RegisteredProfile -Cli 'demomissing'
        Remove-Item -LiteralPath $reg.Sidecar -Force

        $r = script:Invoke-ProfileInChild -ProfilePath $reg.Profile -Commands 'demomissing'
        $r.Warnings.Count | Should -Be 1 -Because "a missing sidecar must not fail silently. Output: $($r.Raw -join ' | ')"
        $r.Warnings[0] | Should -Match 'demomissing'
        $r.Warnings[0] | Should -Match ([regex]::Escape($reg.Sidecar))
        $r.Warnings[0] | Should -Match 'Update-PackageCompletion'
    }

    It 'stays silent about a missing sidecar when the CLI is not installed' {
        # A roamed block for a CLI this machine does not have is a no-op.
        $reg = script:New-RegisteredProfile -Cli 'demoabsentcli'
        Remove-Item -LiteralPath $reg.Sidecar -Force

        $r = script:Invoke-ProfileInChild -ProfilePath $reg.Profile
        $r.Warnings | Should -BeNullOrEmpty
    }

    It 'warns with the load error when the sidecar throws' {
        $reg = script:New-RegisteredProfile -Cli 'demothrows' -Payload "throw 'sidecar-boom'"

        $r = script:Invoke-ProfileInChild -ProfilePath $reg.Profile -Commands 'demothrows'
        $r.Warnings.Count | Should -Be 1 -Because "a sidecar load error must not be swallowed. Output: $($r.Raw -join ' | ')"
        $r.Warnings[0] | Should -Match 'demothrows'
        $r.Warnings[0] | Should -Match 'sidecar-boom'
        $r.Warnings[0] | Should -Match 'Update-PackageCompletion -Force'
    }

    It 'keeps registering the remaining CLIs after one fails' {
        $dir = Join-Path $TestDrive 'mixed'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $profilePath = Join-Path $dir 'profile.ps1'
        $sidecarDir = Join-Path $dir 'completions'
        & $script:mod {
            param($p, $s)
            Register-PackageCompletion -Cli 'demofirst' -Mode native -ProfilePath $p -SidecarDirectory $s `
                -PreCapturedNative "throw 'first-boom'" -Confirm:$false | Out-Null
            Register-PackageCompletion -Cli 'demosecond' -Mode native -ProfilePath $p -SidecarDirectory $s `
                -PreCapturedNative "Register-ArgumentCompleter -Native -CommandName demosecond -ScriptBlock { 'gamma' }" -Confirm:$false | Out-Null
        } $profilePath $sidecarDir

        $r = script:Invoke-ProfileInChild -ProfilePath $profilePath -Commands 'demofirst','demosecond' -Probe 'demosecond '
        $r.Matches | Should -Contain 'gamma'
    }

    It 'detects and reports a missing sidecar whose path contains an apostrophe' {
        $dir = Join-Path $TestDrive "O'Brien"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $profilePath = Join-Path $dir 'profile.ps1'
        $sidecarDir = Join-Path $dir 'completions'
        & $script:mod {
            param($p, $s)
            Register-PackageCompletion -Cli 'demoapos' -Mode native -ProfilePath $p -SidecarDirectory $s `
                -PreCapturedNative "Register-ArgumentCompleter -Native -CommandName demoapos -ScriptBlock { }" -Confirm:$false
        } $profilePath $sidecarDir | Out-Null
        $sidecar = Join-Path $sidecarDir 'demoapos.ps1'
        $state = { & $script:mod { param($p) Get-PackageCompletionBlockState -Content (Get-Content -Raw $p) -Cli 'demoapos' } $profilePath }

        & $state | Should -Be 'Intact'
        Remove-Item -LiteralPath $sidecar -Force
        & $state | Should -Be 'SidecarMissing'

        $r = script:Invoke-ProfileInChild -ProfilePath $profilePath -Commands 'demoapos'
        $r.Warnings.Count | Should -Be 1 -Because "Output: $($r.Raw -join ' | ')"
        $r.Warnings[0] | Should -Match ([regex]::Escape($sidecar)) -Because 'the warning must show the real path, with a single apostrophe'
    }

    It 'the shared OnIdle drain warns instead of discarding an unexpected error' {
        $reg = script:New-RegisteredProfile -Cli 'demodrain'
        $r = script:Invoke-ProfileInChild -ProfilePath $reg.Profile -Commands 'demodrain' -ExtraQueued "throw 'drain-boom'"
        ($r.Warnings -join "`n") | Should -Match 'drain-boom' -Because "the drain's catch must not be empty. Output: $($r.Raw -join ' | ')"
    }
}

Describe 'Legacy Register-CliCompletion block reports a missing sidecar' -Tag 'Light','Completion' {

    It 'warns at profile load when the sidecar is missing' {
        $dir = Join-Path $TestDrive 'legacy'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $profilePath = Join-Path $dir 'profile.ps1'
        $sidecarDir = Join-Path $dir 'completions'
        & $script:mod {
            param($p, $s)
            Register-CliCompletion -Cli 'demolegacy' -ProfilePath $p -SidecarDirectory $s -Force -Confirm:$false `
                -NativeCommand { 'Register-ArgumentCompleter -Native -CommandName demolegacy -ScriptBlock { }' }
        } $profilePath $sidecarDir | Out-Null
        Remove-Item -LiteralPath (Join-Path $sidecarDir 'demolegacy.ps1') -Force

        $r = script:Invoke-ProfileInChild -ProfilePath $profilePath -Commands 'demolegacy'
        $r.Warnings.Count | Should -Be 1 -Because "Output: $($r.Raw -join ' | ')"
        $r.Warnings[0] | Should -Match 'demolegacy'
        $r.Warnings[0] | Should -Match 'Update-PackageCompletion'
    }
}

Describe 'Update-PackageCompletion gap-fill repairs a block whose sidecar is missing' -Tag 'Light','Completion' {

    BeforeAll {
        # pwsh is always on PATH while these tests run, so the Get-Command
        # gate in Update-PackageCompletion lets it through.
        $script:cli = 'pwsh'
        # An empty bucket dir has no CompletionCoverage.psd1, so only the
        # mocked declarative walk runs.
        $script:emptyBucket = Join-Path $TestDrive 'empty-bucket'
        New-Item -ItemType Directory -Path $script:emptyBucket -Force | Out-Null
    }

    It 'declarative CLI: re-registers without -Force, then preserves once healthy' {
        $cli = $script:cli
        $fakeBundle = [pscustomobject]@{
            Bundle   = 'Test'
            Packages = @(
                [pscustomobject]@{
                    Name = 'TestPkg'; CliCommands = @($cli); Completion = 'native'
                    HasNativeCommandScript = $true
                    NativeCommandOutputs = @{ $cli = "Register-ArgumentCompleter -Native -CommandName $cli -ScriptBlock { } # gapfill" }
                    NativeCommandScript = $null
                }
            )
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { @($fakeBundle) }

        $dir = Join-Path $TestDrive 'decl'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $profilePath = Join-Path $dir 'profile.ps1'
        Set-Content -Path $profilePath -Value '' -NoNewline
        $sidecar = Join-Path $dir "completions\$cli.ps1"

        Update-PackageCompletion -BucketPath $script:emptyBucket -ProfilePath $profilePath -Confirm:$false | Out-Null
        Test-Path $sidecar | Should -BeTrue
        Remove-Item -LiteralPath $sidecar -Force

        $rows = Update-PackageCompletion -BucketPath $script:emptyBucket -ProfilePath $profilePath -IncludeUnchanged -Confirm:$false
        $row = @($rows | Where-Object Cli -EQ $cli)
        $row.Count | Should -Be 1
        $row[0].Action | Should -Be 'Registered' -Because 'a block whose sidecar is missing is not healthy and gap-fill must repair it'
        $row[0].Reason | Should -Match 'missing'
        Test-Path $sidecar | Should -BeTrue

        $rows = Update-PackageCompletion -BucketPath $script:emptyBucket -ProfilePath $profilePath -IncludeUnchanged -Confirm:$false
        @($rows | Where-Object Cli -EQ $cli)[0].Action | Should -Be 'Preserved'
    }

    It 'procedural CLI: re-registers without -Force when the sidecar is missing' {
        $cli = $script:cli
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { @() }

        $bucket = Join-Path $TestDrive 'proc-bucket'
        New-Item -ItemType Directory -Path $bucket -Force | Out-Null
        Set-Content -Path (Join-Path $bucket 'CompletionCoverage.psd1') -Encoding UTF8 -Value @"
@{
    Clis = @(
        @{ Cli = '$cli'; Status = 'Registered'; Script = 'developer\PowerShell.ps1'; Switches = @('-NoProfile','-Command') }
    )
}
"@
        $dir = Join-Path $TestDrive 'proc'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $profilePath = Join-Path $dir 'profile.ps1'
        Set-Content -Path $profilePath -Value '' -NoNewline
        $sidecar = Join-Path $dir "completions\$cli.ps1"

        Update-PackageCompletion -BucketPath $bucket -ProfilePath $profilePath -Confirm:$false | Out-Null
        Test-Path $sidecar | Should -BeTrue
        Remove-Item -LiteralPath $sidecar -Force

        $rows = Update-PackageCompletion -BucketPath $bucket -ProfilePath $profilePath -IncludeUnchanged -Confirm:$false
        $row = @($rows | Where-Object { $_.Cli -eq $cli -and $_.Bundle -eq 'procedural' })
        $row.Count | Should -Be 1
        $row[0].Action | Should -Be 'Registered'
        $row[0].Reason | Should -Match 'missing'
        Test-Path $sidecar | Should -BeTrue
    }
}
