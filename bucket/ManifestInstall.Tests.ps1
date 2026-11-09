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
        GitConfigGitHubCli / GitConfigVSCode / GitConfigVisualStudio /
        GitConfigure (multi-assertion git-config tests, some with Light unit
        coverage).

    Light-tag drift tests check the skip lists and hints against the
    manifests on disk, and fail if discovery finds no harness cases.

    Discovery is recursive: member manifests live in the category
    subfolders (os/ client/ developer/ ai/ admin/, #302). Until #513 this
    file globbed only bucket\*.json, which matches just the bundles, so the
    harness generated zero cases. Discovery data reaches the run-phase
    drift tests through -ForEach, because $script: variables set in
    BeforeDiscovery do not survive into the run phase (they read as $null,
    which left every drift check looping over nothing).

    WARNING -- Heavy/Install is destructive by design: each case uninstalls
    the app if present, and Install-LocalManifest re-points the registered
    MarkMichaelis scoop bucket at this working copy. Run it on a test
    machine. Install-LocalManifest is passed the bucket root explicitly:
    its default (the manifest's own folder) predates the foldered layout
    and would rewrite url entries to bucket\<category>\<category>\... .
#>

BeforeDiscovery {
    $bucketRoot = $PSScriptRoot

    # Manifests handled elsewhere — see comment block above.
    $bundleNames = @(
        'OSBasePackages','DeveloperBasePackages','ClientBasePackages',
        'MicrosoftOffice365','AIAgents'
    )
    $bespokeNames = @(
        'McAfeeUninstall',
        'AddLocalRepoBucket','AddMarkMichaelisScoopBucket',
        'GitConfigBeyondCompare','GitConfigGitHubCli','GitConfigVSCode',
        'GitConfigVisualStudio','GitConfigure'
    )

    $hints = & (Join-Path $bucketRoot 'ManifestTestHints.ps1')

    # -Filter '*.json' alone would also match '.jsonc' via 8.3 short names.
    $manifests = @(
        Get-ChildItem -Path $bucketRoot -Filter '*.json' -File -Recurse |
            Where-Object { $_.Extension -eq '.json' }
    )

    $harnessCases = @(
        foreach ($m in $manifests) {
            $name = $m.BaseName
            if ($name -in $bundleNames)  { continue }
            if ($name -in $bespokeNames) { continue }
            $hint = if ($hints.ContainsKey($name)) { $hints[$name] } else { @{ Verify = 'Scoop' } }
            @{
                Name   = $name
                Path   = $m.FullName
                Hint   = $hint
                Manual = [bool]$hint.Manual
            }
        }
    )

    $script:AutoCases   = @($harnessCases | Where-Object { -not $_.Manual })
    $script:ManualCases = @($harnessCases | Where-Object {      $_.Manual })

    $script:Discovery = @{
        BundleNames   = $bundleNames
        BespokeNames  = $bespokeNames
        HintNames     = @($hints.Keys)
        ManifestNames = @($manifests | ForEach-Object { $_.BaseName })
        HarnessCases  = $harnessCases
        TestFileNames = @(
            Get-ChildItem -Path $bucketRoot -Filter '*.Tests.ps1' -File -Recurse |
                ForEach-Object { $_.Name }
        )
    }
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
        $script:manifestPath = $Path
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
        Install-LocalManifest $script:manifestPath -LocalBucketRoot $PSScriptRoot
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest $script:manifestPath -LocalBucketRoot $PSScriptRoot } | Should -Not -Throw
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'passes the post-install verification' {
        Invoke-ManifestVerify -Name $Name -Hint $Hint
    }
}

Describe 'Install <Name>' -ForEach $script:ManualCases -Tag 'Manual','Heavy','Install' {

    BeforeAll {
        $script:manifestPath = $Path
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
        Install-LocalManifest $script:manifestPath -LocalBucketRoot $PSScriptRoot
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest $script:manifestPath -LocalBucketRoot $PSScriptRoot } | Should -Not -Throw
        Test-ScoopPackageInstalled $Name | Should -Be $true
    }

    It 'passes the post-install verification' {
        Invoke-ManifestVerify -Name $Name -Hint $Hint
    }
}

Describe 'Manifest test coverage (drift)' -Tag 'Light' -ForEach @(@{ D = $script:Discovery }) {

    It 'discovers the member manifests in the category subfolders (#302, #513)' {
        @($D.HarnessCases).Count | Should -BeGreaterThan 0 -Because 'an empty harness means the Install suite above silently runs nothing'
        @($D.HarnessCases | ForEach-Object { $_.Name }) | Should -Contain 'Codex' -Because 'ai/Codex.json is a harness manifest'
        foreach ($c in $D.HarnessCases) {
            Test-Path -LiteralPath $c.Path -PathType Leaf | Should -BeTrue -Because "case '$($c.Name)' must point at its manifest"
        }
    }

    It 'has no two manifests with the same name across the category subfolders' {
        # Names key the skip lists, the hints and scoop's app names, so a
        # duplicate would silently collapse two manifests into one case.
        $dupes = @($D.ManifestNames | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        $dupes | Should -BeNullOrEmpty -Because "Duplicate manifest names: $($dupes -join ', ')"
    }

    It 'every bundle and bespoke name corresponds to an existing manifest' {
        $stale = @(@($D.BundleNames) + @($D.BespokeNames) | Where-Object { $_ -notin $D.ManifestNames })
        $stale | Should -BeNullOrEmpty -Because "Skip-list names with no matching manifest: $($stale -join ', ')"
    }

    It 'every hint entry corresponds to an existing manifest' {
        $orphans = @($D.HintNames | Where-Object { $_ -notin $D.ManifestNames })
        $orphans | Should -BeNullOrEmpty -Because "Hint entries with no matching manifest: $($orphans -join ', ')"
    }

    It 'every bespoke Tests.ps1 referenced by the skip list still exists' {
        $missing = @($D.BespokeNames | Where-Object { "$_.Tests.ps1" -notin $D.TestFileNames })
        $missing | Should -BeNullOrEmpty -Because "Bespoke skip list references missing files: $($missing -join ', ')"
    }
}
