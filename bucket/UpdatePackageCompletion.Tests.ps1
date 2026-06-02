#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for Update-PackageCompletion — the post-PSCompletions-install
# repair cmdlet that rewrites sentinel blocks for already-installed
# CLIs whose Completion mode is 'pscompletions' (or 'auto' without a
# NativeCommandScript). Covers the bw <Tab> repair scenario from #73
# follow-up.

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    Import-Module $script:psd1 -Force

    # Throwaway bucket with one declarative bundle that exercises every
    # eligible / non-eligible Completion shape:
    #   pscompletions-bw       — pscompletions mode (eligible)
    #   pscompletions-other    — pscompletions mode but CLI NOT on PATH (skipped)
    #   auto-no-native         — auto mode, no NativeCommandScript (eligible)
    #   auto-with-native       — auto mode, with NativeCommandScript  (skipped — repair can't rebuild native)
    #   none-mode              — Completion='none' (ignored entirely)
    #   no-clicommands         — Completion='auto' but CliCommands=@() (ignored)
    $script:tmpBucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-update-completion-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:tmpBucket | Out-Null

    # Pick a CLI that's guaranteed to be on PATH on every dev / CI Win
    # box for the eligible cases ('cmd.exe' resolves on all Windows
    # hosts; 'pwsh' resolves wherever Pester 7 runs).
    $script:onPathCli  = 'pwsh'
    $script:offPathCli = 'definitely-not-a-real-cli-' + [guid]::NewGuid().ToString('N').Substring(0,8)

    $bundleText = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{
        Name        = 'PscompletionsBw'
        Installer   = 'winget'
        Id          = 'Test.PscompletionsBw'
        CliCommands = @('$($script:onPathCli)')
        Completion  = 'pscompletions'
    }
    [Package]@{
        Name        = 'PscompletionsOffPath'
        Installer   = 'winget'
        Id          = 'Test.PscompletionsOffPath'
        CliCommands = @('$($script:offPathCli)')
        Completion  = 'pscompletions'
    }
    [Package]@{
        Name        = 'AutoNoNative'
        Installer   = 'winget'
        Id          = 'Test.AutoNoNative'
        CliCommands = @('$($script:onPathCli)-twin')
        Completion  = 'auto'
    }
    [Package]@{
        Name                = 'AutoWithNative'
        Installer           = 'winget'
        Id                  = 'Test.AutoWithNative'
        CliCommands         = @('$($script:onPathCli)-native')
        Completion          = 'auto'
        NativeCommandScript = { 'auto-native-completion-source' }
    }
    [Package]@{
        Name                = 'NativeOnly'
        Installer           = 'winget'
        Id                  = 'Test.NativeOnly'
        CliCommands         = @('$($script:onPathCli)-nativeonly')
        Completion          = 'native'
        NativeCommandScript = { 'pure-native-completion-source' }
    }
    [Package]@{
        Name        = 'NoneMode'
        Installer   = 'winget'
        Id          = 'Test.NoneMode'
        CliCommands = @('$($script:onPathCli)-none')
        Completion  = 'none'
    }
    [Package]@{
        Name      = 'NoCliCommands'
        Installer = 'winget'
        Id        = 'Test.NoCliCommands'
    }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'UpdateCompletionBundle'
"@
    Set-Content -Path (Join-Path $script:tmpBucket 'UpdateCompletionBundle.ps1') -Value $bundleText -Encoding UTF8

    # Make AutoNoNative's CLI resolve via Get-Command by dropping a shim
    # PS1 into a folder we then prepend to $env:PATH for the duration
    # of this Describe block.
    $script:shimDir = Join-Path $script:tmpBucket '_shims'
    New-Item -ItemType Directory -Path $script:shimDir | Out-Null
    foreach ($shimName in @("$($script:onPathCli)-twin.ps1", "$($script:onPathCli)-native.ps1", "$($script:onPathCli)-nativeonly.ps1", "$($script:onPathCli)-none.ps1")) {
        Set-Content -Path (Join-Path $script:shimDir $shimName) -Value '# stub' -Encoding UTF8
    }
    $script:savedPath = $env:PATH
    $env:PATH = "$script:shimDir;$env:PATH"

    # Per-test fresh profile so block-already-exists state is isolated.
    $script:profilePath = Join-Path $script:tmpBucket 'profile.ps1'
}

AfterAll {
    if ($script:savedPath) { $env:PATH = $script:savedPath }
    if ($script:tmpBucket -and (Test-Path $script:tmpBucket)) {
        Remove-Item -LiteralPath $script:tmpBucket -Recurse -Force -ErrorAction Ignore
    }
}

