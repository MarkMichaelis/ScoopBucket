# dotnet global-tool bulk sweep.
#
# Preferred path: `dotnet tool update -g --all` (added in .NET SDK 9.0.200).
# Older SDKs reject the flag with "Unrecognized option '--all'"; in that
# case we enumerate `dotnet tool list -g`, parse package IDs, and dispatch
# `dotnet tool update -g <id>` per row. Aggregate exit codes -- any failure
# downgrades the whole sweep to Failed but does not abort the loop.

function Update-AllDotnetToolPackages {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$WhatIf)

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        return @{ State = 'Skipped'; Reason = 'dotnet not on PATH.'; Engine = 'dotnetTool' }
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] dotnet tool update -g --all"
        return @{ State = 'Updated'; Reason = '(WhatIf)'; Engine = 'dotnetTool' }
    }

    # Try the modern --all flag first.
    Write-Host "  dotnet tool update -g --all"
    $out = & dotnet tool update -g --all 2>&1
    $exit = $LASTEXITCODE
    $joined = (@($out) -join "`n")

    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null; Engine = 'dotnetTool' }
    }

    # Fallback: --all unsupported on this SDK. Enumerate + per-tool update.
    if ($joined -match "Unrecognized option|Unknown option|--all") {
        Write-Host "  dotnet tool update --all unsupported on this SDK; falling back to per-tool enumeration."
        $listOut = & dotnet tool list -g 2>&1
        $listExit = $LASTEXITCODE
        if ($listExit -ne 0) {
            return @{ State = 'Failed'; Reason = "dotnet tool list -g exited with $listExit."; Engine = 'dotnetTool' }
        }
        # Skip the two header lines ("Package Id  Version  Commands" + dashes).
        $rows = @($listOut | ForEach-Object { $_.ToString() } | Where-Object { $_ -match '^\s*\S' -and $_ -notmatch '^\s*Package\s+Id' -and $_ -notmatch '^\s*---' })
        $anyFail = $false
        $count   = 0
        foreach ($row in $rows) {
            $id = ($row -split '\s+' | Where-Object { $_ })[0]
            if (-not $id) { continue }
            Write-Host "  dotnet tool update -g $id"
            & dotnet tool update -g $id | Out-Null
            if ($LASTEXITCODE -ne 0) { $anyFail = $true }
            $count++
        }
        if ($anyFail) {
            return @{ State = 'Failed'; Reason = "One or more per-tool updates failed (of $count tools)."; Engine = 'dotnetTool' }
        }
        return @{ State = 'Updated'; Reason = "Per-tool fallback updated $count tools."; Engine = 'dotnetTool' }
    }

    return @{ State = 'Failed'; Reason = "dotnet tool update -g --all exited with $exit. Output: $($joined.Trim())"; Engine = 'dotnetTool' }
}
