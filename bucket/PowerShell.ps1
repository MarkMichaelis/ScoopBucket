
Write-Host 'Installing and configuring PowerShell...'
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

Update-Help -ErrorAction Ignore
if((Get-PSRepository PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy 'Trusted'
}
Install-Module PowershellGet -Repository PSGallery -Scope AllUsers  # Updated to allow support for -AllowPrerelease
Install-Module Pscx -AllowClobber -AllowPrerelease -Scope AllUsers  # Both Pscx and IntelliTect.File support Edit-File. 
                                                                    # IntelliTect.File will get priority once if it appears first in the PSModulePath
                                                                    # or it is installed after Pscx (if not using source code)
Install-Module ZLocation -Repository PSGallery -Scope AllUsers
Install-Module PSReadLine -Force -Scope AllUsers   # Update the version of PSReadline
Install-Module Microsoft.PowerShell.SecretManagement -Scope AllUsers
Install-Module WinGet-Essentials -Repository PSGallery -Scope AllUsers
Install-Module Microsoft.PowerShell.ConsoleGuiTools -Repository PSGallery -Scope AllUsers
choco install Pester

# Install Scott Hanselman's Windows Terminal Copilot CLI skill
# (sets tab title/color from inside Copilot CLI via !tab commands).
# Repo: https://github.com/shanselman/windows-terminal-copilot-skill
if (Get-Command git -ErrorAction Ignore) {
    $skillPath = Join-Path $env:USERPROFILE '.copilot\skills\windows-terminal'
    if (Test-Path (Join-Path $skillPath '.git')) {
        git -C $skillPath pull --quiet
    } else {
        New-Item -ItemType Directory -Path (Split-Path $skillPath -Parent) -Force | Out-Null
        git clone --quiet https://github.com/shanselman/windows-terminal-copilot-skill.git $skillPath
    }
    $importLine = 'Import-Module "$env:USERPROFILE\.copilot\skills\windows-terminal\WindowsTerminalSkill.psd1"'
    if (-not (Test-Path $PROFILE)) {
        New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    }
    if (-not (Select-String -Path $PROFILE -Pattern 'WindowsTerminalSkill\.psd1' -SimpleMatch -Quiet)) {
        Add-Content -Path $PROFILE -Value $importLine
    }
} else {
    Write-Warning 'git not found; skipping windows-terminal-copilot-skill install.'
}

# ----------------------------------------------------------------------------
# Native PowerShell tab-completion for the PowerShell hosts and wsl (#278).
#
# Neither `pwsh`, `powershell`, nor `wsl` ships a `<cli> completion powershell`
# subcommand, so each gets a hand-curated completer covering its documented
# top-level switches. Registration flows through Register-CliCompletion's
# self-healing path (Resolve-SelfHealingCompleter): if any of these CLIs later
# gains a real native helper, it is adopted automatically and a low-priority
# advisory notes this block can be removed. Best-effort -- skipped with a
# warning when the AllUsersAllHosts profile is not writable (e.g. not elevated),
# matching gh.
# ----------------------------------------------------------------------------
function New-StaticNativeCompleter {
    # Build a scriptblock that emits a hand-curated `Register-ArgumentCompleter
    # -Native` here-string for $Cli over a fixed $Switches list. Returned as a
    # closure so Register-CliCompletion captures the rendered text verbatim.
    param([string]$Cli, [string[]]$Switches)
    $switchLiteral = ($Switches | ForEach-Object { "'$_'" }) -join ','
    $completerText = @"
Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @($switchLiteral) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
    return { $completerText }.GetNewClosure()
}

$pwshSwitches = @(
    '-File', '-Command', '-EncodedCommand', '-ConfigurationName', '-CustomPipeName',
    '-ExecutionPolicy', '-InputFormat', '-OutputFormat', '-Login', '-MTA', '-STA',
    '-NoExit', '-NoLogo', '-NoProfile', '-NoProfileLoadTime', '-NonInteractive',
    '-SettingsFile', '-Version', '-WindowStyle', '-WorkingDirectory', '-Help'
)
try {
    Register-CliCompletion -Cli pwsh -NativeCommand (New-StaticNativeCompleter -Cli pwsh -Switches $pwshSwitches) -Force -Confirm:$false -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "Skipping pwsh tab-completion registration: $($_.Exception.Message)"
}

$powershellSwitches = @(
    '-File', '-Command', '-EncodedCommand', '-ConfigurationName', '-ExecutionPolicy',
    '-InputFormat', '-OutputFormat', '-Mta', '-Sta', '-NoExit', '-NoLogo', '-NoProfile',
    '-NonInteractive', '-PSConsoleFile', '-Version', '-WindowStyle', '-Help'
)
try {
    Register-CliCompletion -Cli powershell -NativeCommand (New-StaticNativeCompleter -Cli powershell -Switches $powershellSwitches) -Force -Confirm:$false -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "Skipping powershell tab-completion registration: $($_.Exception.Message)"
}

$wslSwitches = @(
    '--install', '--list', '-l', '--set-default', '-s', '--set-version',
    '--set-default-version', '--shutdown', '--terminate', '-t', '--unregister',
    '--import', '--export', '--distribution', '-d', '--user', '-u', '--exec', '-e',
    '--status', '--update', '--help'
)
try {
    Register-CliCompletion -Cli wsl -NativeCommand (New-StaticNativeCompleter -Cli wsl -Switches $wslSwitches) -Force -Confirm:$false -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "Skipping wsl tab-completion registration: $($_.Exception.Message)"
}

# scoop tab-completion via the upstream `scoop-completion` module (#278). scoop
# has no `scoop completion powershell` subcommand; its completer is shipped as a
# PowerShell module installed through scoop itself. Install (best-effort) and
# add an idempotent import to the CurrentUserAllHosts profile so it loads in
# every host.
try {
    if (-not (Get-Module -ListAvailable -Name scoop-completion)) {
        scoop install scoop-completion
    }
    $allHostsProfile = $PROFILE.CurrentUserAllHosts
    if (-not (Test-Path $allHostsProfile)) {
        New-Item -ItemType File -Path $allHostsProfile -Force | Out-Null
    }
    if (-not (Select-String -Path $allHostsProfile -Pattern 'Import-Module\s+scoop-completion' -Quiet)) {
        Add-Content -Path $allHostsProfile -Value 'Import-Module scoop-completion'
    }
} catch {
    Write-Warning "Skipping scoop-completion activation: $($_.Exception.Message)"
}




