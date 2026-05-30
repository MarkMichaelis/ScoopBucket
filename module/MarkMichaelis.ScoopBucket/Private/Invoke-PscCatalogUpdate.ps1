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

    if (-not (Get-Command psc -ErrorAction SilentlyContinue)) {
        $pscModule = Get-Module -ListAvailable -Name PSCompletions | Select-Object -First 1
        if (-not $pscModule) {
            Write-Verbose 'Invoke-PscCatalogUpdate: PSCompletions not installed; skipping psc update *.'
            return
        }
        try {
            Import-Module PSCompletions -ErrorAction Stop
        } catch {
            Write-Warning "Invoke-PscCatalogUpdate: Import-Module PSCompletions failed: $($_.Exception.Message)"
            return
        }
    }

    try {
        & psc update '*' 2>&1 | Out-Null
    } catch {
        Write-Warning "psc update * failed: $($_.Exception.Message). PSCompletions catalog may be stale."
    }

    try {
        & psc config enable_completions_update 0 2>&1 | Out-Null
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
