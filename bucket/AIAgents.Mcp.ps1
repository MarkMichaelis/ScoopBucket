#requires -Version 7.0

<#
.SYNOPSIS
    Helper functions for AIAgents.ps1 MCP-server wiring.

.DESCRIPTION
    AIAgents.ps1 dot-sources this file. Tests dot-source it directly
    so they can exercise individual helpers without running the
    bundle's imperative install side effects.

    Functions ONLY. No top-level work. Dot-sourcing must have zero
    observable side effects.

    See bucket/AIAgents.Mcp.Tests.ps1 for behavior-first coverage.
#>

# ---------------------------------------------------------------------------
# Profile self-heal sentinel: idempotent block appended to PowerShell
# profile(s) so any new shell whose env var is missing back-fills from
# `gh auth token`. Steady-state cost is microseconds: HKCU/Machine User
# env scope auto-populates the variable in nearly every spawn, so the
# `-not $env:GITHUB_PERSONAL_ACCESS_TOKEN` guard short-circuits before
# any process spawn.
# ---------------------------------------------------------------------------

$script:McpProfileSentinelStart = '# >>> ScoopBucket: GitHub PAT for MCP servers >>>'
$script:McpProfileSentinelEnd   = '# <<< ScoopBucket: GitHub PAT for MCP servers <<<'

function Get-McpProfileSentinelBlock {
    @"
$script:McpProfileSentinelStart
# Self-heal: HKCU User env var (set by AIAgents.ps1) is normally already
# inherited at process startup. Only fetch from gh as a fallback.
if (-not `$env:GITHUB_PERSONAL_ACCESS_TOKEN -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    try { `$env:GITHUB_PERSONAL_ACCESS_TOKEN = (gh auth token 2>`$null).Trim() } catch { }
}
function Update-GitHubTokenFromGh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Warning 'gh CLI not found.'; return }
    `$token = (gh auth token 2>`$null).Trim()
    if (-not `$token) { Write-Warning 'gh auth token returned empty.'; return }
    `$env:GITHUB_PERSONAL_ACCESS_TOKEN = `$token
    [Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', `$token, 'User')
    Write-Host 'Refreshed GITHUB_PERSONAL_ACCESS_TOKEN in current shell + HKCU User env.'
}
$script:McpProfileSentinelEnd
"@
}

# ---------------------------------------------------------------------------
# Elevation detection. Wrapped as a function so tests can Mock it.
# ---------------------------------------------------------------------------

function Test-IsElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-McpProfileTargets {
    <#
    .SYNOPSIS
        Returns the list of PowerShell profile paths the sentinel block
        should be installed into. Elevation-aware:
          elevated     -> AllUsersAllHosts (machine-wide pwsh 7)
          non-elevated -> CurrentUserAllHosts (pwsh 7) +
                          ~\Documents\WindowsPowerShell\profile.ps1 (5.1)
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [switch]$IsElevated
    )

    if ($IsElevated) {
        return [string[]]@($PROFILE.AllUsersAllHosts)
    }

    $pwsh7 = $PROFILE.CurrentUserAllHosts
    $ps51  = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\profile.ps1'
    return [string[]]@($pwsh7, $ps51)
}

# ---------------------------------------------------------------------------
# Profile sentinel I/O.
# ---------------------------------------------------------------------------

function Add-McpProfileSentinel {
    <#
    .SYNOPSIS
        Idempotently append the sentinel-bracketed block to a single
        profile file. Re-runs are no-ops when the start marker is
        already present.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path $Path) {
        $existing = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing -match [regex]::Escape($script:McpProfileSentinelStart)) {
            return $false  # already present
        }
        $separator = if ($existing -and -not $existing.EndsWith("`n")) { "`r`n" } else { '' }
        $block = $separator + (Get-McpProfileSentinelBlock) + "`r`n"
        Add-Content -Path $Path -Value $block -Encoding UTF8 -NoNewline
    } else {
        Set-Content -Path $Path -Value ((Get-McpProfileSentinelBlock) + "`r`n") -Encoding UTF8 -NoNewline
    }
    return $true
}

