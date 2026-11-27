# Winget engine: uninstalls a single Package via `winget uninstall`.
#
# Inverse of Install-WingetPackage. The presence probe is the same
# (Test-WingetPackageInstalled; #516) but inverted: found ⇒ uninstall;
# not found ⇒ NotInstalled short-circuit.

function Uninstall-WingetPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "winget: Id is empty for '$($Package.Name)'." }
    }

    # Name the installed package exactly as the probe found it: a plain --id is
    # a substring match, so `winget uninstall --id OpenAI.Codex` would remove
    # the ChatGPT Store app (package family OpenAI.Codex_...) when Codex CLI is
    # not installed (#553).
    $target = @('--id', $id)
    if (-not $WhatIf) {
        try {
            $probe = Test-WingetPackageInstalled -Package $Package
            if (-not $probe.Installed) {
                return @{ State = 'NotInstalled'; Reason = $probe.Reason }
            }
            if ($probe.Id) { $target = @('--id', $probe.Id, '--exact') }
        } catch {
            Write-Verbose "Uninstall-WingetPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $uninstallArgs = @('uninstall') + $target + @('--silent', '--accept-source-agreements')
    if ($Package.Scope -in @('machine','global')) {
        $uninstallArgs += @('--scope', 'machine')
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] winget $($uninstallArgs -join ' ')"
        return @{ State = 'Uninstalled'; Reason = '(WhatIf)' }
    }

    Write-Host "  winget $($uninstallArgs -join ' ')"
    & winget @uninstallArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Uninstalled'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "winget uninstall --id $id exited with $exit." }
}
