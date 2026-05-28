[CmdletBinding()]
param(
    # When set, prune any MCP server names this bucket has retired
    # (see $DeprecatedMcpServers below) from existing user MCP configs.
    # Off by default so a routine `scoop install` / reinstall never removes
    # entries the user may still rely on. Intended for direct invocation:
    #   pwsh -File AIAgents.ps1 -Reset
    [switch]$Reset
)

Write-Host 'Installing and configuring AIAgents...'
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# ---------------------------------------------------------------------------
# Package list.
#
# AIAgents owns:
#   - the agent apps themselves (Claude Desktop + every chat/CLI agent we
#     publish a bucket manifest for)
#   - the runtimes those MCP servers need at runtime (Node.js so `npx` is on
#     PATH; PoshMcp pulled in via dotnetTool when the .NET SDK is present)
# The MCP-server JSON/TOML wiring is config state, not a package, so it
# runs as a tail block below.
# ---------------------------------------------------------------------------

$Packages = [Package[]]@(
    # Runtime prerequisites first so MCP-server entries written below
    # actually resolve at agent start-up. DependsOn pulls these in
    # transitively when -Name selects an agent.
    [Package]@{
        Name        = 'Node.js'
        Installer   = 'choco'
        Id          = 'nodejs'
        CliCommands = @('node','npm','npx')
        Completion  = 'auto'
        Notes       = 'Required for every npx-based MCP server (context7, playwright, filesystem, github). node/npm have PSCompletions entries but npx does not, so ship a shared hand-curated NativeCommandScript that registers all three uniformly here.'
        ExpectedCompletions = @{
            node = @('--help','--version','--eval')
            npm  = @('install','run','version')
            npx  = @('--help','--version','--package')
        }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName node -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--eval','--print','--check','--interactive','--require','--inspect',
        '--inspect-brk','--enable-source-maps','--experimental-modules','--experimental-vm-modules',
        '--unhandled-rejections','--use-openssl-ca','--no-warnings','--trace-warnings'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
Register-ArgumentCompleter -Native -CommandName npm -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'install','uninstall','update','run','start','test','version','init','publish','pack',
        'config','cache','audit','outdated','ls','list','link','unlink','search','view','prune',
        'rebuild','restart','stop','adduser','login','logout','whoami','--help','--version'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
Register-ArgumentCompleter -Native -CommandName npx -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--package','--call','--no-install','--ignore-existing','--yes','--no',
        '--shell','--cache','--prefer-offline','--prefer-online','--offline','--quiet','--verbose'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }

    # Agent apps.
    [Package]@{
        Name        = 'Claude Desktop'
        Installer   = 'winget'
        Id          = 'Anthropic.Claude'
        # Anthropic ships Claude Desktop in two flavors: a machine-context MSIX
        # (requires the runFullTrust restricted capability, only honored on
        # interactive Windows desktop sessions with sideloading enabled) and a
        # user-scope EXE. On headless Windows Server hosted CI runners winget's
        # default MSIX selection fails with APPINSTALLER_CLI_ERROR_INSTALL_SYSTEM_NOT_SUPPORTED
        # (-1978334957). Forcing --scope user routes winget to the EXE installer,
        # which is also Anthropic's actual deployment model (per-user app under
        # %LOCALAPPDATA%\AnthropicClaude). See #85.
        Scope       = 'user'
        Notes       = 'MCP-capable desktop client. Local Claude.json manifest also installs this via winget; keeping the declarative entry here is the canonical home for the package.'
    }
    [Package]@{
        Name      = 'ChatGPT'
        Installer = 'scoop'
        Id        = 'MarkMichaelis/ChatGPT'
    }
    [Package]@{
        Name      = 'Gemini'
        Installer = 'scoop'
        Id        = 'MarkMichaelis/Gemini'
        Companions = @('Gemini CLI')
        CISkip    = 'Browser-watch installer requires interactive Download click; see #25/#26.'
    }
    [Package]@{
        Name      = 'Microsoft Copilot'
        Installer = 'scoop'
        Id        = 'MarkMichaelis/MicrosoftCopilot'
    }
    [Package]@{
        Name        = 'Warp'
        Installer   = 'winget'
        Id          = 'Warp.Warp'
        # Warp ships only a per-user installer on Windows (drops warp.exe at
        # %LOCALAPPDATA%\Programs\Warp\warp.exe). Force --scope user so winget
        # doesn't fall back to a machine-context selection that fails on
        # headless CI runners (mirrors the Claude Desktop note above).
        Scope       = 'user'
        # Warp ships a Squirrel-based installer that pops a progress
        # window during install. --silent suppresses that installer UI,
        # and --disable-interactivity keeps winget itself non-interactive
        # so headless / CI runs do not stall on prompts.
        WingetExtraArgs = @('--silent', '--disable-interactivity')
        # Two surfaces from a single binary:
        #   * `warp` — launches the Warp terminal UI (GUI) when run bare,
        #              or the embedded Oz CLI when run with subcommands.
        #   * `oz`   — Warp's canonical CLI name per
        #              docs.warp.dev/reference/cli, used in every CLI
        #              example in Warp's own docs (`oz agent run`,
        #              `oz mcp`, `oz whoami`, etc.). On Windows Warp's
        #              "Install Oz CLI Command" Command Palette action
        #              normally creates this alias; PostInstallScript
        #              below mirrors that headlessly.
        CliCommands = @('warp','oz')
        Completion  = 'auto'
        Notes       = 'Agentic AI terminal (warp.dev). One binary, two exposed entry points: `warp` (UI + CLI passthrough) and `oz` (the canonical "Oz CLI" used in Warp''s docs for agent / MCP / run management). The winget installer drops warp.exe at %LOCALAPPDATA%\Programs\Warp\ but does NOT add it to PATH; PostInstallScript copies warp.exe -> oz.exe in-place (warp uses argv[0] to brand its --help text and Register-ArgumentCompleter target, so a rename is required — a launcher shim would leave argv[0] as warp.exe) and registers both as scoop shims, mirroring the bcomp.com pattern in DeveloperBasePackages. Tab completion is sourced from the binary itself via `warp completions powershell` / `oz completions powershell` so it tracks whatever subcommands Warp ships. MCP wiring below intentionally skips Warp: Warp manages MCP servers via its in-app Settings > Agents > MCP servers UI (its own store); use `oz mcp` from CLI if parity with the JSON/TOML-wired agents is needed.'
        ExpectedCompletions = @{
            warp = @('--help','--version','agent','mcp','run','completions')
            oz   = @('--help','--version','agent','mcp','run','completions')
        }
        NativeCommandScript = {
            @"
# Warp ships its own clap-derived PowerShell completer. Dot-source it for
# each surface so the completion catalog tracks whatever subcommands the
# installed Warp build actually supports. Warp brands the completer using
# argv[0], so warp.exe registers for `warp.exe` and oz.exe (a copy)
# registers for `oz.exe`; we invoke both. Fall back to a curated top-level
# list per command if the bundled completer is missing or returns
# something we can't recognize (e.g., Warp regressed `… completions
# powershell`, or the binary is not yet on disk when the completion
# profile is being generated).
`$warpDir = Join-Path `$env:LOCALAPPDATA 'Programs\Warp'
`$warpExe = Join-Path `$warpDir 'warp.exe'
`$ozExe   = Join-Path `$warpDir 'oz.exe'

`$fallbackTokens = @(
    '--help','--version','--api-key','--output-format','--debug',
    '--crash-recovery-mechanism',
    'agent','environment','mcp','run','model','login','logout','whoami',
    'integration','schedule','secret','federate','artifact','completions','help'
)

foreach (`$pair in @(
    @{ Cli = 'warp'; Exe = `$warpExe },
    @{ Cli = 'oz';   Exe = `$ozExe   }
)) {
    `$registered = `$false
    if (Test-Path `$pair.Exe) {
        try {
            `$script = & `$pair.Exe completions powershell 2>`$null | Out-String
            if (`$script -match 'Register-ArgumentCompleter') {
                Invoke-Expression `$script
                `$registered = `$true
            }
        } catch { }
    }
    if (-not `$registered) {
        `$cliName = `$pair.Cli
        `$tokens  = `$fallbackTokens
        Register-ArgumentCompleter -Native -CommandName `$cliName -ScriptBlock {
            param(`$wordToComplete, `$commandAst, `$cursorPosition)
            `$tokens | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
            }
        }.GetNewClosure()
    }
}
"@
        }
        PostInstallScript = {
            try {
                $warpDir = Join-Path $env:LOCALAPPDATA 'Programs\Warp'
                $warpExe = Join-Path $warpDir 'warp.exe'
                $ozExe   = Join-Path $warpDir 'oz.exe'

                if (-not (Test-Path $warpExe)) {
                    Write-Warning "Warp PostInstallScript: warp.exe not found at $warpExe; skipping shims."
                    return
                }

                # Idempotent: drop any prior shim before re-adding so this
                # PostInstallScript stays safe across re-runs / Warp upgrades.
                & scoop shim rm warp 2>&1 | Out-Null
                & scoop shim rm oz   2>&1 | Out-Null

                & scoop shim add warp $warpExe 2>&1 | ForEach-Object { Write-Host "  $_" }

                # Warp uses argv[0] to brand its --help text ("warp.exe"
                # vs. "oz.exe") AND its `completions powershell`
                # Register-ArgumentCompleter command name. A scoop shim is
                # a launcher that spawns the target process, so the
                # target's argv[0] stays warp.exe regardless of the shim
                # name. Copy warp.exe -> oz.exe in-place so `oz` users see
                # the documented branding and the completer registers
                # under the right command name. Re-copy if warp.exe has a
                # newer mtime (handles Warp self-updates).
                $needsCopy = (-not (Test-Path $ozExe)) -or `
                    ((Get-Item $warpExe).LastWriteTimeUtc -gt (Get-Item $ozExe).LastWriteTimeUtc)
                if ($needsCopy) {
                    Copy-Item $warpExe $ozExe -Force
                }

                & scoop shim add oz $ozExe 2>&1 | ForEach-Object { Write-Host "  $_" }
            } catch {
                Write-Warning "Warp shim setup failed: $($_.Exception.Message)"
            }
        }
    }
    [Package]@{
        Name        = 'Claude Code CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/ClaudeCode'
        CliCommands = @('claude')
        DependsOn   = @('Node.js')
        Completion  = 'auto'
        Notes       = 'claude has no completion subcommand and no PSCompletions entry. Hand-curated top-level command list.'
        ExpectedCompletions = @{ claude = @('--help','--version','mcp') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName claude -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--print','--continue','--resume','--model','--add-dir',
        '--allowedTools','--disallowedTools','--mcp-config','--append-system-prompt',
        '--verbose','--debug','mcp','config','update','migrate-installer','doctor'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'Codex CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/Codex'
        CliCommands = @('codex')
        DependsOn   = @('Node.js')
        Completion  = 'auto'
        Notes       = 'codex has no completion subcommand and no PSCompletions entry. Hand-curated top-level command list.'
        ExpectedCompletions = @{ codex = @('--help','--version','exec') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName codex -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--model','--config','--cd','--ask-for-approval','--sandbox',
        '--dangerously-bypass-approvals-and-sandbox','--full-auto','exec','login','logout',
        'mcp','completion','update','resume','--profile'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'Gemini CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/GeminiCli'
        CliCommands = @('gemini')
        DependsOn   = @('Node.js')
        Completion  = 'auto'
        Notes       = 'gemini has no completion subcommand and no PSCompletions entry. Hand-curated top-level command/flag list.'
        ExpectedCompletions = @{ gemini = @('--help','--version','--model') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName gemini -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--model','--prompt','--sandbox','--debug','--all-files',
        '--yolo','--checkpointing','--telemetry','--telemetry-target','--allowed-mcp-server-names',
        '--extensions','--list-extensions','mcp','--show-memory-usage'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'GitHub Copilot CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/GitHubCopilotCli'
        CliCommands = @('copilot')
        DependsOn   = @('Node.js')
        Completion  = 'auto'
        Notes       = '`copilot completion` only supports bash/zsh/fish; not in PSCompletions catalog (#73). Hand-curated top-level flag/command list (mirrors DeveloperBasePackages winget GitHub.Copilot package).'
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
)

Invoke-PackageInstall -Packages $Packages -Bundle 'AIAgents'

# ---------------------------------------------------------------------------
# MCP server prerequisites that are NOT npm-based.
# ---------------------------------------------------------------------------

# Playwright separates its browser binaries from the npm package; the MCP
# server starts cleanly without them but fails the first time an agent
# asks it to open a page. Install `@playwright/test` globally so the
# `playwright` shim lands on PATH, then install just chromium (~150 MB).
if (Get-Command npm -ErrorAction SilentlyContinue) {
    if (-not (Get-Command playwright -ErrorAction SilentlyContinue)) {
        & npm.cmd install --global '@playwright/test'
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm install --global @playwright/test exited with code $LASTEXITCODE; falling back to npx for browser install."
        }
    }
    if (Get-Command playwright -ErrorAction SilentlyContinue) {
        & playwright.cmd install chromium
    }
    else {
        & npx.cmd -y '@playwright/test' install chromium
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "playwright install chromium exited with code $LASTEXITCODE; the Playwright MCP server may fail at runtime."
    }
}
else {
    Write-Warning 'npm not found after package pass; skipping Playwright browser install.'
}

# PoshMcp ships as a .NET global tool. Skip silently if dotnet isn't on the
# machine — installing the .NET 10+ SDK from this script would be too heavy
# a side effect for a non-developer profile. DeveloperBasePackages already
# pulls the .NET SDK; users who don't run that simply won't get PoshMcp.
$PoshMcpAvailable = $false
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    Write-Host 'Installing PoshMcp dotnet global tool...'
    & dotnet tool install -g poshmcp 2>&1 | Tee-Object -Variable poshOut
    if ($LASTEXITCODE -eq 0 -or ($poshOut -join "`n") -match 'already installed') {
        $PoshMcpAvailable = $true
        $dotnetTools = Join-Path $env:USERPROFILE '.dotnet\tools'
        if ((Test-Path $dotnetTools) -and ($env:Path -notlike "*$dotnetTools*")) {
            $env:Path = "$env:Path;$dotnetTools"
        }
    }
    else {
        Write-Warning "dotnet tool install -g poshmcp failed; PoshMcp MCP server will not be configured."
    }
}
else {
    Write-Warning 'dotnet not found; skipping PoshMcp install. Install the .NET 10+ SDK (e.g., DeveloperBasePackages) and re-run AIAgents to enable PoshMcp.'
}