function Remove-McpProfileSentinel {
    <#
    .SYNOPSIS
        Idempotently strip the sentinel-bracketed block from a profile
        file. No-op if the marker is absent or the file does not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) { return $false }

    $content = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return $false }

    $startEsc = [regex]::Escape($script:McpProfileSentinelStart)
    $endEsc   = [regex]::Escape($script:McpProfileSentinelEnd)
    $pattern  = "(?ms)\r?\n?$startEsc.*?$endEsc\r?\n?"

    $newContent = [regex]::Replace($content, $pattern, '')
    if ($newContent -eq $content) { return $false }

    if ([string]::IsNullOrWhiteSpace($newContent)) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    } else {
        Set-Content -Path $Path -Value $newContent.TrimEnd() -Encoding UTF8
    }
    return $true
}

# ---------------------------------------------------------------------------
# Persisted env var (HKCU User scope, or HKLM Machine scope when elevated).
# Wrapped so tests can Mock these without touching the real registry.
# ---------------------------------------------------------------------------

function Set-PersistedGitHubToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [switch]$IsElevated
    )

    $scope = if ($IsElevated) { 'Machine' } else { 'User' }
    [Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', $Token, $scope)
}

function Clear-PersistedGitHubToken {
    [CmdletBinding()]
    param(
        [switch]$IsElevated
    )

    $scope = if ($IsElevated) { 'Machine' } else { 'User' }
    [Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', $null, $scope)
}

# ---------------------------------------------------------------------------
# npm bin resolution. Locates the .cmd shim for a globally-installed
# package without hard-coding bin names that can change upstream.
# ---------------------------------------------------------------------------

function Get-NpmGlobalRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # On Windows, prefer `npm.cmd` explicitly: when PowerShell's call
    # operator invokes `npm` (which resolves to npm.ps1 under Scoop and
    # most other npm-on-Windows installs), the .ps1 shim's parameter
    # parsing mangles the first positional argument -- `& npm prefix -g`
    # is dispatched as `npm pm -g` and fails with `Unknown command: pm`.
    # `npm.cmd` is the batch shim and passes args verbatim.
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npm) { return $null }
    try {
        $prefix = & $npm.Source prefix -g 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $prefix) { return $null }
        return ($prefix | Out-String).Trim()
    } catch {
        return $null
    }
}

function Resolve-NpmBin {
    <#
    .SYNOPSIS
        Resolve a globally-installed npm package's .cmd shim path by
        reading its package.json#bin map under the global node_modules
        root. Returns $null if the package or shim is missing.
    .PARAMETER NpmGlobalRoot
        Optional override (used by tests to point at a temp directory).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [string]$NpmGlobalRoot
    )

    if (-not $NpmGlobalRoot) { $NpmGlobalRoot = Get-NpmGlobalRoot }
    if (-not $NpmGlobalRoot) { return $null }

    $pkgJson = Join-Path $NpmGlobalRoot "node_modules\$PackageName\package.json"
    if (-not (Test-Path $pkgJson)) { return $null }

    try {
        $manifest = Get-Content -Path $pkgJson -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $manifest -or -not $manifest.bin) { return $null }

    $binName = $null
    if ($manifest.bin -is [string]) {
        # Single-bin form: bin name is the package's last path segment.
        $binName = ($PackageName -split '/')[-1]
    } elseif ($manifest.bin -is [pscustomobject]) {
        $binName = ($manifest.bin.PSObject.Properties | Select-Object -First 1).Name
    } elseif ($manifest.bin -is [hashtable]) {
        $binName = @($manifest.bin.Keys)[0]
    }
    if (-not $binName) { return $null }

    $cmd = Join-Path $NpmGlobalRoot "$binName.cmd"
    if (-not (Test-Path $cmd)) { return $null }
    return $cmd
}

# ---------------------------------------------------------------------------
# MCP-config writers/removers. Logic preserved from AIAgents.ps1 with
# one behavioral change: the JSON writer no longer emits an `env` block
# when the server entry's Env hashtable is missing or empty (so an old
# token-bearing entry is silently overwritten with a token-less one
# on the next run).
# ---------------------------------------------------------------------------

