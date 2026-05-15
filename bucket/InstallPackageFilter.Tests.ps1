#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester regression test: Install-Package -Name <pkg> must filter the
# dispatched bundle down to <pkg> + its DependsOn closure. Earlier the
# bundle's first-line `Import-Module ... -Force` re-exported the
# module's Invoke-PackageInstall into the global function table,
# overwriting the launch script's filter shim, and the bundle's
# trailing `Invoke-PackageInstall -Packages $Packages` ran the
# unfiltered driver  installing every package in the bundle.

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    Import-Module $script:psd1 -Force

    # Build a throwaway bucket dir with a single bundle containing 3
    # packages. The bundle mirrors the real bundles' shape: top-level
    # Import-Module of the working-tree module, $Packages literal, and
    # a trailing Invoke-PackageInstall call.
    $script:tmpBucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-test-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:tmpBucket | Out-Null

    $bundleText = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{ Name = 'alpha'; Installer = 'winget'; Id = 'Test.Alpha' }
    [Package]@{ Name = 'bravo'; Installer = 'winget'; Id = 'Test.Bravo'; DependsOn = @('alpha') }
    [Package]@{ Name = 'charlie'; Installer = 'winget'; Id = 'Test.Charlie' }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'TestBundle'
"@
    Set-Content -Path (Join-Path $script:tmpBucket 'TestBundle.ps1') -Value $bundleText -Encoding UTF8
}

AfterAll {
    if ($script:tmpBucket -and (Test-Path $script:tmpBucket)) {
        Remove-Item -LiteralPath $script:tmpBucket -Recurse -Force -ErrorAction Ignore
    }
}

Describe 'Install-Package -Name filter' -Tag 'Light', 'Module' {
    It 'dispatches only the requested package when no DependsOn closure' {
        $output = Install-Package -Name 'charlie' -DryRun -SkipCompletion -BucketPath $script:tmpBucket *>&1 |
            Out-String

        $output | Should -Match '=== Invoke-PackageInstall: TestBundle \(1 packages\) ==='
        $output | Should -Match '\[install\] \[winget\] charlie'
        $output | Should -Not -Match '\[install\] \[winget\] alpha'
        $output | Should -Not -Match '\[install\] \[winget\] bravo'
    }

    It 'dispatches the requested package plus its transitive DependsOn closure' {
        $output = Install-Package -Name 'bravo' -DryRun -SkipCompletion -BucketPath $script:tmpBucket *>&1 |
            Out-String

        $output | Should -Match '=== Invoke-PackageInstall: TestBundle \(2 packages\) ==='
        $output | Should -Match '\[install\] \[winget\] alpha'
        $output | Should -Match '\[install\] \[winget\] bravo'
        $output | Should -Not -Match '\[install\] \[winget\] charlie'
    }
}
