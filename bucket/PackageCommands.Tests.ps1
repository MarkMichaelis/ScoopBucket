<#
.SYNOPSIS
    Phase 1 Pester scaffold for CLI-availability discovery (#45).

.DESCRIPTION
    Runs Get-PackageCommands.ps1 and reports — but does not enforce — which
    expected CLIs are available on PATH. Tagged Heavy + CliAvailability so
    the standard fast suite is unaffected.

    Run with:
        Invoke-Pester -Path .\bucket\PackageCommands.Tests.ps1 -Tag Heavy
#>

BeforeDiscovery {
    $script:DiscoveryScript = Join-Path (Split-Path -Parent $PSScriptRoot) `
        '.github\scripts\Get-PackageCommands.ps1'
}

Describe 'CLI availability discovery (Phase 1, non-failing)' -Tag 'Heavy','CliAvailability' {

    BeforeAll {
        $script:DiscoveryScript = Join-Path (Split-Path -Parent $PSScriptRoot) `
            '.github\scripts\Get-PackageCommands.ps1'
        $script:results = & $script:DiscoveryScript -Quiet
        if ($null -eq $script:results) { $script:results = @() }
        # Force array (single record edge case).
        $script:results = @($script:results)
    }

    It 'reports CLI availability for every discovered package (non-failing in phase 1)' {
        $script:results.Count | Should -BeGreaterThan 0

        $considered = @($script:results | Where-Object { $_.ExpectedCli })
        $available  = @($considered | Where-Object { $_.Available })
        Write-Host ""
        Write-Host "Discovered $($script:results.Count) package entries; " +
                   "$($considered.Count) have an expected CLI; " +
                   "$($available.Count) of those are on PATH."
        Write-Host ""
        $script:results |
            Format-Table Source, Package, ExpectedCli, Available, SourceScript -AutoSize |
            Out-String |
            Write-Host
    }

    Context 'Source: <_> (info only)' -ForEach @('winget','scoop','choco','psmodule') {
        It 'summarizes <_> entries' {
            $src = $_
            $rows = @($script:results | Where-Object { $_.Source -eq $src })
            $considered = @($rows | Where-Object { $_.ExpectedCli })
            $available  = @($considered | Where-Object { $_.Available })
            $missing    = @($considered | Where-Object { -not $_.Available })

            Write-Host ""
            Write-Host ("[{0}] total={1} with-expected-cli={2} available={3} missing={4}" -f `
                $src, $rows.Count, $considered.Count, $available.Count, $missing.Count)
            if ($missing.Count -gt 0) {
                Write-Host "  Missing CLIs:"
                foreach ($m in $missing) {
                    Write-Host ("    - {0,-40} expected ``{1}`` (from {2})" -f `
                        $m.PackageId, $m.ExpectedCli, $m.SourceScript)
                }
            }
            # Phase 1: report only, never fail.
            $true | Should -BeTrue
        }
    }
}
