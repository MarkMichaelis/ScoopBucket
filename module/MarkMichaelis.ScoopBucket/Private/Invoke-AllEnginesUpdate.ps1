# Orchestrator for `Update-Package -All`: runs the five per-engine bulk
# sweeps in a deterministic order and prints a one-row-per-engine summary
# table using the same glyph scheme as Invoke-PackageUpdate.
#
# Engine order: scoop -> winget -> choco -> npmGlobal -> dotnetTool.
# scoop first because it's this bucket's primary engine; the rest are
# alphabetical for predictability.
#
# A per-engine failure does NOT short-circuit the remaining sweeps -- each
# engine reports independently in the summary.

function Invoke-AllEnginesUpdate {
    [CmdletBinding()]
    param([switch]$DryRun)

    $engineOrder = @(
        @{ Name = 'scoop';      Cmd = { param($w) Update-AllScoopPackages      -WhatIf:$w } },
        @{ Name = 'winget';     Cmd = { param($w) Update-AllWingetPackages     -WhatIf:$w } },
        @{ Name = 'choco';      Cmd = { param($w) Update-AllChocoPackages      -WhatIf:$w } },
        @{ Name = 'npmGlobal';  Cmd = { param($w) Update-AllNpmGlobalPackages  -WhatIf:$w } },
        @{ Name = 'dotnetTool'; Cmd = { param($w) Update-AllDotnetToolPackages -WhatIf:$w } }
    )

    Write-Host ""
    Write-Host "=== Invoke-AllEnginesUpdate: machine-wide sweep across $($engineOrder.Count) engines ==="

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($engine in $engineOrder) {
        Write-Host ""
        Write-Host "[update-all] [$($engine.Name)]"
        try {
            $r = & $engine.Cmd $DryRun
        } catch {
            $r = @{ State = 'Failed'; Reason = "Engine threw: $($_.Exception.Message)"; Engine = $engine.Name }
        }
        if (-not $r.Engine) { $r.Engine = $engine.Name }
        $results.Add($r)
    }

    Write-Host ""
    Write-Host "=== Machine-wide update summary ==="
    foreach ($r in $results) {
        $glyph = switch ($r.State) {
            'Updated' { [char]0x2713 }   # checkmark
            'Failed'  { [char]0x2717 }   # X
            'Skipped' { [char]0x2192 }   # right-arrow
            default   { ' ' }
        }
        $color = switch ($r.State) {
            'Updated' { 'Green' }
            'Failed'  { 'Red' }
            'Skipped' { 'Yellow' }
            default   { $Host.UI.RawUI.ForegroundColor }
        }
        $reason = if ($r.Reason) { " -- $($r.Reason)" } else { '' }
        Write-Host ("  {0} {1,-14} {2}{3}" -f $glyph, $r.State, $r.Engine, $reason) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "Note: completers were not auto-refreshed for -All. Run Update-PackageCompletion if a CLI version bumped." -ForegroundColor DarkGray
}
