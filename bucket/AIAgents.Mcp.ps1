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
    # Per-tool approval (Codex: auto | prompt | writes | approve), e.g. so
    # read-only tools run unattended while write tools always ask.
    if ($Server.ContainsKey('CodexToolApproval') -and $Server.CodexToolApproval) {
        foreach ($tool in $Server.CodexToolApproval.Keys) {
            $section += "`r`n[mcp_servers.$($Server.Name).tools.$tool]`r`napproval_mode = `"$($Server.CodexToolApproval[$tool])`""
        }
    }

    # The server's table and every sub-table ([...env], [...tools.<t>]) are
    # rewritten together, so a re-run never leaves a stale sub-table behind.
    $sectionPattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($Server.Name))(\.[^\]]+)?\].*?(?=^\[|\z)"

    if (Test-Path $Path) {
        $content = Get-Content -Path $Path -Raw
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

    $sectionPattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($ServerName))(\.[^\]]+)?\].*?(?=^\[|\z)"

    $content    = Get-Content -Path $Path -Raw
    $newContent = [regex]::Replace($content, $sectionPattern, '')
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

function Get-AIAgentsNpmInstallArgument {
    <#
    .SYNOPSIS
        Build the `npm install --global` argument vector for an MCP package,
        with quieting flags so a successful run is not buried in noise.
    .DESCRIPTION
        Pre-installing the MCP server packages globally drags in transitive
        dependencies that emit warn-level deprecation / EBADENGINE notices and
        funding banners. None of it is actionable by the user, yet it reads
        like a failure on an otherwise successful `Update-Package` run. These
        flags suppress that chatter while leaving real errors intact:

          --no-fund        drop the "N packages are looking for funding" banner
          --no-audit       skip the post-install audit summary
          --loglevel=error silence warn-level (deprecated / EBADENGINE) output;
                           genuine errors still print and still set a non-zero
                           exit code, so the caller's npx fallback still fires

        Returned as a typed array so the call site can splat it to `npm.cmd`
        and so the flags are independently testable.
    .PARAMETER Package
        The npm package spec to install (a version suffix such as `@latest`
        may already be appended by the caller).
    .OUTPUTS
        String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Package
    )
    @('install', '--global', $Package, '--no-fund', '--no-audit', '--loglevel=error')
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

function Test-PoshMcpToolPresent {
    <#
    .SYNOPSIS
        Report whether the poshmcp dotnet global tool is already installed.
    .DESCRIPTION
        The tool is "present" when its shim exists under the dotnet global-tools
        directory OR resolves on PATH. The on-disk check matters because a fresh
        `dotnet tool install` does not add the tools dir to the current session
        PATH, so Get-Command alone would miss a just-installed tool.
    .OUTPUTS
        Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $exe = Join-Path $env:USERPROFILE '.dotnet\tools\poshmcp.exe'
    return ((Test-Path $exe) -or [bool](Get-Command poshmcp -ErrorAction SilentlyContinue))
}

function Test-PoshMcpShouldConfigure {
    <#
    .SYNOPSIS
        Decide whether the `posh` MCP server should be wired, given whether the
        poshmcp tool is already present and the exit code of the install/update
        attempt.
    .DESCRIPTION
        A tool that is already present stays usable even when a re-install or
        update returns non-zero -- the common cause is a locked tool store
        because a running MCP client holds poshmcp open ("Access to the path
        '...\.store\poshmcp\<ver>' is denied"). In that case the existing version
        is perfectly serviceable, so we still configure the server. Only a tool
        that is genuinely absent AND failed to install is treated as unavailable.
    .OUTPUTS
        Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][bool]$ToolPresent,
        [Parameter(Mandatory)][int]$InstallExitCode
    )
    if ($ToolPresent) { return $true }
    return ($InstallExitCode -eq 0)
}

function Get-PoshMcpInstallFailureDetail {
    <#
    .SYNOPSIS
        Condense raw `dotnet tool install/update` output into one concise reason.
    .DESCRIPTION
        The best-effort PoshMcp update path captures dotnet's output instead of
        streaming it, so a single WARNING can explain why the update did not run
        without dumping dotnet's multi-line SDK-resolution or locked-store error
        block on an otherwise successful Update-Package run. This classifies the
        two common failures (no .NET SDK on the machine; tool store locked by a
        running MCP client) and otherwise falls back to the last meaningful line.
    .PARAMETER RawOutput
        The combined (2>&1) output lines captured from the dotnet invocation.
    .OUTPUTS
        A short human-readable reason string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$RawOutput
    )

    $lines = @($RawOutput | ForEach-Object { "$_" })
    $text = ($lines -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) { return 'no output' }

    if ($text -match 'No \.NET SDKs were found' -or $text -match 'sdk-not-found') {
        return 'no .NET SDK found (only the runtime is installed); install the .NET SDK to update the tool'
    }
    if ($text -match 'denied' -and $text -match '\.store') {
        return 'tool store locked by a running MCP client'
    }

    $lastMeaningful = @($lines | Where-Object { $_.Trim() }) | Select-Object -Last 1
    if ($lastMeaningful) { return $lastMeaningful.Trim() }
    return 'unknown error'
}

# ---------------------------------------------------------------------------
# GoDaddy DNS MCP server (#527).
#
# A local stdio server (ai\GoDaddyDnsMcp.ps1 + .psm1) that wraps the
# authenticated `gddy` CLI. It is wired only when gddy is installed (the
# 'GoDaddy CLI' package in DeveloperBasePackages). The files are copied to a
# stable per-user folder so the agent configs never point into a bucket
# checkout, a scoop version folder, or a git worktree.
# ---------------------------------------------------------------------------

function Get-GoDaddyMcpToolName {
    <#
    .SYNOPSIS
        The server's tools, split into read-only and write tools.
    #>
    [CmdletBinding()]
    param()
    @{
        Read  = @('godaddy_list_domains', 'godaddy_get_domain', 'godaddy_list_dns_records', 'godaddy_get_dns_record', 'godaddy_verify_dns')
        Write = @('godaddy_create_dns_record', 'godaddy_update_dns_record', 'godaddy_delete_dns_record')
    }
}

function Test-GoDaddyCliPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\gddy\gddy.exe'
    return ((Test-Path -LiteralPath $exe) -or [bool](Get-Command gddy -CommandType Application -ErrorAction SilentlyContinue))
}

function Get-GoDaddyMcpInstallPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $env:LOCALAPPDATA 'ScoopBucket\GoDaddyDnsMcp'
}

function Find-GoDaddyMcpSource {
    <#
    .SYNOPSIS
        Folder holding GoDaddyDnsMcp.ps1/.psm1: bucket\ai\ in the repo or a
        bucket checkout, or the scoop app folder itself (scoop downloads the
        manifest's url files flat).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$BaseDirectory = $PSScriptRoot)
    foreach ($dir in @((Join-Path $BaseDirectory 'ai'), $BaseDirectory)) {
        if ((Test-Path -LiteralPath (Join-Path $dir 'GoDaddyDnsMcp.ps1')) -and (Test-Path -LiteralPath (Join-Path $dir 'GoDaddyDnsMcp.psm1'))) {
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }
    return $null
}

function Install-GoDaddyMcpServerFiles {
    <#
    .SYNOPSIS
        Copy the server files into the stable install folder (only when they
        differ). Returns the path of the entry script.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )
    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }
    foreach ($file in 'GoDaddyDnsMcp.ps1', 'GoDaddyDnsMcp.psm1') {
        $src = Join-Path $SourceDirectory $file
        $dst = Join-Path $DestinationDirectory $file
        if (-not (Test-Path -LiteralPath $dst) -or (Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    return (Join-Path $DestinationDirectory 'GoDaddyDnsMcp.ps1')
}

function Get-GoDaddyMcpServerEntry {
    <#
    .SYNOPSIS
        The `godaddy` MCP server entry for every agent config: pwsh running
        the entry script over stdio, with Codex per-tool approval (reads run
        unattended, writes always prompt).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$PwshPath
    )
    if (-not $PwshPath) {
        $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $PwshPath = if ($cmd) { $cmd.Source } else { 'pwsh' }
    }
    $tools = Get-GoDaddyMcpToolName
    $approval = [ordered]@{}
    foreach ($t in $tools.Read)  { $approval[$t] = 'approve' }
    foreach ($t in $tools.Write) { $approval[$t] = 'prompt' }
    @{
        Name              = 'godaddy'
        Command           = $PwshPath
        Arguments         = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ScriptPath)
        CodexToolApproval = $approval
    }
}

function Set-GoDaddyMcpClaudePermission {
    <#
    .SYNOPSIS
        Merge Claude Code permission rules for the godaddy server into
        ~/.claude/settings.json: allow the read tools, and force a prompt
        ("ask") for the write tools and for raw gddy DNS writes in Bash.
    .DESCRIPTION
        Read-merge-write: only missing rules are appended and every other key
        is kept. An "ask" rule prompts even in auto mode and outranks any
        "allow" (deny > ask > allow), so "don't ask again" cannot silently
        remove the approval step for DNS changes.
    .OUTPUTS
        $true when the file changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'))

    $tools = Get-GoDaddyMcpToolName
    $allow = @($tools.Read | ForEach-Object { "mcp__godaddy__$_" })
    # Raw gddy writes, for both shell tools, in the plain form and a form that
    # also catches a full path (& 'C:\...\gddy.exe' dns set ...). Claude Code
    # documents these rules as covering the usual invocation, not as a hard
    # boundary -- the MCP server's approval flow is the primary safeguard.
    $ask = @($tools.Write | ForEach-Object { "mcp__godaddy__$_" })
    foreach ($verb in 'dns add', 'dns set', 'dns delete', 'domain nameserver', 'api call') {
        $ask += "Bash(gddy ${verb}:*)", "Bash(*gddy* $verb *)", "PowerShell(gddy $verb *)", "PowerShell(*gddy* $verb *)"
    }

    $settings = [ordered]@{}
    $raw = $null
    if (Test-Path -LiteralPath $SettingsPath) {
        $raw = Get-Content -LiteralPath $SettingsPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            # -DateKind String (pwsh 7.5+) keeps date-like strings verbatim.
            $parse = @{ AsHashtable = $true; Depth = 100 }
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $parse.DateKind = 'String' }
            try { $settings = $raw | ConvertFrom-Json @parse }
            catch {
                Write-Warning "Claude Code settings at $SettingsPath are not valid JSON; GoDaddy permission rules not added."
                return $false
            }
        }
    }
    if ($settings['permissions'] -isnot [System.Collections.IDictionary]) { $settings['permissions'] = [ordered]@{} }
    $changed = $false
    foreach ($pair in @(@{ Key = 'allow'; Rules = $allow }, @{ Key = 'ask'; Rules = $ask })) {
        $existing = @($settings['permissions'][$pair.Key] | Where-Object { $_ })
        $missing = @($pair.Rules | Where-Object { $existing -notcontains $_ })
        if ($missing.Count) {
            $settings['permissions'][$pair.Key] = @($existing) + $missing
            $changed = $true
        }
    }
    if ($changed) {
        $dir = Split-Path -Parent $SettingsPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Keep the pre-GoDaddy original once, then replace the file in one
        # rename so Claude Code never reads a half-written settings file.
        $backup = "$SettingsPath.pre-godaddy.bak"
        if ($null -ne $raw -and -not (Test-Path -LiteralPath $backup)) {
            [System.IO.File]::WriteAllText($backup, $raw, [System.Text.UTF8Encoding]::new($false))
        }
        $temp = "$SettingsPath.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($temp, ($settings | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $SettingsPath -Force
    }
    return $changed
}

function Install-GoDaddyMcpServer {
    <#
    .SYNOPSIS
        Deploy the GoDaddy DNS MCP server files and return its server entry,
        or $null (with a note) when gddy is not installed.
    #>
    [CmdletBinding()]
    param(
        [string]$BaseDirectory = $PSScriptRoot,
        [string]$DestinationDirectory = (Get-GoDaddyMcpInstallPath)
    )
    if (-not (Test-GoDaddyCliPresent)) {
        Write-Host "GoDaddy MCP: gddy is not installed; skipping. Install the 'GoDaddy CLI' package (DeveloperBasePackages), then run Update-Package 'MCP Server Configuration'."
        return $null
    }
    $source = Find-GoDaddyMcpSource -BaseDirectory $BaseDirectory
    if (-not $source) {
        Write-Warning "GoDaddy MCP: server files (GoDaddyDnsMcp.ps1/.psm1) not found next to $BaseDirectory; skipping."
        return $null
    }
    $script = Install-GoDaddyMcpServerFiles -SourceDirectory $source -DestinationDirectory $DestinationDirectory
    Write-Host "GoDaddy MCP: server files at $DestinationDirectory"
    return (Get-GoDaddyMcpServerEntry -ScriptPath $script)
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

    # Playwright (the `playwright` CLI plus its Chromium binaries) is owned by
    # the Playwright package, which this bundle declares as a DependsOn of
    # 'MCP Server Configuration' -- so by the time this runs, the package pass
    # has already installed it. Only warn here; re-installing it would
    # duplicate the package's own idempotent install.
    if (-not (Get-Command playwright -ErrorAction SilentlyContinue) -and
        -not (Get-Command npx -ErrorAction SilentlyContinue)) {
        Write-Warning 'Neither playwright nor npx is on PATH; the playwright MCP server will fail at runtime. Install the Playwright package (scoop install Playwright) and re-run Update-Package "MCP Server Configuration".'
    }

    # PoshMcp ships as a .NET global tool. Skip silently if dotnet isn't present.
    # If the tool is already installed, a re-install/update can fail merely
    # because a running MCP client locks the tool store -- the existing version
    # is still usable, so we configure the server regardless of that exit code.
    $poshMcpAvailable = $false
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $toolPresent = Test-PoshMcpToolPresent
        if ($toolPresent) {
            Write-Host 'PoshMcp already installed; attempting best-effort update...'
            # Capture rather than stream: on a machine with only the .NET runtime
            # (no SDK) `dotnet tool update` dumps a multi-line "No .NET SDKs were
            # found" block. We always fall back to the installed tool, so surface
            # just a one-line reason in the WARNING below instead (#350).
            $poshOut = & dotnet tool update -g poshmcp 2>&1
        }
        else {
            Write-Host 'Installing PoshMcp dotnet global tool...'
            & dotnet tool install -g poshmcp 2>&1 | Tee-Object -Variable poshOut | ForEach-Object { Write-Host "$_" }
        }
        $installExit = $LASTEXITCODE

        $poshMcpAvailable = Test-PoshMcpShouldConfigure -ToolPresent $toolPresent -InstallExitCode $installExit
        if ($poshMcpAvailable) {
            if ($installExit -ne 0) {
                $detail = Get-PoshMcpInstallFailureDetail -RawOutput $poshOut
                Write-Warning "PoshMcp install/update returned $installExit but poshmcp is already present (using the installed version). Detail: $detail"
            }
            $dotnetTools = Join-Path $env:USERPROFILE '.dotnet\tools'
            if ((Test-Path $dotnetTools) -and ($env:Path -notlike "*$dotnetTools*")) {
                $env:Path = "$env:Path;$dotnetTools"
            }
        }
        else {
            $detail = Get-PoshMcpInstallFailureDetail -RawOutput $poshOut
            Write-Warning "dotnet tool install -g poshmcp failed and poshmcp is not present; PoshMcp MCP server will not be configured. Detail: $detail"
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
            $npmArgs = Get-AIAgentsNpmInstallArgument -Package "$pkg@latest"
            & npm.cmd @npmArgs 2>&1 | ForEach-Object { Write-Host "$_" }
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

    # GoDaddy DNS through the local gddy CLI (#527); skipped without gddy.
    $goDaddyServer = Install-GoDaddyMcpServer
    if ($goDaddyServer) {
        $mcpServers += $goDaddyServer
        if (Set-GoDaddyMcpClaudePermission) {
            Write-Host 'GoDaddy MCP: added Claude Code permission rules (reads allowed; DNS writes always ask).'
        }
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
            & npm.cmd uninstall --global $pkg 2>&1 | ForEach-Object { Write-Host "$_" }
        }
    }
}
