<#
.SYNOPSIS
    Light-suite Pester coverage for the private Get-BundlePackageObjects
    reconstruction helper.

.DESCRIPTION
    Get-BundlePackageObjects dot-sources a declarative bundle in-process to
    rebuild the real [Package] objects (scriptblocks intact) the update /
    uninstall paths need. When the dot-source THROWS -- most commonly because a
    stale cached [Package] class (from an older module version loaded earlier in
    the session) is missing a property the bundle references -- the helper must:

      * return an empty array so the caller's metadata fallback keeps the sweep
        alive, AND
      * emit a Write-Warning so the resulting loss of scriptblocks
        (CustomInstallScript / VerifyScript -> "Reinstall unavailable") is
        VISIBLE and explained, not a silent nondeterministic degradation.

    A bundle that simply never assigns $Packages (legacy imperative bundle) is a
    legitimate empty result and must stay quiet (no warning). This file pins both
    halves of that contract.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    function script:Invoke-GetBundlePackageObjects {
        param([string]$Path)
        # Run the private function in module scope and split the success stream
        # from the warning stream so each can be asserted independently.
        $records = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($p) Get-BundlePackageObjects -BundlePath $p
        } $Path 3>&1
        [pscustomobject]@{
            Objects  = @($records | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
            Warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        }
    }
}

Describe 'Get-BundlePackageObjects' -Tag 'Light', 'Module' {

    It 'warns and returns empty when the bundle dot-source throws' {
        # A bundle whose body throws before $Packages is assigned simulates the
        # stale-class cast failure. It must contain an Invoke-PackageInstall line
        # to pass the helper's declarative-bundle guard.
        $bundle = Join-Path $TestDrive 'Boom.ps1'
        Set-Content -LiteralPath $bundle -Value @'
throw 'simulated stale [Package] cast failure'
Invoke-PackageInstall -Packages $Packages -Bundle 'Boom'
'@
        $r = script:Invoke-GetBundlePackageObjects -Path $bundle

        $r.Objects.Count | Should -Be 0
        $r.Warnings.Count | Should -BeGreaterThan 0
        ($r.Warnings -join "`n") | Should -Match 'Boom'
        ($r.Warnings -join "`n") | Should -Match 'stale'
    }

    It 'stays quiet (no warning) for a legacy bundle that never assigns $Packages' {
        # Legitimate empty result -- imperative bundle with no $Packages. Must NOT
        # warn (that would be noise on every legacy-bundle dispatch).
        $bundle = Join-Path $TestDrive 'Legacy.ps1'
        Set-Content -LiteralPath $bundle -Value @'
# imperative bundle: does its own thing, never assigns $Packages
$null = $true
Invoke-PackageInstall -Packages $Packages -Bundle 'Legacy'
'@
        $r = script:Invoke-GetBundlePackageObjects -Path $bundle

        $r.Objects.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 0
    }

    It 'returns the real [Package] objects for a well-formed declarative bundle' {
        $bundle = Join-Path $TestDrive 'Good.ps1'
        Set-Content -LiteralPath $bundle -Value @'
$Packages = @(
    [Package]@{ Name = 'Alpha'; Installer = 'winget'; Id = 'Foo.Alpha' }
)
Invoke-PackageInstall -Packages $Packages -Bundle 'Good'
'@
        $r = script:Invoke-GetBundlePackageObjects -Path $bundle

        $r.Warnings.Count | Should -Be 0
        $r.Objects.Count | Should -Be 1
        $r.Objects[0].Name | Should -Be 'Alpha'
    }
}
