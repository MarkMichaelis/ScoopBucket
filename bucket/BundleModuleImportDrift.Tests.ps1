#requires -Version 7.0
# ----------------------------------------------------------------------------
# Drift guard (Pester v5, Light/Meta): every shipped bundle .ps1 that imports
# MarkMichaelis.ScoopBucket in its header MUST use the single canonical
# "scoop-portable" region block (see README / #390). The only permitted
# variation is the branch-1 repo-checkout depth (..\module for a bundle that
# sits directly in bucket\, ..\..\module for one under a bucket\<group>\ folder).
#
# Reverting a bundle to the legacy 2-line header, hand-editing one header out of
# sync, or adding a new bundle that copies the old header all fail here.
# ----------------------------------------------------------------------------

Set-StrictMode -Version Latest

Describe 'All bundle headers use the canonical scoop-portable module import' -Tag 'Light', 'Meta' {

    BeforeDiscovery {
        $script:BucketRoot = $PSScriptRoot
        # A "bundle header" is any non-test .ps1 under bucket\ that resolves the
        # module for import -- detected by the $scoopBucketPsd1 variable (present
        # in both the legacy and canonical headers) or a by-name Import-Module of
        # the module (the legacy fallback). Helper scripts that never import the
        # module are intentionally excluded.
        $script:BundleCases = @(
            Get-ChildItem -Path $script:BucketRoot -Recurse -Filter '*.ps1' -File |
                Where-Object { $_.Name -notlike '*.Tests.ps1' } |
                Where-Object {
                    $t = Get-Content -Raw -LiteralPath $_.FullName
                    ($t -match '\$scoopBucketPsd1') -or ($t -match 'Import-Module\s+MarkMichaelis\.ScoopBucket\b')
                } |
                ForEach-Object {
                    [pscustomobject]@{
                        Name = $_.FullName.Substring($script:BucketRoot.Length + 1)
                        Path = $_.FullName
                    }
                }
        )
    }

    BeforeAll {
        $script:BucketRoot = $PSScriptRoot

        # The one true header, with {DEPTH} standing in for the branch-1 repo
        # checkout depth. Compared line-for-line (LF-normalized) against every
        # bundle's region block after its depth token is masked.
        $script:Canonical = @(
            '#region MarkMichaelis.ScoopBucket bundle module import (scoop-portable; see README)'
            '$scoopBucketModule = ''MarkMichaelis.ScoopBucket'''
            '$scoopBucketPsd1 = Join-Path $PSScriptRoot "{DEPTH}\$scoopBucketModule\$scoopBucketModule.psd1"'
            'if (-not (Test-Path $scoopBucketPsd1)) {'
            '    $scoopBucketRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $PSScriptRoot ''..\..\..'' }'
            '    $scoopBucketFound = Get-ChildItem -Path (Join-Path $scoopBucketRoot "buckets\*\module\$scoopBucketModule\$scoopBucketModule.psd1") -ErrorAction SilentlyContinue | Select-Object -First 1'
            '    if ($scoopBucketFound) { $scoopBucketPsd1 = $scoopBucketFound.FullName }'
            '}'
            'if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module $scoopBucketModule -Force }'
            '#endregion MarkMichaelis.ScoopBucket bundle module import'
        ) -join "`n"

        # Runtime recompute of the discovery set, so the "finds the shipped set"
        # guard below cannot vacuously pass on a bad glob.
        $script:BundleFiles = @(
            Get-ChildItem -Path $script:BucketRoot -Recurse -Filter '*.ps1' -File |
                Where-Object { $_.Name -notlike '*.Tests.ps1' } |
                Where-Object {
                    $t = Get-Content -Raw -LiteralPath $_.FullName
                    ($t -match '\$scoopBucketPsd1') -or ($t -match 'Import-Module\s+MarkMichaelis\.ScoopBucket\b')
                }
        )

        function Get-Region {
            param([string]$Text)
            $m = [regex]::Match($Text, '(?ms)^#region MarkMichaelis\.ScoopBucket bundle module import.*?^#endregion[^\r\n]*')
            if ($m.Success) { return ($m.Value -replace "`r`n", "`n") }
            return ''
        }

        function Get-ExpectedDepth {
            param([string]$RelPath)
            $sep = [System.IO.Path]::DirectorySeparatorChar
            $subdirs = $RelPath.Split($sep).Count - 1
            $dotdots = $subdirs + 1
            return (('..' + [System.IO.Path]::DirectorySeparatorChar) * $dotdots) + 'module'
        }
    }

    It 'finds the full shipped bundle set (guards the discovery predicate)' {
        $script:BundleFiles.Count | Should -Be 16 -Because 'the discovery predicate must match exactly the 16 production bundles -- update this count deliberately when adding or removing a bundle'
    }

    It '<_.Name> uses the canonical region block (only branch-1 depth may differ)' -ForEach $script:BundleCases {
        $text = Get-Content -Raw -LiteralPath $_.Path
        $region = Get-Region -Text $text
        $region | Should -Not -BeNullOrEmpty -Because "$($_.Name) must carry the canonical #region..#endregion header (legacy 2-line headers are forbidden)"
        $masked = [regex]::Replace($region, '(\.\.\\){1,2}module', '{DEPTH}')
        $masked | Should -BeExactly $script:Canonical -Because "$($_.Name) header drifted from the canonical scoop-portable block"
    }

    It '<_.Name> branch-1 depth matches its folder location' -ForEach $script:BundleCases {
        $text = Get-Content -Raw -LiteralPath $_.Path
        $region = Get-Region -Text $text
        $depthMatch = [regex]::Match($region, 'Join-Path \$PSScriptRoot "((?:\.\.\\){1,2}module)\\')
        $depthMatch.Success | Should -BeTrue -Because "$($_.Name) must have a branch-1 Join-Path depth"
        $expected = Get-ExpectedDepth -RelPath $_.Name
        $depthMatch.Groups[1].Value | Should -BeExactly $expected -Because "$($_.Name): a bundle in a group folder uses ..\..\module; a top-level bundle uses ..\module"
    }
}
