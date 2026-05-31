# Scoop engine: refresh bucket clones once before bucket-scoped updates.
#
# Scoop's per-bucket git clone (under ~/scoop/buckets/<name>) is what
# `scoop update <app>` reads its manifest from. If the upstream bucket
# moved (e.g. a manifest's `url` field was fixed), the user's local
# clone still serves the old manifest and the per-app update fails --
# in the worst case with a 404 from the old `url`. See #265 and #267.
#
# `scoop update` with no arguments refreshes every bucket clone (it
# does NOT update installed apps). Update-Package calls this once per
# invocation when the dispatch plan contains a scoop package, so the
# subsequent per-app `scoop update <app>` calls always see the latest
# manifests.

function Update-ScoopBucket {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch]$WhatIf
    )

    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Update-ScoopBucket: scoop CLI not on PATH; skipping bucket refresh.'
        return @{ State = 'Skipped'; Reason = 'scoop CLI not on PATH.' }
    }

    if ($WhatIf) {
        Write-Host '  [WhatIf] scoop update (refresh bucket clones)'
        return @{ State = 'Refreshed'; Reason = '(WhatIf)' }
    }

    Write-Host '  scoop update (refresh bucket clones)'
    # Capture all streams (scoop writes progress via Write-Host which
    # in PS7 lands on the Information stream, not stdout).
    $out = & scoop update *>&1
    $exit = $LASTEXITCODE
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Host $joined }
    if ($exit -ne 0) {
        return @{ State = 'Failed'; Reason = "scoop update exited with $exit." }
    }
    return @{ State = 'Refreshed'; Reason = $null }
}
