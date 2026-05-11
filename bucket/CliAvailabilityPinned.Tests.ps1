<#
.SYNOPSIS
    Phase 3 contract tests for CLI-availability (#45).

.DESCRIPTION
    PINNED expectations.  Each CLI listed here MUST resolve via Get-Command in
    a CI environment where the validate-installs workflow has run (so all
    bundle packages and the post-install hooks have been applied).  Locks
    the contract restored by PR #63 (PATH refresh + parser fixes) and PR #64
    (standalone-scoop parser, devenv shim, BeyondCompare bcomp.com remap,
    sysinternals dir on Machine PATH).

    Regressions surface here as test failures with actionable detail.

    Tagged 'Heavy','CliAvailability' so the standard fast suite is unaffected.
    The validate-installs workflow already invokes Pester with -Tag Heavy
    against bucket\*.Tests.ps1 immediately after CLI-availability discovery.

    To run locally (requires bundle packages already installed on the host):
        Invoke-Pester -Path .\bucket\CliAvailabilityPinned.Tests.ps1 -Tag Heavy
#>

Describe 'CLI availability — pinned contract' -Tag 'Heavy','CliAvailability' {

    BeforeAll {
        # Refresh PATH from registry so newly-installed shims/dirs are visible
        # in this Pester process, mirroring Invoke-PostInstallHooks.ps1.
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $merged  = @($machine, $user) |
            Where-Object { $_ } |
            ForEach-Object { $_.TrimEnd(';') } |
            Where-Object { $_ } |
            ForEach-Object { $_ }
        if ($merged) { $env:Path = ($merged -join ';') }
    }

    # -------------------------------------------------------------------------
    # Core CLIs that PR #63's PATH refresh restored (winget Links dir, scoop
    # global shims).  All shipped from winget's `C:\Program Files\WinGet\Links\`
    # or scoop's `C:\ProgramData\scoop\shims\` after `Update-PathFromRegistry`.
    # -------------------------------------------------------------------------
    Context 'PATH-refresh-fixed CLIs (PR #63)' {
        It 'resolves <Cli>' -ForEach @(
            @{ Cli = 'bw';       Package = 'Bitwarden.CLI' }
            @{ Cli = 'rg';       Package = 'BurntSushi.ripgrep.MSVC' }
            @{ Cli = 'calibre';  Package = 'calibre.calibre' }
            @{ Cli = 'sox';      Package = 'ChrisBagwell.SoX' }
            @{ Cli = 'copilot';  Package = 'GitHub.Copilot' }
            @{ Cli = 'gcloud';   Package = 'Google.CloudSDK' }
            @{ Cli = 'fzf';      Package = 'junegunn.fzf' }
            @{ Cli = 'code';     Package = 'Microsoft.VisualStudioCode' }
            @{ Cli = 'bat';      Package = 'sharkdp.bat' }
            @{ Cli = 'es';       Package = 'voidtools.Everything.Cli' }
            @{ Cli = 'bcompare'; Package = 'extras/beyondcompare' }
        ) {
            param($Cli, $Package)
            $cmd = Get-Command $Cli -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty -Because "expected '$Cli' (from $Package) to be on PATH"
        }
    }

    # -------------------------------------------------------------------------
    # CLIs that PR #64 wired up via standalone-scoop parser + post-install hooks.
    # -------------------------------------------------------------------------
    Context 'Post-install-hook CLIs (PR #64)' {
        It 'resolves ffmpeg (scoop install ffmpeg now actually runs in CI)' {
            $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }

        It 'resolves devenv (shim created by Invoke-PostInstallHooks.ps1 via vswhere)' {
            $cmd = Get-Command devenv -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }
    }

    # -------------------------------------------------------------------------
    # Sysinternals: representative subset proves the install-dir-on-PATH fix
    # in OSBasePackages.ps1 (humans) / Invoke-PostInstallHooks.ps1 (CI) works.
    # Drift on any of these means the PATH-add regressed.
    # -------------------------------------------------------------------------
    Context 'Sysinternals suite (install dir on Machine PATH)' {
        It 'resolves <_>' -ForEach @('procexp','procmon','psexec','handle','pslist') {
            $cmd = Get-Command $_ -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty -Because "extras/sysinternals install dir must be on Machine PATH"
        }
    }

    # -------------------------------------------------------------------------
    # BeyondCompare: the package ships THREE relevant binaries with different
    # behaviour.  Scoop's manifest only shims BCompare.exe (-> bcompare) and
    # BComp.exe (-> bcomp); BComp.com (the console-waiting variant used by
    # VCS hooks) is not shimmed by default.  PR #64 retargets `bcomp` -> BComp.com
    # and adds the install dir to Machine PATH so `bcomp.exe` remains reachable
    # by explicit name.
    # -------------------------------------------------------------------------
    Context 'BeyondCompare three-binary surface (PR #64)' {
        It 'resolves bcompare -> BCompare.exe (main app)' {
            $cmd = Get-Command bcompare -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }

        It 'resolves bcomp and targets BComp.com (console-waiting variant)' {
            $cmd = Get-Command bcomp -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            # Resolve through the shim to its ultimate target.  Scoop shims are
            # `.shim` text files alongside a `.exe` launcher; the launcher's
            # path is what Get-Command returns.  For the BComp.com remap we
            # inspect the sidecar `.shim` file which records the real target.
            $shimDir = Split-Path $cmd.Source -Parent
            $shimMeta = Join-Path $shimDir 'bcomp.shim'
            if (Test-Path $shimMeta) {
                $target = (Get-Content $shimMeta | Select-String '^path\s*=' | Select-Object -First 1).Line
                $target | Should -Match 'BComp\.com'
            } else {
                # Fallback: source path itself should end with BComp.com.
                $cmd.Source | Should -Match 'BComp\.com$'
            }
        }

        It 'resolves bcomp.exe by explicit extension (BC install dir on PATH)' {
            $cmd = Get-Command bcomp.exe -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }
    }
}
