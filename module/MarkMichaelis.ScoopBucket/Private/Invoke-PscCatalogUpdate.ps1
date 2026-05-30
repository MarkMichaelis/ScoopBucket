function Invoke-PscCatalogUpdate {
    <#
    .SYNOPSIS
        Front-load a single `psc update *` catalog refresh and squelch
        the PSCompletions "use psc update * to update" nag banner.

    .DESCRIPTION
        Called once per Update-PackageCompletion invocation when the
        resolved package set contains any pscompletions-mode entries.
        Performs three actions, all best-effort:

          1. Ensure PSCompletions / `psc` is importable. If not, return
             quietly (caller's pscompletions registrations will fall
             through to Skipped).
          2. Run `psc update *` once to refresh local catalogs. On
             failure (e.g. the host-specific `__need_update_data`
             exception we have observed under PSCompletions 6.7.0),
             emit a Write-Warning and continue.
          3. Run `psc config enable_completions_update 0` to suppress
             the nag banner that otherwise prints on every subsequent
             Import-Module PSCompletions. If the config command itself
             throws, fall back to a direct edit of the JSON state file
             under (Get-Module PSCompletions).ModuleBase.

        Failures NEVER propagate -- callers can rely on this helper
        completing without throwing.
    #>
    [CmdletBinding()]
    param()

    # Best-effort contract: the helper MUST NOT propagate errors.
    # Callers may set -WarningAction Stop or $WarningPreference = 'Stop',
    # which would make plain Write-Warning terminating. Override the
    # local warning preference so every Write-Warning below stays
    # non-terminating regardless of caller configuration.
    $WarningPreference = 'Continue'

    # Always ensure PSCompletions is loaded before invoking `psc`.
    # PowerShell's command resolution order is function > cmdlet >
    # alias > application, so once PSCompletions is loaded its exported
    # `psc` function shadows any unrelated `psc` executable that may
    # also be on PATH. If PSCompletions is not installed at all, return
    # quietly -- the catalog refresh is meaningless without the module.
    if (-not (Get-Module -Name PSCompletions)) {
        $pscModule = Get-Module -ListAvailable -Name PSCompletions | Select-Object -First 1
        if (-not $pscModule) {
            Write-Verbose 'Invoke-PscCatalogUpdate: PSCompletions not installed; skipping psc update *.'
            return
        }
        try {
            # Suppress every output stream during Import-Module: the
            # PSCompletions module prints its update banner via
            # Write-Host / Write-Information at import time on some
            # versions; failures still surface as terminating exceptions
            # which the catch handles.
            Import-Module PSCompletions -ErrorAction Stop *>&1 | Out-Null
        } catch {
            Write-Warning "Invoke-PscCatalogUpdate: Import-Module PSCompletions failed: $($_.Exception.Message)"
            return
        }
    }
    # Sanity check: confirm `psc` resolves to PSCompletions, not a PATH
    # binary that somehow won the resolution race (e.g. a function
    # alias pointed at an external executable).
    $pscCmd = Get-Command psc -ErrorAction SilentlyContinue
    if (-not $pscCmd) {
        Write-Warning "Invoke-PscCatalogUpdate: PSCompletions loaded but 'psc' command not found; skipping catalog refresh."
        return
    }
    if ($pscCmd.ModuleName -and $pscCmd.ModuleName -ne 'PSCompletions') {
        Write-Warning "Invoke-PscCatalogUpdate: 'psc' resolves to module '$($pscCmd.ModuleName)' (expected 'PSCompletions'); skipping catalog refresh."
        return
    }

    try {
        # `*>&1 | Out-Null` swallows ALL streams (success, error,
        # warning, verbose, debug, information, host). PSCompletions
        # emits the nag banner via Write-Host / Write-Information, so
        # plain `2>&1 | Out-Null` would still leak it. Terminating
        # exceptions still hit the catch block below.
        & psc update '*' *>&1 | Out-Null
    } catch {
        Write-Warning "psc update * failed: $($_.Exception.Message). PSCompletions catalog may be stale."
    }

    try {
        & psc config enable_completions_update 0 *>&1 | Out-Null
    } catch {
        Write-Warning "psc config enable_completions_update 0 failed: $($_.Exception.Message). Attempting direct config edit."
        try {
            $pscModule = Get-Module PSCompletions
            if (-not $pscModule) { $pscModule = Get-Module -ListAvailable -Name PSCompletions | Select-Object -First 1 }
            if ($pscModule) {
                $candidates = @(
                    Join-Path $pscModule.ModuleBase 'config.json'
                    Join-Path $pscModule.ModuleBase 'data\config.json'
                )
                if ($env:APPDATA) {
                    $candidates += Join-Path $env:APPDATA 'PSCompletions\config.json'
                }
                $configPath = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
                if ($configPath) {
                    $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($cfg.PSObject.Properties.Name -contains 'enable_completions_update') {
                        $cfg.enable_completions_update = '0'
                    } else {
                        $cfg | Add-Member -NotePropertyName enable_completions_update -NotePropertyValue '0' -Force
                    }
                    ($cfg | ConvertTo-Json -Depth 20) | Set-Content -Path $configPath -Encoding UTF8
                }
            }
        } catch {
            Write-Warning "Direct PSCompletions config edit failed: $($_.Exception.Message)"
        }
    }
}