function Add-McpServerToJsonConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AgentLabel,
        [Parameter(Mandatory)][hashtable]$Server
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
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

function Add-McpServerToCodex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Server,
        [string]$Path
    )

    if (-not $Path) { $Path = Join-Path $env:USERPROFILE '.codex\config.toml' }
    $dir  = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # TOML basic strings interpret backslash as an escape character. Any
    # raw Windows path like 'C:\Users\Mark' contains '\U' which the TOML
    # parser tries to consume as a \UXXXXXXXX Unicode escape and fails
    # with "too few unicode value digits". Escape backslashes (\ -> \\)
    # and double-quotes (" -> \") in every interpolated value.
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

    if (Test-Path $Path) {
        $content = Get-Content -Path $Path -Raw
        $content = [regex]::Replace($content, $envSectionPattern, '')
        $content = [regex]::Replace($content, $sectionPattern, '')
        $content = $content.TrimEnd() + "`r`n`r`n" + $section + "`r`n"
        Set-Content -Path $Path -Value $content -Encoding UTF8
    }
    else {
        Set-Content -Path $Path -Value ($section + "`r`n") -Encoding UTF8
    }
    Write-Host "Codex CLI: configured $($Server.Name) MCP in $Path"
}

function Remove-McpServerFromJsonConfig {
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
    Write-Host "$AgentLabel`: pruned $ServerName MCP from $Path"
}

function Remove-McpServerFromCodex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [string]$Path
    )

    if (-not $Path) { $Path = Join-Path $env:USERPROFILE '.codex\config.toml' }
    if (-not (Test-Path $Path)) { return }

    $sectionPattern    = "(?ms)^\[mcp_servers\.$([regex]::Escape($ServerName))\].*?(?=^\[|\z)"
    $envSectionPattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($ServerName))\.env\].*?(?=^\[|\z)"

    $content    = Get-Content -Path $Path -Raw
    $newContent = [regex]::Replace($content, $envSectionPattern, '')
    $newContent = [regex]::Replace($newContent, $sectionPattern, '')
    if ($newContent -ne $content) {
        Set-Content -Path $Path -Value $newContent.TrimEnd() -Encoding UTF8
        Write-Host "Codex CLI: pruned $ServerName MCP from $Path"
    }
}

# ---------------------------------------------------------------------------
# Resolve $McpServers entries. For each npm-backed server, prefer the
# globally-installed bin shim (fast, no npx round-trip); fall back to
# `npx -y <pkg>` when bin resolution fails (graceful degradation).
# ---------------------------------------------------------------------------

function Resolve-McpServerCommand {
    <#
    .SYNOPSIS
        Given an npm package name, return a hashtable with `Command`
        and `Arguments` keys: the resolved bin path with empty args
        when the package is globally installed, otherwise an
        `npx -y <pkg>` fallback.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [string]$NpmGlobalRoot,
        [string[]]$ExtraArguments = @()
    )

    $bin = Resolve-NpmBin -PackageName $PackageName -NpmGlobalRoot $NpmGlobalRoot
    if ($bin) {
        return @{ Command = $bin; Arguments = @($ExtraArguments) }
    }
    $args = @('-y', $PackageName) + $ExtraArguments
    return @{ Command = 'npx'; Arguments = $args }
}

# ---------------------------------------------------------------------------
# Shared declarative data for the MCP wiring. Kept as functions (not top-level
# variables) so dot-sourcing this file stays side-effect free, and so both the
# apply (Install-AIAgentsMcpConfiguration) and prune
# (Reset-AIAgentsMcpConfiguration) paths share one source of truth.
# ---------------------------------------------------------------------------

function Get-AIAgentsMcpJsonAgent {
    <#
    .SYNOPSIS
        The JSON-config agents AIAgents wires MCP servers into.
    .OUTPUTS
        Hashtable[] with Label and Path keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    @(
        @{ Label = 'Claude Desktop';     Path = (Join-Path $env:APPDATA     'Claude\claude_desktop_config.json') }
        @{ Label = 'Claude Code CLI';    Path = (Join-Path $env:USERPROFILE '.claude.json') }
        @{ Label = 'Gemini CLI';         Path = (Join-Path $env:USERPROFILE '.gemini\settings.json') }
        @{ Label = 'GitHub Copilot CLI'; Path = (Join-Path $env:USERPROFILE '.copilot\mcp-config.json') }
    )
}

