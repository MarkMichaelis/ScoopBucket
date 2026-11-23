#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Invariants over the real bucket for the per-package Default flag (#454).
#
# - Avalonia was made its own bundle precisely so it does not install by
#   default (#448/#449); Install-Package -Name '*' must keep it that way.
# - One package declared by two bundles (same Installer and Id) is one item to
#   the installer, so both declarations must agree on whether it is a default.
# - A package that only links to another declarative bundle (Installer scoop,
#   Id MarkMichaelis/<that bundle>) has no default of its own: '*' processes
#   the linked bundle directly. Its packages carry the defaults.

BeforeAll {
    $script:psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:packages = @(Get-Package -BucketPath $PSScriptRoot)
    $script:bundleNames = @($script:packages.Bundle | Sort-Object -Unique)
}

Describe 'Package defaults in the bucket (#454)' -Tag 'Light' {
    It 'keeps Avalonia out of the default set' {
        $avalonia = @($script:packages | Where-Object Bundle -eq 'Avalonia')
        $avalonia.Count | Should -BeGreaterThan 0
        foreach ($p in $avalonia) { $p.Default | Should -Be $false -Because "$($p.Name) must opt out" }
    }

    It 'gives a package declared by two bundles the same default in both' {
        $disagreements = foreach ($group in ($script:packages | Where-Object Id | Group-Object Installer, Id)) {
            if (@($group.Group.Default | Sort-Object -Unique).Count -gt 1) {
                "$($group.Name): " + (($group.Group | ForEach-Object { "$($_.Bundle)/$($_.Name)=$($_.Default)" }) -join ', ')
            }
        }
        $disagreements | Should -BeNullOrEmpty
    }

    It 'sets no default on a package that only links to another bundle' {
        $offenders = $script:packages | Where-Object {
            $_.Installer -eq 'scoop' -and
            $_.Id -match '^MarkMichaelis/(?<target>[^/]+)$' -and $Matches['target'] -in $script:bundleNames -and
            $_.Default -eq $false
        } | ForEach-Object { "$($_.Bundle)/$($_.Name) -> $($_.Id)" }
        $offenders | Should -BeNullOrEmpty
    }
}