Describe 'Update-PackageCompletion eligibility classification' -Tag 'Light' {
    BeforeEach {
        if (Test-Path $script:profilePath) { Remove-Item -LiteralPath $script:profilePath -Force }
    }

    It 'skips pscompletions packages whose CLI is not on PATH' {
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf -IncludeUnchanged
        $offPath = $results | Where-Object Cli -EQ $script:offPathCli
        $offPath | Should -Not -BeNullOrEmpty
        $offPath.Action | Should -Be 'Skipped'
        $offPath.Reason | Should -Match 'not on PATH'
    }

    It "registers Completion='auto' packages with a NativeCommandScript using pre-captured native output" {
        # Regression for #170: previously skipped with reason 'native scriptblock'.
        # Get-BundlePackages pre-captures the NativeCommandScript output
        # into NativeCommandOutputs[$cli], so we can now write a native
        # block during a profile-repair walk without re-running the
        # original installer.
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath
        $native = $results | Where-Object Cli -EQ "$($script:onPathCli)-native"
        $native | Should -Not -BeNullOrEmpty
        $native.Action | Should -Be 'Registered'
        $native.Source | Should -Be 'Native'
        $native.Mode   | Should -Be 'native'

        # v3 (#216): the captured native completion source moved from the
        # profile (inline OnIdle Action body) to a sidecar
        # <profile-dir>\completions\<cli>.ps1 that the profile dot-sources.
        # The profile itself must reference the sidecar and use the v3
        # sentinel; the payload must live in the sidecar.
        $profileContent = Get-Content -Raw -Encoding UTF8 $script:profilePath
        $profileContent | Should -Match "ScoopBucket:CliCompletion:$($script:onPathCli)-native:BEGIN v4"
        $sidecar = Join-Path (Split-Path -Parent $script:profilePath) "completions\$($script:onPathCli)-native.ps1"
        Test-Path $sidecar | Should -BeTrue
        (Get-Content -Raw -Encoding UTF8 $sidecar) | Should -Match 'auto-native-completion-source'
    }

    It "registers Completion='native' packages whose CLI is on PATH" {
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath
        $nativeOnly = $results | Where-Object Cli -EQ "$($script:onPathCli)-nativeonly"
        $nativeOnly | Should -Not -BeNullOrEmpty
        $nativeOnly.Action | Should -Be 'Registered'
        $nativeOnly.Source | Should -Be 'Native'
        $nativeOnly.Mode   | Should -Be 'native'

        # v3 (#216): payload lives in the sidecar, not the profile.
        $sidecar = Join-Path (Split-Path -Parent $script:profilePath) "completions\$($script:onPathCli)-nativeonly.ps1"
        Test-Path $sidecar | Should -BeTrue
        (Get-Content -Raw -Encoding UTF8 $sidecar) | Should -Match 'pure-native-completion-source'
    }

    It "ignores Completion='none' and packages without CliCommands" {
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf -IncludeUnchanged
        ($results | Where-Object Cli -EQ "$($script:onPathCli)-none") | Should -BeNullOrEmpty
        ($results | Where-Object Package -EQ 'NoCliCommands')          | Should -BeNullOrEmpty
    }

    It 'reports WhatIf for eligible CLIs (pscompletions + auto-no-native + native) when -WhatIf supplied' {
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf
        $bw = $results | Where-Object Cli -EQ $script:onPathCli
        $bw | Should -Not -BeNullOrEmpty
        $bw.Action | Should -Be 'WhatIf'
        $bw.Mode   | Should -Be 'pscompletions'

        $twin = $results | Where-Object Cli -EQ "$($script:onPathCli)-twin"
        $twin | Should -Not -BeNullOrEmpty
        $twin.Action | Should -Be 'WhatIf'
        # auto-mode without NativeCommandScript collapses to pscompletions
        # because that's the only registration path we can safely repair.
        $twin.Mode | Should -Be 'pscompletions'

        # auto-mode WITH a NativeCommandScript now repairs via native too.
        $autoNative = $results | Where-Object Cli -EQ "$($script:onPathCli)-native"
        $autoNative | Should -Not -BeNullOrEmpty
        $autoNative.Action | Should -Be 'WhatIf'
        $autoNative.Mode   | Should -Be 'native'

        $nativeOnly = $results | Where-Object Cli -EQ "$($script:onPathCli)-nativeonly"
        $nativeOnly | Should -Not -BeNullOrEmpty
        $nativeOnly.Action | Should -Be 'WhatIf'
        $nativeOnly.Mode   | Should -Be 'native'
    }

    It "preserves existing sentinel blocks unless -Force is passed" {
        # Pre-seed the profile with a block for the eligible CLI.
        $existing = "# ScoopBucket:CliCompletion:$($script:onPathCli):BEGIN v1`r`n# (existing)`r`n# ScoopBucket:CliCompletion:$($script:onPathCli):END`r`n"
        Set-Content -Path $script:profilePath -Value $existing -Encoding UTF8

        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf -IncludeUnchanged
        $bw = $results | Where-Object Cli -EQ $script:onPathCli
        $bw.Action | Should -Be 'Preserved'
        $bw.Reason | Should -Match 'pass -Force'
    }

    It 'does not write a per-row Write-Host tally with -IncludeUnchanged (#276 quiet output)' {
        # The returned rows ARE the output; the old one-line Write-Host tally
        # duplicated them. With -IncludeUnchanged there are no suppressed rows
        # to summarize, so Write-Host must never fire.
        Mock -ModuleName MarkMichaelis.ScoopBucket Write-Host { }

        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf -IncludeUnchanged

        $results | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Write-Host -Times 0 -Exactly
    }
}

