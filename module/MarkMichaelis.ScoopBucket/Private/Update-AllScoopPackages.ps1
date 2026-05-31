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
        Write-Host "  [WhatIf] scoop $($updateArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)'; Engine = 'scoop' }
    }

    Write-Host "  scoop $($updateArgs -join ' ')"
    # Merge all streams; scoop writes its per-app status via Write-Host
    # which lands on the Information stream in PS7 (same rationale as
    # Update-ScoopPackage).
    $out = & scoop @updateArgs *>&1
    $exit = $LASTEXITCODE
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Host $joined }
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null; Engine = 'scoop' }
    }
    return @{ State = 'Failed'; Reason = "scoop update * exited with $exit."; Engine = 'scoop' }
}
