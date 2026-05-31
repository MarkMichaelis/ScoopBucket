# npmGlobal bulk sweep: `npm update -g`. Hard-codes `npm.cmd` for the same
# reason Update-NpmGlobalPackage does (avoids the npm.ps1 arg-mangling bug
# fixed in #249). Probes for `npm.cmd` specifically.

function Update-AllNpmGlobalPackages {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$WhatIf)

    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        return @{ State = 'Skipped'; Reason = 'npm.cmd not on PATH.'; Engine = 'npmGlobal' }
    }

    $updateArgs = @('update', '-g')

    if ($WhatIf) {
        Write-Host "  [WhatIf] npm $($updateArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)'; Engine = 'npmGlobal' }
    }

    Write-Host "  npm $($updateArgs -join ' ')"
    & npm.cmd @updateArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null; Engine = 'npmGlobal' }
    }
    return @{ State = 'Failed'; Reason = "npm update -g exited with $exit."; Engine = 'npmGlobal' }
}
