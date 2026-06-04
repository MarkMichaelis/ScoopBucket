#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Structure drift guard for the foldered bucket layout (issue #314).

.DESCRIPTION
    Enforces the group-folder organisation introduced in #300:
      - exactly the four aggregator manifests live at the bucket root;
      - every other manifest lives directly under a known group folder
        (os / client / developer / ai / admin).
    A manifest dropped loosely at root, or filed under an unknown or nested
    folder, fails this test until it is placed in a recognised group.
#>

BeforeAll {
    $script:bucketDir       = $PSScriptRoot
    $script:rootAggregators = @('AIAgents', 'ClientBasePackages', 'DeveloperBasePackages', 'OSBasePackages')
    $script:knownGroups     = @('admin', 'ai', 'client', 'developer', 'os')
}

Describe 'Bucket group-folder structure' -Tag 'Light', 'Bucket' {

    It 'keeps only the four aggregator manifests at bucket root' {
        $rootManifests = Get-ChildItem -Path $script:bucketDir -Filter '*.json' -File |
            ForEach-Object { $_.BaseName } | Sort-Object
        $rootManifests | Should -Be ($script:rootAggregators | Sort-Object) `
            -Because 'only the four group aggregators may sit at bucket root'
    }

    It 'files every member manifest directly under a known group folder' {
        $offenders = @()
        Get-ChildItem -Path $script:bucketDir -Filter '*.json' -File -Recurse |
            Where-Object { $_.DirectoryName -ne $script:bucketDir } |
            ForEach-Object {
                $rel   = $_.FullName.Substring($script:bucketDir.Length).TrimStart('\', '/')
                $parts = $rel -split '[\\/]'
                if ($parts.Count -ne 2 -or $script:knownGroups -notcontains $parts[0]) {
                    $offenders += $rel
                }
            }
        $offenders | Should -BeNullOrEmpty `
            -Because 'member manifests must live directly in os/client/developer/ai/admin'
    }

    It 'has a manifest in every known group folder' {
        foreach ($group in $script:knownGroups) {
            $groupDir = Join-Path $script:bucketDir $group
            (Get-ChildItem -Path $groupDir -Filter '*.json' -File).Count |
                Should -BeGreaterThan 0 -Because "$group should contain at least one manifest"
        }
    }
}
