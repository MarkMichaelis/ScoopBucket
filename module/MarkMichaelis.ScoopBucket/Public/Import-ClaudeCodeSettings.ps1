function Import-ClaudeCodeSettings {
    <#
    .SYNOPSIS
        Apply the committed MarkMichaelis Claude Code configuration.
    .DESCRIPTION
        Desired-state configuration run as the Claude Code CLI package
        ConfigScript (#412), so it is re-applied on every install and update and
        is idempotent -- a re-run changes nothing:

          * Installs the tab-session hook (keeps each Windows Terminal tab's
            session record current so a restored tab resumes the right session),
            the "Prompt Spotlight" theme, and the "Outcomes, not code" output
            style under ~/.claude.
          * Read-merge-writes ~/.claude/settings.json: sets the keys under
            "settings" in the committed configuration (theme, outputStyle) and
            adds the hook to SessionStart and SessionEnd once, next to any
            existing hooks. Every other key is kept.

        The hook runs under Node.js, which Claude Code depends on. The committed
        configuration lives in the bucket, so the ConfigScript in AIAgents.ps1
        passes an explicit -ConfigPath resolved from its own $PSScriptRoot; the
        default resolves the same file when the module is imported from the
        repo. Honours -WhatIf.
    .PARAMETER ConfigPath
        The committed configuration (MarkMichaelisClaudeCodeSettings.jsonc). The
        hook, theme, and output style are read from the same folder.
    .PARAMETER ClaudeHome
        Claude Code's user folder (defaults to ~/.claude).
    .OUTPUTS
        PSCustomObject -- SettingsPath, Changed (the items written on this run).
    .EXAMPLE
        Import-ClaudeCodeSettings -WhatIf
        Shows what would change without writing anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\..\bucket\ai\MarkMichaelisClaudeCodeSettings.jsonc'),
        [string]$ClaudeHome = (Join-Path $HOME '.claude')
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Claude Code configuration not found: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $assetDir = Split-Path -Parent $ConfigPath
    $changed = [System.Collections.Generic.List[string]]::new()

    $hookPath = Join-Path $ClaudeHome 'scripts\tab-session-hook.js'
    if (Copy-FileIfChanged -Source (Join-Path $assetDir 'MarkMichaelisClaudeTabSessionHook.js') -Destination $hookPath) {
        $changed.Add('tab-session hook')
    }
    if (Copy-FileIfChanged -Source (Join-Path $assetDir 'MarkMichaelisClaudeOutcomesNotCode.md') -Destination (Join-Path $ClaudeHome 'output-styles\outcomes-not-code.md')) {
        $changed.Add('output style')
    }
    # Parsed and re-written so the committed .jsonc may carry comments.
    $theme = Read-JsonSettingsFile -Path (Join-Path $assetDir 'MarkMichaelisClaudePromptSpotlightTheme.jsonc')
    if (Write-JsonSettingsFile -Path (Join-Path $ClaudeHome 'themes\prompt-spotlight.json') -Settings $theme -Action 'Install theme') {
        $changed.Add('theme')
    }

    $settingsPath = Join-Path $ClaudeHome 'settings.json'
    $settings = Read-JsonSettingsFile -Path $settingsPath
    foreach ($key in $config['settings'].Keys) { $settings[$key] = $config['settings'][$key] }
    if ($settings['hooks'] -isnot [System.Collections.IDictionary]) { $settings['hooks'] = [ordered]@{} }
    $hookCommand = 'node "{0}"' -f $hookPath
    foreach ($hookEvent in 'SessionStart', 'SessionEnd') {
        $entries = @($settings['hooks'][$hookEvent] | Where-Object { $_ })
        # Matched per entry: ConvertTo-Json of an empty list emits nothing, which a
        # comparison operator treats as an empty (falsy) collection, not a non-match.
        $installed = $entries | Where-Object { ($_ | ConvertTo-Json -Depth 20 -Compress) -match 'tab-session-hook\.js' }
        if (-not $installed) {
            $settings['hooks'][$hookEvent] = $entries + , ([ordered]@{ hooks = @([ordered]@{ type = 'command'; command = $hookCommand }) })
        }
    }
    if (Write-JsonSettingsFile -Path $settingsPath -Settings $settings -Action 'Apply Claude Code settings') {
        $changed.Add('Claude Code settings')
    }

    [pscustomobject]@{
        SettingsPath = $settingsPath
        Changed      = $changed.ToArray()
    }
}
