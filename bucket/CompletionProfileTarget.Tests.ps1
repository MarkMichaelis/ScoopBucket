# ----------------------------------------------------------------------------
# Completion profile target resolution (#397).
#
# Regression guard for the failure that made completions silently dead on any
# machine carrying two PowerShell installs.
#
# $PROFILE.AllUsersAllHosts is $PSHOME\profile.ps1 -- scoped to a single
# PowerShell INSTALLATION, not the machine. A box with both the Store/MSIX and
# the MSI build of PowerShell 7 has two of them, so registering into whichever
# install happened to run the installer left the other host with nothing. The
# Store copy lives under WindowsApps, which Windows refuses to write even for
# administrators, so elevation could never fix it.
#
# The target is therefore CurrentUserAllHosts, which every PowerShell 7 host
# for the user loads regardless of which install launched it.
# ----------------------------------------------------------------------------

BeforeAll {
    $script:psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
}

Describe 'Completion profile target' -Tag 'Light','Completion' {

    It 'resolves to CurrentUserAllHosts, never AllUsersAllHosts (#397)' {
        if (-not (Test-Path $PROFILE.CurrentUserAllHosts)) {
            Set-ItResult -Skipped -Because 'resolving would create the user profile file as a side effect'
            return
        }
        $target = & $script:mod { Resolve-CompletionProfileTarget }
        $target | Should -Be $PROFILE.CurrentUserAllHosts
        $target | Should -Not -Be $PROFILE.AllUsersAllHosts -Because 'AllUsersAllHosts is per-install and unreachable for a Store-installed pwsh (#397)'
    }

    It 'declarative and legacy registration paths agree on the target' {
        if (-not (Test-Path $PROFILE.CurrentUserAllHosts)) {
            Set-ItResult -Skipped -Because 'resolving would create the user profile file as a side effect'
            return
        }
        # Register-PackageCompletion (declarative, the bundle CliCommands path)
        # and Register-CliCompletion (procedural, e.g. gh/gk from
        # GitConfigure.ps1) must write to the same file or half the CLIs land
        # somewhere the user's shell never reads.
        $declarative = & $script:mod { Get-PackageCompletionProfilePath }
        $legacy      = & $script:mod { Get-CompletionProfilePath }
        $declarative | Should -Be $legacy
    }

    It 'honours -OverridePath on both paths (test hook still works)' {
        $fake = Join-Path $TestDrive 'sandbox-profile.ps1'
        (& $script:mod { param($p) Get-PackageCompletionProfilePath -OverridePath $p } $fake) | Should -Be $fake
        (& $script:mod { param($p) Get-CompletionProfilePath        -OverridePath $p } $fake) | Should -Be $fake
    }

    It 'does not require elevation' {
        # The old resolver threw "requires an elevated PowerShell session"
        # before it ever looked at writability. A per-user profile needs no
        # such thing, and the throw was a dead end on Store-only machines.
        $src = & $script:mod { (Get-Command Resolve-CompletionProfileTarget).Definition }
        $src | Should -Not -Match 'Test-IsElevated'
    }
}

Describe 'Completion sidecar directory' -Tag 'Light','Completion' {

    It 'keeps a sandboxed profile self-contained' {
        $sandboxProfile = Join-Path $TestDrive 'profile.ps1'
        $dir = & $script:mod { param($p) Get-PackageCompletionSidecarDirectory -ProfilePath $p } $sandboxProfile
        $dir | Should -Be (Join-Path $TestDrive 'completions')
    }

    It 'uses the ProgramData default for the real profile' {
        if (-not $env:ProgramData) {
            Set-ItResult -Skipped -Because 'no ProgramData on this host'
            return
        }
        $dir = & $script:mod { param($p) Get-PackageCompletionSidecarDirectory -ProfilePath $p } $PROFILE.CurrentUserAllHosts
        $dir | Should -Be (Join-Path $env:ProgramData 'ScoopBucket\completions')
    }

    It 'lets -OverrideDirectory win' {
        $override = Join-Path $TestDrive 'explicit'
        $dir = & $script:mod { param($d) Get-PackageCompletionSidecarDirectory -OverrideDirectory $d } $override
        $dir | Should -Be $override
    }
}
