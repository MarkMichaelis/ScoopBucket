#requires -Version 7.0
# See OSBasePackages.ps1: stops scoop recording a failed install (#504).

#region MarkMichaelis.ScoopBucket bundle module import (scoop-portable; see README)
$scoopBucketModule = 'MarkMichaelis.ScoopBucket'
$scoopBucketPsd1 = Join-Path $PSScriptRoot "..\module\$scoopBucketModule\$scoopBucketModule.psd1"
if (-not (Test-Path $scoopBucketPsd1)) {
    $scoopBucketRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $PSScriptRoot '..\..\..' }
    $scoopBucketFound = Get-ChildItem -Path (Join-Path $scoopBucketRoot "buckets\*\module\$scoopBucketModule\$scoopBucketModule.psd1") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($scoopBucketFound) { $scoopBucketPsd1 = $scoopBucketFound.FullName }
}
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module $scoopBucketModule -Force }
#endregion MarkMichaelis.ScoopBucket bundle module import

# Git Tools (#563): Git and its set-up, plus the Git clients. Developer Base
# installs it, and the picker shows it only there. It replaces the
# GitConfigure manifest, split into items that can each be turned off.
#
# Git itself, with its set-up items as companions, is declared once in
# SharedPackages.ps1: OS Base shows the same package.

$Packages = [Package[]]@(
    & "$PSScriptRoot\SharedPackages.ps1" -Name 'Git'
    [Package]@{
        Name      = 'posh-git'
        Installer = 'scoop'
        Id        = 'MarkMichaelis/PoshGit'
        # posh-git's profile line starts ssh-agent (Start-SshAgent), which
        # needs the ssh-agent service enabled.
        DependsOn = @('ssh-agent')
    }
    [Package]@{ Name = 'Commit identity'; Installer = 'scoop'; Id = 'MarkMichaelis/GitCommitIdentity' }

    # gh aliases plus `gh auth setup-git` (#434); installed with the GitHub CLI.
    [Package]@{ Name = 'GitHub CLI settings'; Installer = 'scoop'; Id = 'MarkMichaelis/GitConfigGitHubCli' }
    [Package]@{
        Name        = 'GitHub CLI'
        Installer   = 'winget'
        Id          = 'GitHub.cli'
        Companions  = @('GitHub CLI settings')
        CliCommands = @('gh')
        Completion  = 'native'
        NativeCompletionKind = 'native'
        NativeCommandScript  = { gh completion -s powershell }
        ExpectedCompletions  = @{ gh = @('auth','pr','repo') }
        Notes       = 'GitHub''s CLI, machine scope. Completion is the binary''s own cobra completer (`gh completion -s powershell`).'
    }

    [Package]@{
        Name        = 'GitKraken CLI'
        Installer   = 'winget'
        Id          = 'GitKraken.cli'
        CliCommands = @('gk')
        Completion  = 'native'
        NativeCompletionKind = 'native'
        # cobra-based: the shell is a positional argument, not gh's `-s`.
        NativeCommandScript  = { gk completion powershell }
        ExpectedCompletions  = @{ gk = @('auth','issue','work') }
    }
    [Package]@{
        Name       = 'GitKraken'
        Installer  = 'choco'
        Id         = 'gitkraken'
        Companions = @('GitKraken CLI')
        Notes      = 'Chocolatey because its package is a system-wide install into C:\Program Files with a system shim; the winget and scoop packages are per-user.'
    }
    [Package]@{ Name = 'Git Extensions'; Installer = 'choco'; Id = 'gitextensions' }

    [Package]@{
        Name        = 'Lazygit'
        Installer   = 'winget'
        Id          = 'JesseDuffield.lazygit'
        CliCommands = @('lazygit')
        Completion  = 'auto'
        Notes       = 'lazygit is a terminal UI for git; its CLI surface is a small set of setup flags (no `lazygit completion powershell` subcommand and no PSCompletions catalog entry). Hand-curated flag list mirrors bat/fzf/code in the bucket.'
        ExpectedCompletions = @{ lazygit = @('--help','--version','--config') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName lazygit -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','-h','--version','-v','--debug','-d','--config','-c',
        '--print-config-dir','-cd','--use-config-dir','-ucd','--path','-p',
        '--filter','-f','--git-dir','-g','--work-tree','-w','--screen-mode','-sm',
        '--profile','-pf','--tail','-t'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'GitTools'