Describe 'Update-PackageCompletion changed-only output (#285)' -Tag 'Light' {
    BeforeEach {
        if (Test-Path $script:profilePath) { Remove-Item -LiteralPath $script:profilePath -Force }
    }

    It 'returns only changed rows (Registered / WhatIf) and suppresses Skipped by default' {
        # Fresh profile + -WhatIf: every eligible on-PATH CLI is a WhatIf row
        # (shown); the off-PATH CLI is Skipped (suppressed by default).
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf

        ($results | Where-Object Action -EQ 'Skipped')  | Should -BeNullOrEmpty
        ($results | Where-Object Cli -EQ $script:offPathCli) | Should -BeNullOrEmpty
        ($results | Where-Object Action -EQ 'WhatIf')   | Should -Not -BeNullOrEmpty
        ($results | ForEach-Object Action | Sort-Object -Unique) |
            ForEach-Object { $_ | Should -BeIn @('Registered', 'WhatIf') }
    }

    It 'prints a host-only Hidden summary line for the suppressed rows' {
        # Record every Write-Host line via a global list. ParameterFilter on
        # the positional $Object is brittle across hosts, so we capture the
        # rendered text directly and assert on the joined output.
        $global:scoopBucketHostLines = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName MarkMichaelis.ScoopBucket Write-Host {
            $global:scoopBucketHostLines.Add([string]$Object)
        }

        $null = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf

        try {
            ($global:scoopBucketHostLines -join "`n") |
                Should -Match 'Hidden: .*skipped.*-IncludeUnchanged'
        } finally {
            Remove-Variable -Name scoopBucketHostLines -Scope Global -ErrorAction Ignore
        }
    }

    It '-IncludeUnchanged returns every row (including Skipped) and prints no Hidden line' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Write-Host { }

        $all = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf -IncludeUnchanged

        ($all | Where-Object Action -EQ 'Skipped') | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Write-Host -Times 0 -Exactly
    }

    It 'tags every returned row with the CompletionResult type name for the format view' {
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf
        $results | Should -Not -BeNullOrEmpty
        foreach ($r in $results) {
            $r.PSObject.TypeNames | Should -Contain 'MarkMichaelis.ScoopBucket.CompletionResult'
        }
    }
}

Describe 'Update-PackageCompletion quiet -WhatIf output (#287)' -Tag 'Light' {
    BeforeEach {
        if (Test-Path $script:profilePath) { Remove-Item -LiteralPath $script:profilePath -Force }
    }

    It 'leaves the Reason empty on WhatIf preview rows (the Action column already says WhatIf)' {
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf -IncludeUnchanged

        $whatIf = $results | Where-Object Action -EQ 'WhatIf'
        $whatIf | Should -Not -BeNullOrEmpty
        foreach ($row in $whatIf) {
            $row.Reason | Should -BeNullOrEmpty
        }
    }

    It 'tags WhatIf preview rows with Source=WhatIf (not Skipped)' {
        # Distinguishes a -WhatIf preview (would register) from a genuine
        # Skipped row, and guards the same branch that bypasses
        # ShouldProcess (and therefore its built-in "What if:" host line).
        # If the ShouldProcess-gated preview path is reinstated, these rows
        # revert to Source='Skipped' and this fails.
        $results = Update-PackageCompletion -BucketPath $script:tmpBucket `
            -ProfilePath $script:profilePath -WhatIf -IncludeUnchanged

        $whatIf = $results | Where-Object Action -EQ 'WhatIf'
        $whatIf | Should -Not -BeNullOrEmpty
        foreach ($row in $whatIf) {
            $row.Source | Should -Be 'WhatIf'
        }
    }
}
