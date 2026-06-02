#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Light test for Invoke-PackageInstall's summary output: each row must
    be color-coded *and* glyph-marked by State so Failed rows can't be
    mistaken for success (color alone isn't colorblind-safe, so the
    glyph carries the same signal). The hand-rendered Write-Host table
    was retired in favour of the shared PackageResult format view.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'Invoke-PackageInstall result emission' -Tag 'Light','Module' {

    It 'emits a Green Installed PackageResult and a Red Failed PackageResult (glyph + color)' {
        $rendered = InModuleScope MarkMichaelis.ScoopBucket {
            # Two packages: one that succeeds (custom installer returns
            # success), one that fails (custom installer throws).
            $pkgs = @(
                [Package]@{ Name = 'GoodPkg'; Installer = 'custom'
                            CustomInstallScript = { @{ State = 'Installed'; Reason = $null } } }
                [Package]@{ Name = 'BadPkg';  Installer = 'custom'
                            CustomInstallScript = { throw 'simulated failure' } }
            )

            # BadPkg writes a structured ErrorRecord to the error stream;
            # silence it so the test focuses on the success-stream objects.
            $results = @(Invoke-PackageInstall -Bundle 'Test' -Packages $pkgs `
                -ErrorAction SilentlyContinue)

            $results.Count | Should -Be 2
            ($results | ForEach-Object { $_.GetType().Name } | Select-Object -Unique) | Should -Be 'PackageResult'

            $good = $results | Where-Object Name -eq 'GoodPkg'
            $bad  = $results | Where-Object Name -eq 'BadPkg'

            $good.Operation | Should -Be 'Install'
            $good.Status    | Should -Be 'Installed'
            $bad.Operation  | Should -Be 'Install'
            $bad.Status     | Should -Be 'Failed'
            $bad.Reason     | Should -Match 'simulated failure'
            $bad.Error      | Should -Not -BeNullOrEmpty
            $bad.Error.FullyQualifiedErrorId | Should -Match 'PackageInstallFailed'

            # Render the objects through the format view (color on) so the
            # glyph + ANSI color can be asserted end-to-end.
            $prev = $PSStyle.OutputRendering
            $PSStyle.OutputRendering = 'Ansi'
            try {
                ($results | Out-String -Width 200)
            } finally {
                $PSStyle.OutputRendering = $prev
            }
        }

        $goodLine = ($rendered -split "`n" | Where-Object { $_ -match 'GoodPkg' } | Select-Object -First 1)
        $badLine  = ($rendered -split "`n" | Where-Object { $_ -match 'BadPkg'  } | Select-Object -First 1)

        $goodLine | Should -Not -BeNullOrEmpty
        $badLine  | Should -Not -BeNullOrEmpty

        # Glyph carries the signal even when color is stripped: the new view
        # renders a glyph-only Status column (no text label), Name first.
        $goodLine | Should -Match ([regex]::Escape('+'))
        $goodLine | Should -Match 'GoodPkg'
        $badLine  | Should -Match ([regex]::Escape('x'))
        $badLine  | Should -Match 'BadPkg'

        # Color reinforces it: green for Installed, red for Failed. The glyph
        # is wrapped in the status color, so assert the colored glyph directly.
        $green = $PSStyle.Foreground.Green
        $red   = $PSStyle.Foreground.Red
        $goodLine | Should -Match ([regex]::Escape($green + '+'))
        $badLine  | Should -Match ([regex]::Escape($red + 'x'))
    }
}
