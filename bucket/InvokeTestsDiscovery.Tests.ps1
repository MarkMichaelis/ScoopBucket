<#
.SYNOPSIS
    Light-suite guard for Invoke-Tests.ps1 test discovery.

.DESCRIPTION
    After the bucket group reorganization (#300) member tests live in group
    subfolders (bucket/os, bucket/developer, bucket/admin, ...). Invoke-Tests.ps1
    must discover them recursively, otherwise they silently drop out of the CI
    Light gate (./bucket/Invoke-Tests.ps1 -Tag Light).

    These tests drive Invoke-Tests.ps1 via its -ListOnly switch (which returns the
    discovered FileInfo set without running Pester) and assert that subfolder
    member tests are included. Reverting the runner to a non-recursive glob makes
    these assertions fail for a behavioral reason (the subfolder file is absent
    from the discovered set).
#>

BeforeAll {
    $script:runner = Join-Path $PSScriptRoot 'Invoke-Tests.ps1'
}

Describe 'Invoke-Tests.ps1 discovery' -Tag 'Light', 'Unit' {

    It 'discovers member tests located in group subfolders' {
        $discovered = & $script:runner -ListOnly
        $relative = $discovered | ForEach-Object {
            $_.FullName.Substring($PSScriptRoot.Length).TrimStart('\', '/')
        }

        # At least one test must come from a known group subfolder. A
        # non-recursive glob would only ever return bucket-root tests.
        ($relative | Where-Object { $_ -match '[\\/]' }) | Should -Not -BeNullOrEmpty
    }

    It 'discovers a specific subfolder test by pattern' {
        # McAfeeUninstall.Tests.ps1 lives under bucket/os/. A non-recursive
        # runner returns nothing for this pattern (and warns "No test files
        # matched"); the recursive runner finds it.
        $discovered = & $script:runner -Pattern 'McAfeeUninstall' -ListOnly
        @($discovered).Count | Should -BeGreaterThan 0
        ($discovered.FullName -join ';') | Should -Match 'os[\\/]McAfeeUninstall\.Tests\.ps1'
    }

    It 'still discovers bucket-root engine tests' {
        $discovered = & $script:runner -Pattern 'Package' -ListOnly
        ($discovered.Name) | Should -Contain 'Package.Tests.ps1'
    }
}
