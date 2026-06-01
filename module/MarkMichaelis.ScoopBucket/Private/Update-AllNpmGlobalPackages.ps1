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
        Write-UpdateStatus "  [WhatIf] npm $($updateArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)'; Engine = 'npmGlobal' }
    }

    Write-UpdateStatus "Sweeping npmGlobal (npm update -g)..."
    Write-Verbose "  npm $($updateArgs -join ' ')"
    $out = & npm.cmd @updateArgs *>&1
    $exit = $LASTEXITCODE
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Verbose $joined }
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null; Engine = 'npmGlobal' }
    }
    return @{ State = 'Failed'; Reason = "npm update -g exited with $exit.$(Get-CapturedOutputTail $joined)"; Engine = 'npmGlobal' }
}