# Auto-detect a GitHub PAT for the GitHub MCP server. Prefer an explicit env
# var; fall back to the gh CLI's stored token if available.
$GithubToken = $env:GITHUB_PERSONAL_ACCESS_TOKEN
if ([string]::IsNullOrWhiteSpace($GithubToken) -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    try {
        $ghToken = & gh auth token 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ghToken)) {
            $GithubToken = $ghToken.Trim()
            Write-Host 'GitHub MCP: using token from `gh auth token`.'
        }
    }
    catch { }
}
if ([string]::IsNullOrWhiteSpace($GithubToken)) {
    Write-Warning 'GitHub MCP: no token found (set $env:GITHUB_PERSONAL_ACCESS_TOKEN or run `gh auth login`). The MCP entry will be written but will fail at runtime until a token is provided.'
}

# ---------------------------------------------------------------------------
# Configure MCP servers for every MCP-capable agent.
# Idempotent: re-running just overwrites the named entries; other MCP servers
# in the same config are preserved.
# ---------------------------------------------------------------------------

$DeprecatedMcpServers = @('shell')

$McpServers = @(
    @{
        Name      = 'context7'
        Command   = 'npx'
        Arguments = @('-y', '@upstash/context7-mcp')
    }
    @{
        Name      = 'playwright'
        Command   = 'npx'
        Arguments = @('-y', '@playwright/mcp@latest')
    }
    @{
        Name      = 'filesystem'
        Command   = 'npx'
        Arguments = @('-y', '@modelcontextprotocol/server-filesystem', $env:USERPROFILE)
    }
    @{
        Name      = 'github'
        Command   = 'npx'
        Arguments = @('-y', '@modelcontextprotocol/server-github')
        Env       = @{ GITHUB_PERSONAL_ACCESS_TOKEN = $GithubToken }
    }
)

