[CmdletBinding()]
param(
    # When set, prune any MCP server names this bucket has retired
    # (see $DeprecatedMcpServers below) from existing user MCP configs.
    # Off by default so a routine `scoop install` / reinstall never removes
    # entries the user may still rely on. Intended for direct invocation:
    #   pwsh -File AIAgents.ps1 -Reset
    [switch]$Reset
)

Write-Verbose 'Installing and configuring AIAgents...'
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
    #
    # AIAgents is the AUTHORITATIVE completion source for node/npm/npx
    # across every bundle in this repo. The hand-curated NativeCommandScript
    # below registers all three CLIs uniformly. Do NOT add a Node.js entry
    # to any other bundle (e.g. DeveloperBasePackages) -- a duplicate
    # would write a competing profile block for the same CLIs and the
    # registration outcome would become order-dependent. See issue #222.
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
        # Warp's Squirrel installer has been observed to stall after the
        # download phase on real-world updates (issues #269, #272). The
        # 5-minute default sweep timeout (from Update-Package's
        # -PackageTimeoutMinutes) was killing the install before it could
        # finish on slower links / large deltas. Bump *this* package's
        # ceiling to 20 minutes -- still bounded, but generous enough that
        # a healthy download + Squirrel apply completes without being
        # killed. Other packages are unaffected; the global default stays
        # at 5 minutes.
        UpdateTimeoutMinutes = 20
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
        NativeCompletionKind = 'native'
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
    # MCP-server wiring as declarative config. Unlike imperative tail code,
    # a ConfigScript is re-applied by the framework on every install and
    # every update (including no-op updates where no newer version exists)
    # -- the same always-run guarantee completions get. Refresh on demand
    # with `Update-Package 'MCP Server Configuration'`. The script is
    # self-contained: it dot-sources the helper module and resolves its own
    # token / runtime availability, so it works identically whether invoked
    # by the install driver or the update driver.
    [Package]@{
        Name      = 'MCP Server Configuration'
        Installer = 'custom'
        DependsOn = @('Node.js')
        Notes     = 'Idempotent MCP-server wiring for every MCP-capable agent. Re-applied on every install/update; refresh on demand with Update-Package "MCP Server Configuration".'
        # Engine no-op: the configuration IS the work, performed in ConfigScript.
        CustomInstallScript = { }
        ConfigScript = {
            . (Join-Path $PSScriptRoot 'AIAgents.Mcp.ps1')
            Install-AIAgentsMcpConfiguration
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'AIAgents'

# Probe-mode short-circuit: when Get-BundlePackages enumerates the bundle
# in a child runspace it shims Invoke-PackageInstall and sets this flag.
# The normal MCP wiring now runs as the 'MCP Server Configuration' package's
# ConfigScript (invoked by the install driver above), so only the opt-in
# -Reset prune and the best-effort completion sweep remain as tail work.
if ($global:__SBPKG_IS_PROBE) { return }

# Dot-source MCP-wiring helpers. AIAgents.Mcp.ps1 contains function
# definitions only -- no top-level work -- so the file is safe to source
# from this bundle as well as from bucket/AIAgents.Mcp.Tests.ps1.
. (Join-Path $PSScriptRoot 'AIAgents.Mcp.ps1')

if ($Reset) {
    Reset-AIAgentsMcpConfiguration
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

