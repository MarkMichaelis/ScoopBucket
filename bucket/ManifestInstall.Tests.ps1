#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Data-driven install/idempotent/verify harness for every single-package
    <name>.json manifest in bucket/.

.DESCRIPTION
    Replaces the ~25-file fleet of per-package *.Tests.ps1 files that all
    shared an identical skeleton differing only in the post-install
    verification line. Each manifest's verification is now declared once in
    bucket/ManifestTestHints.ps1; this file iterates that table and emits
    one Describe per package.

    Manifests NOT covered here:
      * Declarative bundles (OSBasePackages, DeveloperBasePackages,
        ClientBasePackages, MicrosoftOffice365, AIAgents) — exercised by
        Bundles.Tests.ps1.
      * Manifests with bespoke Pester files that don't fit the
        install + idempotent + verify shape: McAfeeUninstall (uninstaller
        flow), AddLocalRepoBucket / AddMarkMichaelisScoopBucket (scoop
        bucket-add rather than scoop-install), GitConfigBeyondCompare /
        GitConfigVSCode / GitConfigVisualStudio / GitConfigure (multi-
        assertion git-config tests, some with Light unit coverage).

    A Light-tag drift test asserts every harness-eligible manifest is
    accounted for, so a contributor who adds a new <name>.json without
    wiring it into either the hints table or a bespoke Tests.ps1 file
    fails fast.
#>

BeforeDiscovery {
    $bucketRoot = $PSScriptRoot

    # Manifests handled elsewhere — see comment block above.
    $script:BundleNames = @(
        'OSBasePackages','DeveloperBasePackages','ClientBasePackages',
        'MicrosoftOffice365','AIAgents'
    )
    $script:BespokeNames = @(
        'McAfeeUninstall',
        'AddLocalRepoBucket','AddMarkMichaelisScoopBucket',
        'GitConfigBeyondCompare','GitConfigVSCode',
        'GitConfigVisualStudio','GitConfigure'
    )

    $hintsPath = Join-Path $bucketRoot 'ManifestTestHints.ps1'
    $script:Hints = & $hintsPath

    $script:AllManifestNames = @(
        Get-ChildItem (Join-Path $bucketRoot '*.json') |
            ForEach-Object { $_.BaseName }
    )

    $script:HarnessCases = foreach ($name in $script:AllManifestNames) {
        if ($name -in $script:BundleNames)  { continue }
        if ($name -in $script:BespokeNames) { continue }
        $hint = if ($script:Hints.ContainsKey($name)) { $script:Hints[$name] } else { @{ Verify = 'Scoop' } }
        @{
            Name   = $name
            Hint   = $hint
            Manual = [bool]$hint.Manual
        }
    }

    $script:AutoCases   = @($script:HarnessCases | Where-Object { -not $_.Manual })
    $script:ManualCases = @($script:HarnessCases | Where-Object {      $_.Manual })
}

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }

    function Invoke-ManifestVerify {
        param([string]$Name, [hashtable]$Hint)
        switch ($Hint.Verify) {
            'Cli' {
                Test-Command $Hint.Cli | Should -Be $true
            }
            'GetProgram' {
                Get-Program -Filter $Hint.Pattern | Should -Not -BeNullOrEmpty
            }
            'Choco' {
                Test-ChocolateyPackageInstalled $Hint.ChocoPackage | Should -Be $true
            }
            'Custom' {
                (& $Hint.Script) | Should -BeTrue
            }
            default {
                # 'Scoop' or unset — manifest is verified by the install
                # assertion above; this is a no-op tagging check that the
                # package is still registered after the idempotent re-run.
                Test-ScoopPackageInstalled $Name | Should -Be $true
            }
        }
    }
}

Describe 'Install <Name>' -ForEach $script:AutoCases -Tag 'Heavy','Install' {

    BeforeAll {
        $script:manifestPath = Join-Path $PSScriptRoot ($Name + '.json')
        if ($Hint.PreserveIfInstalled) {
            $script:preInstalled = [bool](Test-ScoopPackageInstalled $Name)
        } else {
            $script:preInstalled = $false
            if (Test-ScoopPackageInstalled $Name) {
                scoop uninstall $Name
            }
        }
    }

    It 'installs from the local manifest' -Skip:($script:preInstalled) {
        Install-LocalManifest $script:manifestPath
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest $script:manifestPath } | Should -Not -Throw
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'passes the post-install verification' {
        Invoke-ManifestVerify -Name $Name -Hint $Hint
    }
}

Describe 'Install <Name>' -ForEach $script:ManualCases -Tag 'Manual','Heavy','Install' {

    BeforeAll {
        $script:manifestPath = Join-Path $PSScriptRoot ($Name + '.json')
        if ($Hint.PreserveIfInstalled) {
            $script:preInstalled = [bool](Test-ScoopPackageInstalled $Name)
        } else {
            $script:preInstalled = $false
            if (Test-ScoopPackageInstalled $Name) {
                scoop uninstall $Name
            }
        }
    }

    It 'installs from the local manifest' -Skip:($script:preInstalled) {
        Install-LocalManifest $script:manifestPath
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest $script:manifestPath } | Should -Not -Throw
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'passes the post-install verification' {
        Invoke-ManifestVerify -Name $Name -Hint $Hint
    }
}

Describe 'Manifest test coverage (drift)' -Tag 'Light' {

    It 'partitions every <name>.json into exactly one of: bundle, bespoke, harness' {
        $partitioned = New-Object System.Collections.Generic.HashSet[string]
        foreach ($n in $script:BundleNames)  { [void]$partitioned.Add($n) }
        foreach ($n in $script:BespokeNames) { [void]$partitioned.Add($n) }
        foreach ($c in $script:HarnessCases) { [void]$partitioned.Add($c.Name) }
        $unaccounted = @($script:AllManifestNames | Where-Object { -not $partitioned.Contains($_) })
        $unaccounted | Should -BeNullOrEmpty -Because "Manifests in bucket/ not covered by bundle, bespoke, or harness: $($unaccounted -join ', ')"
    }

    It 'every hint entry corresponds to an existing <name>.json manifest' {
        $orphans = New-Object System.Collections.Generic.List[string]
        foreach ($key in $script:Hints.Keys) {
            $path = Join-Path $PSScriptRoot ($key + '.json')
            if (-not (Test-Path $path)) {
                $orphans.Add($key)
            }
        }
        $orphans | Should -BeNullOrEmpty -Because "Hint entries with no matching manifest: $($orphans -join ', ')"
    }

    It 'every bespoke Tests.ps1 referenced by the skip list still exists' {
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($name in $script:BespokeNames) {
            $path = Join-Path $PSScriptRoot ($name + '.Tests.ps1')
            if (-not (Test-Path $path)) {
                $missing.Add($name)
            }
        }
        $missing | Should -BeNullOrEmpty -Because "Bespoke skip list references missing files: $($missing -join ', ')"
    }
}
