# scoop bulk sweep: `scoop update *` updates every installed app. Note that
# bare `scoop update` only refreshes scoop itself + buckets, NOT apps -- the
# explicit `*` is required for a true "update everything" sweep.

function Update-AllScoopPackages {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$WhatIf)

    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        return @{ State = 'Skipped'; Reason = 'scoop not on PATH.'; Engine = 'scoop' }
    }

    $updateArgs = @('update', '*')

    if ($WhatIf) {
        Write-UpdateStatus "  [WhatIf] scoop $($updateArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)'; Engine = 'scoop' }
    }

    Write-UpdateStatus "Sweeping scoop (scoop update *)..."
    Write-Verbose "  scoop $($updateArgs -join ' ')"
    # Merge every stream; scoop per-app Write-Host status reaches us as the
    # child process stdout now the call is out of process (same rationale as
    # Update-ScoopPackage).
    # Out of process: `scoop update *` re-runs every outdated app's
    # installer.script, which re-imports this module with -Force. See
    # Invoke-ScoopCommand and #451.
    $out = Invoke-ScoopCommand @updateArgs *>&1
    $exit = $LASTEXITCODE
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Verbose $joined }
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null; Engine = 'scoop' }
    }
    return @{ State = 'Failed'; Reason = "scoop update * exited with $exit.$(Get-CapturedOutputTail $joined)"; Engine = 'scoop' }
}
