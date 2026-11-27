#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    The Git set-up items GitConfigure was split into (#563), run against a
    throw-away global git config and profile folder.

.DESCRIPTION
    Each script runs in a child pwsh with GIT_CONFIG_GLOBAL, USERPROFILE and
    Data pointed at a temp folder, so nothing touches the real machine. Every
    script is run twice: the second run must change nothing (README's
    twice-runnable contract).
#>

BeforeAll {
    $script:Dir = $PSScriptRoot
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-SetupScript {
        param([string]$Name, [string]$Root, [string]$Data)
        $env:GIT_CONFIG_GLOBAL = Join-Path $Root '.gitconfig'
        $env:USERPROFILE = Join-Path $Root 'home'
        $env:Data = $Data
        try {
            $out = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $script:Dir "$Name.ps1") *>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        } finally {
            $env:GIT_CONFIG_GLOBAL = $script:SavedGitConfig
            $env:USERPROFILE = $script:SavedProfile
            $env:Data = $script:SavedData
        }
    }
    function Get-GlobalConfig([string]$Root, [string[]]$Arguments) {
        $env:GIT_CONFIG_GLOBAL = Join-Path $Root '.gitconfig'
        try { git config --global @Arguments } finally { $env:GIT_CONFIG_GLOBAL = $script:SavedGitConfig }
    }
}

Describe 'Git set-up scripts (#563)' -Tag 'Light', 'Git' {
    BeforeEach {
        $script:SavedGitConfig = $env:GIT_CONFIG_GLOBAL
        $script:SavedProfile = $env:USERPROFILE
        $script:SavedData = $env:Data
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) "git-setup-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'home') -Force | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Global Git settings sets push.default and core.autocrlf, and a second run changes nothing' {
        (Invoke-SetupScript -Name 'GitGlobalSettings' -Root $script:Root).ExitCode | Should -Be 0
        $first = Get-Content -Raw (Join-Path $script:Root '.gitconfig')
        (Invoke-SetupScript -Name 'GitGlobalSettings' -Root $script:Root).ExitCode | Should -Be 0
        Get-GlobalConfig $script:Root '--get', 'push.default' | Should -Be 'simple'
        Get-GlobalConfig $script:Root '--get', 'core.autocrlf' | Should -Be 'input'
        Get-Content -Raw (Join-Path $script:Root '.gitconfig') | Should -BeExactly $first
    }

    It 'Debug diff tools registers both difftools' {
        (Invoke-SetupScript -Name 'GitDebugDiffTools' -Root $script:Root).ExitCode | Should -Be 0
        (Invoke-SetupScript -Name 'GitDebugDiffTools' -Root $script:Root).ExitCode | Should -Be 0
        Get-GlobalConfig $script:Root '--get', 'difftool.debug-powershell.cmd' | Should -Match 'REMOTE='
        Get-GlobalConfig $script:Root '--get', 'difftool.debug-cmd.exe.cmd' | Should -Match 'REMOTE='
    }

    It 'Commit identity fills an unset identity' {
        (Invoke-SetupScript -Name 'GitCommitIdentity' -Root $script:Root).ExitCode | Should -Be 0
        Get-GlobalConfig $script:Root '--get', 'user.name' | Should -Be 'Mark Michaelis'
    }

    It 'Commit identity never replaces an identity already set' {
        Get-GlobalConfig $script:Root 'user.email', 'someone@example.test'
        (Invoke-SetupScript -Name 'GitCommitIdentity' -Root $script:Root).ExitCode | Should -Be 0
        Get-GlobalConfig $script:Root '--get', 'user.email' | Should -Be 'someone@example.test'
    }

    Context 'Share Git settings from Data' {
        It 'does nothing while $env:Data is not set' {
            $r = Invoke-SetupScript -Name 'GitShareDataSettings' -Root $script:Root -Data ''
            $r.ExitCode | Should -Be 0
            Get-GlobalConfig $script:Root '--get-all', 'include.path' | Should -BeNullOrEmpty
            $r.Output | Should -Match 'Data is not set'
        }

        It 'includes Data\Profile\.gitconfig once, however often it runs' {
            $data = Join-Path $script:Root 'Data'
            New-Item -ItemType Directory -Path (Join-Path $data 'Profile') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $data 'Profile\.gitconfig') -Value "[alias]`n    shared-alias = status"
            (Invoke-SetupScript -Name 'GitShareDataSettings' -Root $script:Root -Data $data).ExitCode | Should -Be 0
            (Invoke-SetupScript -Name 'GitShareDataSettings' -Root $script:Root -Data $data).ExitCode | Should -Be 0
            @(Get-GlobalConfig $script:Root '--get-all', 'include.path') | Should -Be @((Join-Path $data 'Profile\.gitconfig'))
            # The include works: the shared alias resolves through it.
            Get-GlobalConfig $script:Root '--includes', '--get', 'alias.shared-alias' | Should -Be 'status'
        }

        It 'refuses to include the global config itself (the old hard link), which would recurse' {
            $data = Join-Path $script:Root 'Data'
            New-Item -ItemType Directory -Path (Join-Path $data 'Profile') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Root '.gitconfig') -Value "[core]`n    autocrlf = input"
            New-Item -ItemType HardLink -Path (Join-Path $data 'Profile\.gitconfig') -Target (Join-Path $script:Root '.gitconfig') | Out-Null
            $r = Invoke-SetupScript -Name 'GitShareDataSettings' -Root $script:Root -Data $data
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'hard link'
            Get-GlobalConfig $script:Root '--get-all', 'include.path' | Should -BeNullOrEmpty
        }
    }

    Context 'Link ~\.ssh to Data' {
        It 'does nothing while $env:Data is not set' {
            $r = Invoke-SetupScript -Name 'GitLinkSshToData' -Root $script:Root -Data ''
            $r.ExitCode | Should -Be 0
            Test-Path (Join-Path $script:Root 'home\.ssh') | Should -BeFalse
        }

        It 'links ~\.ssh to Data\Profile\.ssh, and a second run keeps the link' {
            $data = Join-Path $script:Root 'Data'
            New-Item -ItemType Directory -Path (Join-Path $data 'Profile\.ssh') -Force | Out-Null
            (Invoke-SetupScript -Name 'GitLinkSshToData' -Root $script:Root -Data $data).ExitCode | Should -Be 0
            (Invoke-SetupScript -Name 'GitLinkSshToData' -Root $script:Root -Data $data).ExitCode | Should -Be 0
            $link = Get-Item -LiteralPath (Join-Path $script:Root 'home\.ssh')
            $link.LinkType | Should -Be 'Junction'
            $link.Target | Should -Be (Join-Path $data 'Profile\.ssh')
        }

        It 'leaves an existing ~\.ssh folder alone' {
            $data = Join-Path $script:Root 'Data'
            New-Item -ItemType Directory -Path (Join-Path $data 'Profile\.ssh') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:Root 'home\.ssh') -Force | Out-Null
            $r = Invoke-SetupScript -Name 'GitLinkSshToData' -Root $script:Root -Data $data
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'already exists'
            (Get-Item -LiteralPath (Join-Path $script:Root 'home\.ssh')).LinkType | Should -BeNullOrEmpty
        }
    }
}
