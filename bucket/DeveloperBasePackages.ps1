$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Refs:
#   #14/#46  BeyondCompare: winget MSIX is user-scope only -> scoop extras
#   #73      copilot completion via PSCompletions (no native PS completion command)

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'dotnet'
        Installer   = 'scoop'
        Id          = 'main/dotnet'
        CliCommands = @('dotnet')
        Completion  = 'auto'
        NativeCompletionKind = 'native'
        Notes       = 'Sources tab completion from the official `dotnet complete` API (https://learn.microsoft.com/en-us/dotnet/core/tools/enable-tab-autocomplete) instead of the third-party PSCompletions catalog so completions track whatever subcommands the installed SDK ships. Hand-curated ExpectedCompletions covers the canonical top-level verbs the test harness validates.'
        ExpectedCompletions = @{ dotnet = @('add','build','clean','pack','publish','restore','run','test') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    dotnet complete --position `$cursorPosition "`$commandAst" |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
        }
}
"@
        }
    }
    [Package]@{
        Name        = 'Visual Studio'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/VisualStudio2026Enterprise'
        CliCommands = @('devenv')
        Completion  = 'auto'
        Notes       = 'devenv has no completion subcommand and no PSCompletions entry; hand-curated common-options list from `devenv /?`.'
        ExpectedCompletions = @{ devenv = @('/Build','/Run','/Edit') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName devenv -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '/Build','/Clean','/Rebuild','/Deploy','/Run','/RunExit','/Edit','/Diff','/Merge',
        '/Out','/Log','/Command','/SafeMode','/ResetSettings','/ResetUserData','/ResetSkipPkgs',
        '/InstallVSTemplates','/Setup','/NoSplash','/Project','/ProjectConfig','/Help','/?',
        '/Upgrade','/UseEnv'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'Beyond Compare'
        Installer   = 'scoop'
        Id          = 'extras/beyondcompare'
        CliCommands = @('bcomp','bcompare')
        Completion  = 'auto'
        Notes       = 'Keep scoop default bcomp shim (BComp.exe, GUI launcher). Add a separate bcomp.com shim for BComp.com (console-waiting variant) so git/scripted callers can request blocking semantics on demand. Refs #14/#46. Neither bcomp nor bcompare has a completion subcommand or PSCompletions entry; hand-curated shared flag list.'
        ExpectedCompletions = @{
            bcomp    = @('/?','/closescript','/silent')
            bcompare = @('/?','/closescript','/silent')
        }
        NativeCommandScript = {
            @"
@('bcomp','bcompare') | ForEach-Object {
    `$cli = `$_
    Register-ArgumentCompleter -Native -CommandName `$cli -ScriptBlock {
        param(`$wordToComplete, `$commandAst, `$cursorPosition)
        @(
            '/?','/help','/silent','/closescript','/automerge','/reviewconflicts',
            '/title1','/title2','/title3','/lefttitle','/centertitle','/righttitle',
            '/savetarget','/expandall','/leftreadonly','/centerreadonly','/rightreadonly',
            '/qc','/quickcompare','/edit','/snapshot','/fv','/iv'
        ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
        }
    }
}
"@
        }
        PostInstallScript = {
            try {
                $dir = (& scoop prefix beyondcompare 2>$null | Select-Object -First 1)
                $bcompCom = if ($dir) { Join-Path $dir 'BComp.com' } else { $null }
                if ($bcompCom -and (Test-Path $bcompCom)) {
                    # Drop any prior bcomp.com shim before re-adding so the
                    # PostInstallScript stays idempotent across re-runs.
                    & scoop shim rm bcomp.com 2>&1 | Out-Null
                    & scoop shim add bcomp.com $bcompCom 2>&1 | ForEach-Object { Write-Host "  $_" }
                }
            } catch {
                Write-Warning "Beyond Compare bcomp.com shim setup failed: $($_.Exception.Message)"
            }
        }
    }

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

    [Package]@{
        Name        = 'Visual Studio Code'
        Installer   = 'winget'
        Id          = 'Microsoft.VisualStudioCode'
        CliCommands = @('code')
        Completion  = 'auto'
        Notes       = '`code --help` lists CLI switches but `code` has no completion subcommand and no PSCompletions catalog entry. Hand-curated flag list (mirrors OSBasePackages).'
        ExpectedCompletions = @{ code = @('--help','--diff','--new-window') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName code -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--diff','--merge','--add','--goto','--new-window','--reuse-window',
        '--wait','--locale','--user-data-dir','--profile','--extensions-dir','--list-extensions',
        '--install-extension','--uninstall-extension','--enable-proposed-api','--status',
        '--prof-startup','--disable-extensions','--disable-extension','--sync','--inspect-extensions',
        '--inspect-brk-extensions','--verbose','--log','--telemetry'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'GitHub Copilot CLI'
        Installer   = 'winget'
        Id          = 'GitHub.Copilot'
        CliCommands = @('copilot')
        Completion  = 'auto'
        Notes       = '`copilot completion` only supports bash/zsh/fish; not in PSCompletions catalog (#73). Hand-curated top-level flag/command list.'
        ExpectedCompletions = @{ copilot = @('--help','--version','--model') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName copilot -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--model','--prompt','--allow-tool','--deny-tool',
        '--allow-all-tools','--add-dir','--no-color','--banner','--resume','--continue',
        '--screen-reader','--log-level','--log-dir','-p','--allow-all-paths'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'Python'
        Installer   = 'winget'
        Id          = 'Python.Python.3.14'
        CliCommands = @('python')
        Completion  = 'auto'
        Notes       = 'CPython ships no native PowerShell completion provider and the PSCompletions catalog entry is opaque (depends on a network catalog fetch). Hand-curated CPython CLI flag list -- deterministic, hermetic, and consistent with devenv/code/copilot/aspire in the same bundle (#229).'
        ExpectedCompletions = @{ python = @('-c','-m','-V','--version','-h','--help') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName python -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '-c','-m','-i','-u','-V','--version','-h','--help',
        '-O','-OO','-q','-s','-S','-v','-W','-x',
        '-b','-B','-d','-E','-I','-P','-R'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }

    [Package]@{
        Name        = 'Android Platform Tools'
        Installer   = 'scoop'
        Id          = 'main/adb'
        CliCommands = @('adb','fastboot')
        Completion  = 'auto'
        Notes       = 'Android SDK platform-tools (adb/fastboot). scoop main/adb shims adb.exe and fastboot.exe automatically. Neither adb nor fastboot ships a `completions powershell` subcommand or a PSCompletions entry, so the completer is hand-curated (curated, not native -- #289/#293). Subcommand lists drawn from `adb --help` and `fastboot --help`.'
        ExpectedCompletions = @{
            adb      = @('devices','install','shell','logcat')
            fastboot = @('devices','flash','reboot')
        }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName adb -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'devices','help','version','connect','disconnect','pair','push','pull','sync',
        'shell','install','install-multiple','uninstall','logcat','forward','reverse',
        'reboot','sideload','root','unroot','remount','bugreport','backup','restore',
        'kill-server','start-server','get-state','get-serialno','wait-for-device','tcpip','emu',
        '-s','-d','-e','-H','-P','-a'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
Register-ArgumentCompleter -Native -CommandName fastboot -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'devices','flash','flashall','erase','format','getvar','boot','reboot',
        'reboot-bootloader','continue','update','set_active','oem','flashing',
        '--help','--version','-w','-s'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }

    [Package]@{
        Name        = 'Aspire'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/Aspire'
        CliCommands = @('aspire')
        DependsOn   = @('dotnet','Visual Studio')
        Completion  = 'auto'
        Notes       = 'Bundle manifest invokes `dotnet tool install --global Aspire.Cli` + project templates. DependsOn ensures dotnet+VS are in place first. aspire has no completion subcommand and no PSCompletions entry; hand-curated top-level command list (mirrors Aspire bundle).'
        ExpectedCompletions = @{ aspire = @('new','run','add') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName aspire -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'new','run','add','publish','deploy','exec','config','update','--help','--version',
        '-h','--debug','--cli-version','--wait-for-debugger'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'DeveloperBasePackages'
