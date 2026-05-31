# Chocolatey bulk sweep: `choco upgrade all -y --no-progress`. Probes for
# `choco` first -- choco is optional on most machines and Skipped beats
# throwing CommandNotFound from inside a -All sweep.

function Update-AllChocoPackages {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$WhatIf)

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        return @{ State = 'Skipped'; Reason = 'choco not on PATH.'; Engine = 'choco' }
    }

    $upgradeArgs = @('upgrade', 'all', '-y', '--no-progress')

    if ($WhatIf) {
        Write-Host "  [WhatIf] choco $($upgradeArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)'; Engine = 'choco' }
    }

    Write-Host "  choco $($upgradeArgs -join ' ')"
    & choco @upgradeArgs
    $exit = $LASTEXITCODE
    # Treat reboot-required exits as Updated (same convention as
    # Update-ChocoPackage); only true failures map to Failed.
    if ($exit -eq 0 -or $exit -in @(1641, 3010)) {
        $reason = if ($exit -ne 0) { "Reboot pending (choco exit $exit)." } else { $null }
        return @{ State = 'Updated'; Reason = $reason; Engine = 'choco' }
    }
    return @{ State = 'Failed'; Reason = "choco upgrade all exited with $exit."; Engine = 'choco' }
}