function Get-AIAgentsMcpNpmPackage {
    <#
    .SYNOPSIS
        npm package names AIAgents pre-installs globally for its MCP servers.
    .OUTPUTS
        String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    @(
        '@upstash/context7-mcp',
        '@playwright/mcp',
        '@modelcontextprotocol/server-github',
        '@modelcontextprotocol/server-filesystem'
    )
}

function Get-AIAgentsDeprecatedMcpServer {
    <#
    .SYNOPSIS
        MCP server names this bucket has retired and prunes under -Reset.
    .OUTPUTS
        String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    @('shell')
}

# ---------------------------------------------------------------------------
# PoshMcp full-access PowerShell surface.
#
# PoshMcp filters which PowerShell commands it exposes as MCP tools via the
# PowerShellConfiguration section of its config (CommandNames / Modules /
# IncludePatterns / ExcludePatterns). Its default surface is read-only
# (Get-* style commands only). To give agents a full, write-capable
# interactive PowerShell, we ship a config with IncludePatterns '*' and
# point `poshmcp serve --config <path>` at it.
#
# SECURITY: IncludePatterns '*' exposes EVERY command, including destructive
# cmdlets and Invoke-Expression. This is a deliberate, owner-approved posture
# for this bucket; every wired agent inherits unrestricted PowerShell.
# ---------------------------------------------------------------------------

function Get-PoshMcpConfigPath {
    <#
    .SYNOPSIS
        Per-user path of the PoshMcp full-access config file.
    .OUTPUTS
        String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $env:USERPROFILE '.poshmcp\appsettings.full.json'
}

function Write-PoshMcpFullAccessConfig {
    <#
    .SYNOPSIS
        Idempotently write a PoshMcp config exposing the full (write-capable)
        PowerShell command surface via IncludePatterns '*'.
    .OUTPUTS
        The config file path that was written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $config = [ordered]@{
        PowerShellConfiguration = [ordered]@{
            CommandNames    = @()
            Modules         = @()
            IncludePatterns = @('*')
            ExcludePatterns = @()
        }
    }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
    return $Path
}

function Get-PoshMcpServerEntry {
    <#
    .SYNOPSIS
        Build the `posh` MCP server entry that points poshmcp at a full-access
        config so agents get the complete (write-capable) PowerShell surface.
    .OUTPUTS
        Hashtable with Name, Command, and Arguments keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath
    )
    @{
        Name      = 'posh'
        Command   = 'poshmcp'
        Arguments = @('serve', '--transport', 'stdio', '--config', $ConfigPath)
    }
}

