<#
.SYNOPSIS
    Light-suite Pester coverage for the private Get-BundlePackageObjects
    reconstruction helper.

.DESCRIPTION
    Get-BundlePackageObjects rebuilds the real [Package] objects (scriptblocks
    intact) the update / uninstall paths need. It does so WITHOUT running the
    bundle's imperative body: it locates the `$Packages = ...` assignment via the
    AST and evaluates ONLY that expression. This file pins the contract:

      * A well-formed declarative bundle yields its real [Package] objects.
      * A bundle's imperative side-effect body must NEVER run during a harvest
        (an UPDATE/UNINSTALL must not re-trigger install side effects).
      * A bundle that never assigns $Packages (legacy imperative bundle) is a
        legitimate empty result and must stay quiet (no warning).
      * When the $Packages assignment exists but fails to evaluate -- most
        commonly a stale cached [Package] class missing a referenced member --
        the helper returns @() AND emits a Write-Warning so the resulting loss of
        scriptblocks ("Reinstall unavailable") is VISIBLE, not a silent
        nondeterministic degradation.
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

    It 'does NOT execute the bundle imperative body (no install side effects on harvest)' {
        # A harvest reads only the $Packages assignment. The imperative remainder
        # (install/config side effects) must never run -- proven with a sentinel
        # file the imperative body would create if it executed.
        $sentinel = Join-Path $TestDrive ('sideeffect-' + [guid]::NewGuid().ToString('N') + '.flag')
        $bundle = Join-Path $TestDrive 'SideEffect.ps1'
        $body = @"
`$Packages = @(
    [Package]@{ Name = 'Alpha'; Installer = 'winget'; Id = 'Foo.Alpha' }
)
Invoke-PackageInstall -Packages `$Packages -Bundle 'SideEffect'
# imperative body that must NOT run during a harvest:
Set-Content -LiteralPath '$sentinel' -Value 'ran'
"@
        Set-Content -LiteralPath $bundle -Value $body
        $r = script:Invoke-GetBundlePackageObjects -Path $bundle

        $r.Objects.Count | Should -Be 1
        $r.Objects[0].Name | Should -Be 'Alpha'
        (Test-Path -LiteralPath $sentinel) | Should -BeFalse
    }

    It 'preserves scriptblocks (CustomInstallScript) on reconstructed packages' {
        $bundle = Join-Path $TestDrive 'WithScript.ps1'
        Set-Content -LiteralPath $bundle -Value @'
$Packages = @(
    [Package]@{
        Name                = 'Custom'
        Installer           = 'custom'
        UpdateMode          = 'Reinstall'
        CustomInstallScript = { 'installed' }
    }
)
Invoke-PackageInstall -Packages $Packages -Bundle 'WithScript'
'@
        $r = script:Invoke-GetBundlePackageObjects -Path $bundle

        $r.Warnings.Count | Should -Be 0
        $r.Objects.Count | Should -Be 1
        $r.Objects[0].CustomInstallScript | Should -Not -BeNullOrEmpty
        $r.Objects[0].CustomInstallScript.GetType().Name | Should -Be 'ScriptBlock'
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

    It 'warns and returns empty when the $Packages assignment fails to evaluate' {
        # Simulates the stale-class cast failure: the $Packages declaration exists
        # but its right-hand side throws during evaluation. The helper must return
        # @() (so the caller's metadata fallback keeps the sweep alive) AND warn so
        # the loss of scriptblocks is visible.
        $bundle = Join-Path $TestDrive 'Boom.ps1'
        Set-Content -LiteralPath $bundle -Value @'
$Packages = @(
    [Package]@{ Name = 'Alpha'; Installer = 'winget'; Id = (throw 'simulated stale [Package] cast failure') }
)
Invoke-PackageInstall -Packages $Packages -Bundle 'Boom'
'@
        $r = script:Invoke-GetBundlePackageObjects -Path $bundle

        $r.Objects.Count | Should -Be 0
        $r.Warnings.Count | Should -BeGreaterThan 0
        ($r.Warnings -join "`n") | Should -Match 'Boom'
        ($r.Warnings -join "`n") | Should -Match 'stale'
    }
}
