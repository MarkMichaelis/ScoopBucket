$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install' {
    BeforeAll {
        # Re-derive rather than closing over the discovery-phase $name: at run
        # phase Pester evaluates BeforeAll in a fresh scope where $PSCommandPath
        # (and therefore the file-scoped $name) is empty.
        $script:name = 'GitConfigGitHubCli'

        if (Test-ScoopPackageInstalled $script:name) {
            scoop uninstall $script:name
        }

        # `gh iv` reads the issue from whichever repo the working directory
        # resolves to, so every alias invocation below runs from the bucket
        # checkout. Pester's working directory is not guaranteed otherwise.
        $script:ghAvailable = [bool](Get-Command gh -ErrorAction Ignore)
        $script:ghAuthed = $false
        $script:probeIssue = $null
        if ($script:ghAvailable) {
            Push-Location $PSScriptRoot
            try {
                gh auth status *>$null
                $script:ghAuthed = ($LASTEXITCODE -eq 0)
                if ($script:ghAuthed) {
                    # Any issue will do; --state all so a fully triaged repo
                    # still yields a probe target.
                    $script:probeIssue = (gh issue list --state all --limit 1 --json number --jq '.[0].number' 2>$null)
                }
            }
            finally { Pop-Location }
        }
    }

    It 'installs from the local manifest' {
        Install-LocalManifest "$PSScriptRoot\$($script:name).json"
        Test-ScoopPackageInstalled $script:name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$($script:name).json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $script:name | Should -Be $true
    }

    It 'ships gh-aliases.yml alongside the configurator' {
        . "$PSScriptRoot\GitConfigGitHubCli.ps1" *>$null
        Resolve-GhAliasFile | Should -Not -BeNullOrEmpty
    }

    It 'imports gh-aliases.yml into an isolated gh config without error' {
        if (-not $script:ghAvailable) {
            Set-ItResult -Skipped -Because 'gh not installed'
            return
        }
        # GH_CONFIG_DIR sandboxes the import so the assertion never mutates the
        # developer's real %APPDATA%\GitHub CLI\config.yml.
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("gh-alias-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        $prior = $env:GH_CONFIG_DIR
        try {
            $env:GH_CONFIG_DIR = $sandbox
            gh alias import "$PSScriptRoot\gh-aliases.yml" --clobber *>$null
            $LASTEXITCODE | Should -Be 0
            (gh alias list) -join "`n" | Should -Match '(?m)^iv:'
        }
        finally {
            $env:GH_CONFIG_DIR = $prior
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'executes gh iv with an issue number and emits the compact title line' {
        if (-not $script:ghAuthed) {
            Set-ItResult -Skipped -Because 'gh not installed or not authenticated'
            return
        }
        if (-not $script:probeIssue) {
            Set-ItResult -Skipped -Because 'no issues in this repo to probe'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $out = gh iv $script:probeIssue
            $LASTEXITCODE | Should -Be 0
            ($out -join "`n") | Should -Match "^#$($script:probeIssue) \S"
        }
        finally { Pop-Location }
    }

    It 'accepts a leading # on the issue number' {
        if (-not $script:ghAuthed -or -not $script:probeIssue) {
            Set-ItResult -Skipped -Because 'gh not authenticated or no issues to probe'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $out = gh iv "#$($script:probeIssue)"
            $LASTEXITCODE | Should -Be 0
            ($out -join "`n") | Should -Match "^#$($script:probeIssue) \S"
        }
        finally { Pop-Location }
    }

    It 'executes gh iv -s and adds a body summary line' {
        if (-not $script:ghAuthed -or -not $script:probeIssue) {
            Set-ItResult -Skipped -Because 'gh not authenticated or no issues to probe'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $out = @(gh iv $script:probeIssue -s)
            $LASTEXITCODE | Should -Be 0
            # Title line plus at least one summary line -- the summary branch
            # emits "(no body)" rather than nothing when the issue has no body.
            $out.Count | Should -BeGreaterOrEqual 2
            $out[0] | Should -Match "^#$($script:probeIssue) \S"
            $out[1] | Should -Not -BeNullOrEmpty
        }
        finally { Pop-Location }
    }

    It 'writes a gh-backed credential.helper into an isolated global git config' {
        # Issue #434 end to end against the real gh. GIT_CONFIG_GLOBAL (git
        # 2.32+) repoints `git config --global` -- which is what gh auth setup-git
        # shells out to -- at a throwaway file, so this never rewrites the
        # developer's real ~/.gitconfig. Also pins the caveat: the helper value
        # is an absolute path to the gh binary, not a bare `gh`.
        if (-not $script:ghAuthed) {
            Set-ItResult -Skipped -Because 'gh not installed or not authenticated'
            return
        }
        $sandboxConfig = Join-Path ([System.IO.Path]::GetTempPath()) "setupgit-$([guid]::NewGuid()).gitconfig"
        $prior = $env:GIT_CONFIG_GLOBAL
        try {
            $env:GIT_CONFIG_GLOBAL = $sandboxConfig
            gh auth setup-git *>$null
            $LASTEXITCODE | Should -Be 0
            $helper = git config --global --get-all 'credential.https://github.com.helper'
            ($helper -join "`n") | Should -Match 'gh(\.exe)?'
            # Re-running must not append a second copy of the same entry.
            gh auth setup-git *>$null
            $after = @(git config --global --get-all 'credential.https://github.com.helper')
            $after.Count | Should -Be @($helper).Count
        }
        finally {
            if ($null -eq $prior) {
                Remove-Item Env:\GIT_CONFIG_GLOBAL -ErrorAction Ignore
            } else {
                $env:GIT_CONFIG_GLOBAL = $prior
            }
            Remove-Item -LiteralPath $sandboxConfig -Force -ErrorAction Ignore
        }
    }

    It 'exits 2 with a usage message when no issue number is given' {
        if (-not $script:ghAvailable) {
            Set-ItResult -Skipped -Because 'gh not installed'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $err = (gh iv 2>&1) -join "`n"
            $LASTEXITCODE | Should -Be 2
            $err | Should -Match 'usage: gh iv'
        }
        finally { Pop-Location }
    }
}

Describe "Behaviour $sut (unit)" -Tag 'Light', 'Unit' {
    BeforeAll {
        $script:configurator = Join-Path $PSScriptRoot 'GitConfigGitHubCli.ps1'

        # Dot-sourcing the configurator self-invokes Invoke-GitConfigGitHubCli
        # (last line of the file), so merely loading the function under test
        # would import the aliases for real. GH_CONFIG_DIR redirects gh's
        # per-user config away from %APPDATA%\GitHub CLI\ for the whole block,
        # so neither the load nor any assertion can touch the developer's real
        # alias set.
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "ghcfg-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:priorConfigDir = $env:GH_CONFIG_DIR
        $env:GH_CONFIG_DIR = $script:sandbox

        # Same containment for the *git* side: the credential-helper step shells
        # out to `gh auth setup-git`, which writes `git config --global`.
        # GIT_CONFIG_GLOBAL (git 2.32+) repoints --global at a throwaway file, so
        # the load-time self-invocation can never rewrite the developer's real
        # ~/.gitconfig even on a machine whose gh is authenticated.
        $script:gitConfigSandbox = Join-Path $script:sandbox 'sandbox.gitconfig'
        $script:priorGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
        $env:GIT_CONFIG_GLOBAL = $script:gitConfigSandbox

        . $script:configurator *>$null
    }

    AfterAll {
        if ($null -eq $script:priorConfigDir) {
            Remove-Item Env:\GH_CONFIG_DIR -ErrorAction Ignore
        } else {
            $env:GH_CONFIG_DIR = $script:priorConfigDir
        }
        if ($null -eq $script:priorGitConfigGlobal) {
            Remove-Item Env:\GIT_CONFIG_GLOBAL -ErrorAction Ignore
        } else {
            $env:GIT_CONFIG_GLOBAL = $script:priorGitConfigGlobal
        }
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction Ignore
    }

    It 'parses without syntax errors' {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:configurator, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'ships gh-aliases.yml alongside the configurator' {
        # The manifest url list ships this file into the same app dir; the
        # configurator resolves it via $PSScriptRoot and no-ops without it.
        Test-Path (Join-Path $PSScriptRoot 'gh-aliases.yml') | Should -Be $true
    }

    It 'declares the iv alias as a shell alias' {
        $yml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gh-aliases.yml') -Raw
        $yml | Should -Match '(?m)^iv:'
        # gh only runs an expansion through POSIX sh when it is '!'-prefixed;
        # without the bang the whole one-liner would be treated as gh args.
        $yml | Should -Match '(?m)^\s*!s=0;'
    }

    It 'warns and returns without throwing when gh is not installed' {
        # Acceptance criterion from issue #406. Unreachable on a machine that
        # has gh -- which is every machine the Heavy suite runs on -- so the
        # absent-tool guard is only ever exercised here, under a mock.
        Mock Get-Command -ParameterFilter { $Name -eq 'gh' } -MockWith { $null }

        $captured = $null
        { $script:captured = Invoke-GitConfigGitHubCli 3>&1 } | Should -Not -Throw
        ($script:captured | Out-String) | Should -Match 'gh not found'
    }

    It 'warns and returns without throwing when gh-aliases.yml is missing' {
        # The second guard: gh present but the data file absent, which is what
        # a manifest that forgot the gh-aliases.yml url would produce. Exercised
        # against the alias step alone rather than the orchestrator, so the
        # credential step is not driven for real just to assert this warning.
        Mock Resolve-GhAliasFile -MockWith { $null }

        $captured = $null
        { $script:captured = Set-GitHubCliAlias 3>&1 } | Should -Not -Throw
        ($script:captured | Out-String) | Should -Match 'gh-aliases\.yml not found'
    }

    Context 'git credential helper (issue #434)' {
        # `gh auth setup-git` is the whole point of the step, and it mutates
        # global git config, so every test here mocks Invoke-GhAuthSetupGit --
        # the seam that wraps the native call -- and asserts on whether the
        # guards let it through. Nothing below can reach git or the network.

        BeforeAll {
            # Stand-in for a gh on PATH, so the "gh is present" tests assert the
            # same on a machine that has gh and one that does not.
            $script:fakeGh = [pscustomobject]@{ Source = 'C:\fake\gh.exe' }
        }

        It 'maps the gh auth status exit code to a boolean' {
            # The exit code is the only authentication signal gh gives us, and
            # it is injected rather than probed so this stays a pure unit test.
            Test-GhAuthenticated -StatusProbe { 0 } | Should -BeTrue
            Test-GhAuthenticated -StatusProbe { 1 } | Should -BeFalse
            Test-GhAuthenticated -StatusProbe { 4 } | Should -BeFalse
        }

        It 'warns and skips the credential helper when gh is not installed' {
            Mock Get-Command -ParameterFilter { $Name -eq 'gh' } -MockWith { $null }
            Mock Invoke-GhAuthSetupGit -MockWith { [pscustomobject]@{ ExitCode = 0; Output = '' } }

            $captured = $null
            { $script:captured = Set-GitCredentialHelperFromGitHubCli 3>&1 } | Should -Not -Throw
            ($script:captured | Out-String) | Should -Match 'gh not found'
            Should -Invoke Invoke-GhAuthSetupGit -Times 0 -Exactly
        }

        It 'warns telling the user to run gh auth login when gh is unauthenticated' {
            # The unattended case: a never-logged-in machine must warn and skip
            # rather than hang on the OAuth device flow or fail the bundle.
            Mock Get-Command -ParameterFilter { $Name -eq 'gh' } -MockWith { $script:fakeGh }
            Mock Test-GhAuthenticated -MockWith { $false }
            Mock Invoke-GhAuthSetupGit -MockWith { [pscustomobject]@{ ExitCode = 0; Output = '' } }

            $captured = $null
            { $script:captured = Set-GitCredentialHelperFromGitHubCli 3>&1 } | Should -Not -Throw
            ($script:captured | Out-String) | Should -Match 'gh auth login'
            Should -Invoke Invoke-GhAuthSetupGit -Times 0 -Exactly
        }

        It 'runs gh auth setup-git when gh is present and authenticated' {
            Mock Get-Command -ParameterFilter { $Name -eq 'gh' } -MockWith { $script:fakeGh }
            Mock Test-GhAuthenticated -MockWith { $true }
            Mock Invoke-GhAuthSetupGit -MockWith { [pscustomobject]@{ ExitCode = 0; Output = '' } }

            $captured = $null
            { $script:captured = Set-GitCredentialHelperFromGitHubCli 3>&1 } | Should -Not -Throw
            ($script:captured | Out-String) | Should -Not -Match 'WARNING|Skipping'
            Should -Invoke Invoke-GhAuthSetupGit -Times 1 -Exactly
        }

        It 'is idempotent -- a second run re-applies the helper without throwing' {
            # Idempotency contract: setup-git rewrites the same credential.helper
            # entries with --replace-all, so re-running is a no-op in effect and
            # must never throw or double up.
            Mock Get-Command -ParameterFilter { $Name -eq 'gh' } -MockWith { $script:fakeGh }
            Mock Test-GhAuthenticated -MockWith { $true }
            Mock Invoke-GhAuthSetupGit -MockWith { [pscustomobject]@{ ExitCode = 0; Output = '' } }

            { Set-GitCredentialHelperFromGitHubCli *>$null } | Should -Not -Throw
            { Set-GitCredentialHelperFromGitHubCli *>$null } | Should -Not -Throw
            Should -Invoke Invoke-GhAuthSetupGit -Times 2 -Exactly
        }

        It 'warns without throwing when gh auth setup-git fails' {
            Mock Get-Command -ParameterFilter { $Name -eq 'gh' } -MockWith { $script:fakeGh }
            Mock Test-GhAuthenticated -MockWith { $true }
            Mock Invoke-GhAuthSetupGit -MockWith {
                [pscustomobject]@{ ExitCode = 1; Output = 'boom' }
            }

            $captured = $null
            { $script:captured = Set-GitCredentialHelperFromGitHubCli 3>&1 } | Should -Not -Throw
            ($script:captured | Out-String) | Should -Match 'gh auth setup-git failed'
        }

        It 'records the scoop-uninstall caveat next to the setup-git call' {
            # `gh auth setup-git` bakes an ABSOLUTE path to the gh binary into
            # credential.helper, so a scoop-installed gh leaves git auth broken
            # once gh is uninstalled. The caveat must travel with the code.
            $source = Get-Content -LiteralPath $script:configurator -Raw
            $source | Should -Match 'absolute path'
            $source | Should -Match 'scoop'
        }

        It 'surfaces the caveat to the installing user through manifest notes' {
            # scoop prints `notes` after an install, which is the only place a
            # user who never reads the script will see the uninstall hazard.
            $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'GitConfigGitHubCli.json') -Raw |
                ConvertFrom-Json
            $manifest.notes | Should -Not -BeNullOrEmpty
            ($manifest.notes -join ' ') | Should -Match 'gh auth setup-git'
            ($manifest.notes -join ' ') | Should -Match 'gh auth login'
        }

        It 'configures aliases and credentials as independent steps' {
            # A missing gh-aliases.yml must not suppress credential setup (and
            # vice versa): the orchestrator runs both, each with its own guards.
            Mock Set-GitHubCliAlias -MockWith { }
            Mock Set-GitCredentialHelperFromGitHubCli -MockWith { }

            Invoke-GitConfigGitHubCli *>$null

            Should -Invoke Set-GitHubCliAlias -Times 1 -Exactly
            Should -Invoke Set-GitCredentialHelperFromGitHubCli -Times 1 -Exactly
        }
    }
}