if ($PoshMcpAvailable) {
    $McpServers += @{
        Name      = 'posh'
        Command   = 'poshmcp'
        Arguments = @('serve', '--transport', 'stdio')
    }
}

Function Add-McpServerToJsonConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AgentLabel,
        [Parameter(Mandatory)][hashtable]$Server
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path $Path) {
        try {
            $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "$AgentLabel`: existing config at $Path is not valid JSON; skipping $($Server.Name)."
            return
        }
    }
    else {
        $config = [pscustomobject]@{}
    }

    if (-not $config.PSObject.Properties['mcpServers']) {
        $config | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
    }

    $entry = [pscustomobject]@{
        command = $Server.Command
        args    = $Server.Arguments
    }
    if ($Server.ContainsKey('Env') -and $Server.Env -and $Server.Env.Count -gt 0) {
        $envObj = [pscustomobject]@{}
        foreach ($k in $Server.Env.Keys) {
            $val = $Server.Env[$k]
            if ($null -eq $val) { $val = '' }
            $envObj | Add-Member -NotePropertyName $k -NotePropertyValue $val
        }
        $entry | Add-Member -NotePropertyName env -NotePropertyValue $envObj
    }

    if ($config.mcpServers.PSObject.Properties[$Server.Name]) {
        $config.mcpServers.($Server.Name) = $entry
    }
    else {
        $config.mcpServers | Add-Member -NotePropertyName $Server.Name -NotePropertyValue $entry
    }

    $config | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
    Write-Host "$AgentLabel`: configured $($Server.Name) MCP in $Path"
}