function Install-AIAgentsMcpConfiguration {
    <#
    .SYNOPSIS
        Apply the AIAgents MCP-server configuration idempotently.

    .DESCRIPTION
        Self-contained machine configuration for the AIAgents bundle: install
        Playwright browsers, the PoshMcp dotnet tool, and the MCP npm packages;
        resolve a GitHub PAT; write the mcpServers entries into every supported
        agent config (JSON + Codex TOML); persist the PAT out-of-band; and
        install the profile self-heal block. Re-running overwrites only the
        named entries -- other MCP servers in the same config are preserved.

        This is invoked by the bundle's ConfigScript so it runs on every
        install and every update, and on demand via
        Update-Package 'MCP Server Configuration'.
    #>
    [CmdletBinding()]
    param()

    # Playwright separates its browser binaries from the npm package; install
    # @playwright/test globally so the `playwright` shim lands on PATH, then
    # install just chromium.
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

    # PoshMcp ships as a .NET global tool. Skip silently if dotnet isn't present.
    $poshMcpAvailable = $false
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        Write-Host 'Installing PoshMcp dotnet global tool...'
        & dotnet tool install -g poshmcp 2>&1 | Tee-Object -Variable poshOut
        if ($LASTEXITCODE -eq 0 -or ($poshOut -join "`n") -match 'already installed') {
            $poshMcpAvailable = $true
            $dotnetTools = Join-Path $env:USERPROFILE '.dotnet\tools'
            if ((Test-Path $dotnetTools) -and ($env:Path -notlike "*$dotnetTools*")) {
                $env:Path = "$env:Path;$dotnetTools"
            }
        }
        else {
            Write-Warning 'dotnet tool install -g poshmcp failed; PoshMcp MCP server will not be configured.'
        }
    }
    else {
        Write-Warning 'dotnet not found; skipping PoshMcp install. Install the .NET 10+ SDK (e.g., DeveloperBasePackages) and re-run AIAgents to enable PoshMcp.'
    }

    # Auto-detect a GitHub PAT for the GitHub MCP server.
    $githubToken = $env:GITHUB_PERSONAL_ACCESS_TOKEN
    if ([string]::IsNullOrWhiteSpace($githubToken) -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        try {
            $ghToken = & gh auth token 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ghToken)) {
                $githubToken = $ghToken.Trim()
                Write-Host 'GitHub MCP: using token from `gh auth token`.'
            }
        }
        catch { Write-Verbose "GitHub MCP: gh auth token lookup failed: $($_.Exception.Message)" }
    }
    if ([string]::IsNullOrWhiteSpace($githubToken)) {
        Write-Warning 'GitHub MCP: no token found (set $env:GITHUB_PERSONAL_ACCESS_TOKEN or run `gh auth login`). The MCP entry will be written but will fail at runtime until a token is provided.'
    }

    # Pre-install MCP server npm packages globally so each agent spawn invokes
    # the resolved .cmd shim directly instead of paying a fresh npx round-trip.
    $mcpNpmPackages = Get-AIAgentsMcpNpmPackage
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        foreach ($pkg in $mcpNpmPackages) {
            Write-Host "Installing $pkg globally (latest)..."
            & npm.cmd install --global "$pkg@latest" 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "npm install -g $pkg failed; that MCP entry will fall back to 'npx -y'."
            }
        }
    }
    else {
        Write-Warning 'npm not found; all MCP npm entries will fall back to npx (slow first-spawn).'
    }

    $npmGlobalRoot = Get-NpmGlobalRoot

    $context7Cmd   = Resolve-McpServerCommand -PackageName '@upstash/context7-mcp'                    -NpmGlobalRoot $npmGlobalRoot
    $playwrightCmd = Resolve-McpServerCommand -PackageName '@playwright/mcp'                          -NpmGlobalRoot $npmGlobalRoot
    $filesystemCmd = Resolve-McpServerCommand -PackageName '@modelcontextprotocol/server-filesystem' -NpmGlobalRoot $npmGlobalRoot -ExtraArguments @($env:USERPROFILE)
    $githubCmd     = Resolve-McpServerCommand -PackageName '@modelcontextprotocol/server-github'      -NpmGlobalRoot $npmGlobalRoot

    $mcpServers = @(
        @{ Name = 'context7';   Command = $context7Cmd.Command;   Arguments = $context7Cmd.Arguments }
        @{ Name = 'playwright'; Command = $playwrightCmd.Command; Arguments = $playwrightCmd.Arguments }
        @{ Name = 'filesystem'; Command = $filesystemCmd.Command; Arguments = $filesystemCmd.Arguments }
        @{
            Name       = 'github'
            Command    = $githubCmd.Command
            Arguments  = $githubCmd.Arguments
            # GitHub Copilot CLI ships its own remote github-mcp-server; skip
            # writing this entry there to avoid duplication.
            SkipAgents = @('GitHub Copilot CLI')
        }
    )

    if ($poshMcpAvailable) {
        $poshConfigPath = Write-PoshMcpFullAccessConfig -Path (Get-PoshMcpConfigPath)
        Write-Host "PoshMcp: wrote full-access PowerShell config to $poshConfigPath (IncludePatterns '*')."
        $mcpServers += Get-PoshMcpServerEntry -ConfigPath $poshConfigPath
    }

    $jsonAgents = Get-AIAgentsMcpJsonAgent

    foreach ($server in $mcpServers) {
        $skip = @()
        if ($server.ContainsKey('SkipAgents') -and $server.SkipAgents) { $skip = @($server.SkipAgents) }

        foreach ($agent in $jsonAgents) {
            if ($skip -contains $agent.Label) {
                Write-Host "$($agent.Label): skipping $($server.Name) MCP (built-in equivalent)."
                continue
            }
            Add-McpServerToJsonConfig -Path $agent.Path -AgentLabel $agent.Label -Server $server
        }
        if ($skip -notcontains 'Codex CLI') {
            Add-McpServerToCodex -Server $server
        }
    }

    # Provision the GitHub PAT out-of-band so it does NOT live in any agent
    # config file. Profile sentinel acts as a self-heal fallback if HKCU is
    # ever cleared.
    $isElevated = Test-IsElevated

    if (-not [string]::IsNullOrWhiteSpace($githubToken)) {
        Set-PersistedGitHubToken -Token $githubToken -IsElevated:$isElevated
        $scopeLabel = if ($isElevated) { 'HKLM Machine' } else { 'HKCU User' }
        Write-Host "GitHub MCP: persisted GITHUB_PERSONAL_ACCESS_TOKEN at $scopeLabel scope."
    }

    foreach ($profilePath in (Get-McpProfileTargets -IsElevated:$isElevated)) {
        if (Add-McpProfileSentinel -Path $profilePath) {
            Write-Host "GitHub MCP: installed self-heal block in $profilePath"
        }
    }
}

