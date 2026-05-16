#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Light test for Invoke-PackageInstall's summary output: each row must
    be color-coded *and* glyph-marked by State so Failed rows can't be
    mistaken for success (color alone isn't colorblind-safe, so the
    glyph carries the same signal).
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'Invoke-PackageInstall summary coloring' -Tag 'Light','Module' {

    It 'writes Failed rows in Red (with ✗ glyph) and Installed rows in Green (with ✓ glyph)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $captured = New-Object System.Collections.Generic.List[object]
            Mock Write-Host -MockWith {
                $captured.Add([pscustomobject]@{
                    Message = $Object
                    Color   = $ForegroundColor
                })
            }

            # Two packages: one that succeeds (custom installer returns
            # success), one that fails (custom installer throws).
            $pkgs = @(
                [Package]@{ Name = 'GoodPkg'; Installer = 'custom'
                            CustomInstallScript = { @{ State = 'Installed'; Reason = $null } } }
                [Package]@{ Name = 'BadPkg';  Installer = 'custom'
                            CustomInstallScript = { throw 'simulated failure' } }
            )

            # BadPkg writes to the error stream now; silence it so the
            # mock doesn't get confused but the summary still renders.
            $null = Invoke-PackageInstall -Bundle 'Test' -Packages $pkgs `
                -ErrorAction SilentlyContinue

            $summaryLines = @($captured | Where-Object { $_.Message -match '^\s{2}\S' -and $_.Color })
            $goodLine = $summaryLines | Where-Object Message -match 'GoodPkg' | Select-Object -Last 1
            $badLine  = $summaryLines | Where-Object Message -match 'BadPkg'  | Select-Object -Last 1

            $goodLine | Should -Not -BeNullOrEmpty
            $badLine  | Should -Not -BeNullOrEmpty
            $goodLine.Color   | Should -Be 'Green'
            $badLine.Color    | Should -Be 'Red'
            # Glyph carries the signal even when color is stripped.
            $goodLine.Message | Should -Match ([char]0x2713)   # ✓
            $badLine.Message  | Should -Match ([char]0x2717)   # ✗
        }
    }
}