Function Add-McpServerToCodex {
    param(
        [Parameter(Mandatory)][hashtable]$Server
    )

    $path = Join-Path $env:USERPROFILE '.codex\config.toml'
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # TOML basic strings interpret backslash as an escape character. Any
    # raw Windows path like 'C:\Users\Mark' contains '\U' which the TOML
    # parser tries to consume as a \UXXXXXXXX Unicode escape and fails
    # with "too few unicode value digits". Escape backslashes (\ -> \\)
    # and double-quotes (" -> \") in every interpolated value.
    #
    # Note on PowerShell -replace replacement strings: in .NET regex
    # replacement, '$' is special but '\' is literal. So replacement
    # '\\' (2 chars) emits 2 chars '\\', and replacement '\"' emits '\"'.
    $argsToml = ($Server.Arguments | ForEach-Object {
        $esc = $_ -replace '\\','\\' -replace '"','\"'
        '"' + $esc + '"'
    }) -join ', '
    $cmdEsc = $Server.Command -replace '\\','\\' -replace '"','\"'
    $section = @"
[mcp_servers.$($Server.Name)]
command = "$cmdEsc"
args = [$argsToml]
"@
    if ($Server.ContainsKey('Env') -and $Server.Env -and $Server.Env.Count -gt 0) {
        $envLines = foreach ($k in $Server.Env.Keys) {
            $v = $Server.Env[$k]
            if ($null -eq $v) { $v = '' }
            $vEsc = $v -replace '\\','\\' -replace '"','\"'
            "$k = `"$vEsc`""
        }
        $section += "`r`n[mcp_servers.$($Server.Name).env]`r`n" + ($envLines -join "`r`n")
    }

    $sectionPattern    = "(?ms)^\[mcp_servers\.$([regex]::Escape($Server.Name))\].*?(?=^\[|\z)"
    $envSectionPattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($Server.Name))\.env\].*?(?=^\[|\z)"

    if (Test-Path $path) {
        $content = Get-Content -Path $path -Raw
        $content = [regex]::Replace($content, $envSectionPattern, '')
        $content = [regex]::Replace($content, $sectionPattern, '')
        $content = $content.TrimEnd() + "`r`n`r`n" + $section + "`r`n"
        Set-Content -Path $path -Value $content -Encoding UTF8
    }
    else {
        Set-Content -Path $path -Value ($section + "`r`n") -Encoding UTF8
    }
    Write-Host "Codex CLI: configured $($Server.Name) MCP in $path"
}

$JsonAgents = @(
    @{ Label = 'Claude Desktop';      Path = (Join-Path $env:APPDATA      'Claude\claude_desktop_config.json') }
    @{ Label = 'Claude Code CLI';     Path = (Join-Path $env:USERPROFILE  '.claude.json') }
    @{ Label = 'Gemini CLI';          Path = (Join-Path $env:USERPROFILE  '.gemini\settings.json') }
    @{ Label = 'GitHub Copilot CLI';  Path = (Join-Path $env:USERPROFILE  '.copilot\mcp-config.json') }
)

Function Remove-McpServerFromJsonConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AgentLabel,
        [Parameter(Mandatory)][string]$ServerName
    )

    if (-not (Test-Path $Path)) { return }
    try {
        $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "$AgentLabel`: existing config at $Path is not valid JSON; skipping prune of $ServerName."
        return
    }
    if (-not $config.PSObject.Properties['mcpServers']) { return }
    if (-not $config.mcpServers.PSObject.Properties[$ServerName]) { return }

    $config.mcpServers.PSObject.Properties.Remove($ServerName)
    $config | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
    Write-Host "$AgentLabel`: pruned deprecated $ServerName MCP from $Path"
}

Function Remove-McpServerFromCodex {
    param(
        [Parameter(Mandatory)][string]$ServerName
    )

    $path = Join-Path $env:USERPROFILE '.codex\config.toml'
    if (-not (Test-Path $path)) { return }

    $sectionPattern    = "(?ms)^\[mcp_servers\.$([regex]::Escape($ServerName))\].*?(?=^\[|\z)"
    $envSectionPattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($ServerName))\.env\].*?(?=^\[|\z)"

    $content    = Get-Content -Path $path -Raw
    $newContent = [regex]::Replace($content, $envSectionPattern, '')
    $newContent = [regex]::Replace($newContent, $sectionPattern, '')
    if ($newContent -ne $content) {
        Set-Content -Path $path -Value $newContent.TrimEnd() -Encoding UTF8
        Write-Host "Codex CLI: pruned deprecated $ServerName MCP from $path"
    }
}

foreach ($server in $McpServers) {
    foreach ($agent in $JsonAgents) {
        Add-McpServerToJsonConfig -Path $agent.Path -AgentLabel $agent.Label -Server $server
    }
    Add-McpServerToCodex -Server $server
}

if ($Reset) {
    Write-Host "-Reset: pruning deprecated MCP server names ($($DeprecatedMcpServers -join ', '))..."
    foreach ($name in $DeprecatedMcpServers) {
        foreach ($agent in $JsonAgents) {
            Remove-McpServerFromJsonConfig -Path $agent.Path -AgentLabel $agent.Label -ServerName $name
        }
        Remove-McpServerFromCodex -ServerName $name
    }
}

# Tab-completion registration: idempotent best-effort. Skipped (with a
# warning) when the session isn't elevated so a normal scoop reinstall
# still succeeds for users without admin rights.
try {
    Invoke-CliCompletionsSweep -Force -Confirm:$false -ErrorAction Stop | Out-Null
}
catch {
    Write-Warning "Skipping CLI tab-completion registration: $($_.Exception.Message)"
}
