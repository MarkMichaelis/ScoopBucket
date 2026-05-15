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
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\ScoopBucket\ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module ScoopBucket -Force }

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
        Notes       = 'Required for every npx-based MCP server (context7, playwright, filesystem, github).'
    }

    # Agent apps.
    [Package]@{
        Name        = 'Claude Desktop'
        Installer   = 'winget'
        Id          = 'Anthropic.Claude'
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
        CISkip    = 'Browser-watch installer requires interactive Download click; see #25/#26.'
    }
    [Package]@{
        Name      = 'Microsoft Copilot'
        Installer = 'scoop'
        Id        = 'MarkMichaelis/MicrosoftCopilot'
    }
    [Package]@{
        Name        = 'Claude Code CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/ClaudeCode'
        CliCommands = @('claude')
        DependsOn   = @('Node.js')
    }
    [Package]@{
        Name        = 'Codex CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/Codex'
        CliCommands = @('codex')
        DependsOn   = @('Node.js')
    }
    [Package]@{
        Name        = 'Gemini CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/GeminiCli'
        CliCommands = @('gemini')
        DependsOn   = @('Node.js')
    }
    [Package]@{
        Name        = 'GitHub Copilot CLI'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/GitHubCopilotCli'
        CliCommands = @('copilot')
        Completion  = 'pscompletions'
        DependsOn   = @('Node.js')
        Notes       = '`copilot completion` only supports bash/zsh/fish; no native PowerShell completion command. PSCompletions fallback (#73).'
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

    $argsToml = ($Server.Arguments | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $section = @"
[mcp_servers.$($Server.Name)]
command = "$($Server.Command)"
args = [$argsToml]
"@
    if ($Server.ContainsKey('Env') -and $Server.Env -and $Server.Env.Count -gt 0) {
        $envLines = foreach ($k in $Server.Env.Keys) {
            $v = $Server.Env[$k]
            if ($null -eq $v) { $v = '' }
            $vEsc = $v -replace '\\','\\\\' -replace '"','\\"'
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