function Reset-AIAgentsMcpConfiguration {
    <#
    .SYNOPSIS
        Prune retired / skipped MCP entries and clear the persisted PAT.

    .DESCRIPTION
        The opt-in counterpart to Install-AIAgentsMcpConfiguration: removes the
        MCP server names this bucket has retired, prunes entries intentionally
        skipped (e.g. GitHub Copilot CLI), removes the profile self-heal block,
        clears the persisted GitHub PAT, and uninstalls the MCP npm packages.
        Invoked only on explicit `AIAgents.ps1 -Reset`.
    #>
    [CmdletBinding()]
    param()

    $deprecated     = Get-AIAgentsDeprecatedMcpServer
    $jsonAgents     = Get-AIAgentsMcpJsonAgent
    $mcpNpmPackages = Get-AIAgentsMcpNpmPackage
    $isElevated     = Test-IsElevated

    Write-Host "-Reset: pruning deprecated MCP server names ($($deprecated -join ', '))..."
    foreach ($name in $deprecated) {
        foreach ($agent in $jsonAgents) {
            Remove-McpServerFromJsonConfig -Path $agent.Path -AgentLabel $agent.Label -ServerName $name
        }
        Remove-McpServerFromCodex -ServerName $name
    }

    # Prune entries this bucket intentionally skips (server -> skipped agents)
    # so users upgrading from a pre-skip version get the stale entry cleaned.
    $skipMap = @{ github = @('GitHub Copilot CLI') }
    foreach ($serverName in $skipMap.Keys) {
        foreach ($skipLabel in $skipMap[$serverName]) {
            $agent = $jsonAgents | Where-Object { $_.Label -eq $skipLabel } | Select-Object -First 1
            if ($agent) {
                Remove-McpServerFromJsonConfig -Path $agent.Path -AgentLabel $agent.Label -ServerName $serverName
            }
        }
    }

    Write-Host '-Reset: removing GitHub PAT self-heal block from PowerShell profile(s)...'
    foreach ($profilePath in (Get-McpProfileTargets -IsElevated:$isElevated)) {
        if (Remove-McpProfileSentinel -Path $profilePath) {
            Write-Host "  pruned $profilePath"
        }
    }

    Write-Host '-Reset: clearing persisted GITHUB_PERSONAL_ACCESS_TOKEN env var...'
    Clear-PersistedGitHubToken -IsElevated:$isElevated

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host '-Reset: uninstalling MCP npm packages globally...'
        foreach ($pkg in $mcpNpmPackages) {
            & npm.cmd uninstall --global $pkg 2>&1 | Out-Host
        }
    }
}
