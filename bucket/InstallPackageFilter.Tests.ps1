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

    # Sibling .json so the completer's manifest-name scan picks up
    # 'TestBundle' as a bundle name (mirrors the production layout
    # where every bundle .ps1 has a sibling .json so scoop can install
    # it).
    $bundleManifest = @{
        '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
        version   = '1.00.000'
        url       = @('https://example.invalid/test-bundle')
        installer = @{ script = @('& "$dir\\TestBundle.ps1"') }
    }
    Set-Content -LiteralPath (Join-Path $script:tmpBucket 'TestBundle.json') `
        -Value ($bundleManifest | ConvertTo-Json -Depth 4) -Encoding UTF8
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

Describe 'Install-Package <BundleName> dispatch' -Tag 'Light', 'Module' {
    # The user types the bundle name (e.g. `Install-Package OSBasePackages`)
    # instead of an individual package name. We install every package in
    # that bundle — no -Name filter, full $Packages collection.

    It 'installs every package in the bundle when given the bundle name' {
        $output = Install-Package -Name 'TestBundle' -DryRun -SkipCompletion -BucketPath $script:tmpBucket *>&1 |
            Out-String

        $output | Should -Match "dispatching bundle 'TestBundle' \(all packages\)"
        $output | Should -Match '=== Invoke-PackageInstall: TestBundle \(3 packages\) ==='
        $output | Should -Match '\[install\] \[winget\] alpha'
        $output | Should -Match '\[install\] \[winget\] bravo'
        $output | Should -Match '\[install\] \[winget\] charlie'
    }
}

Describe 'Install-Package <BareManifest> fallback' -Tag 'Light', 'Module' {
    # A `<name>.json` exists in the bucket but no [Package] declares it
    # and no declarative bundle owns it. Install-Package must fall
    # through to `scoop install <name>` so the manifest's
    # installer.script runs verbatim.

    BeforeAll {
        # Drop a json with no sibling .ps1 into the temp bucket.
        $manifest = @{
            '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
            version   = '1.00.000'
            url       = @('https://example.invalid/bare-manifest')
            installer = @{ script = @('Write-Host bare-manifest install') }
        }
        Set-Content -LiteralPath (Join-Path $script:tmpBucket 'BareManifestPkg.json') `
            -Value ($manifest | ConvertTo-Json -Depth 4) -Encoding UTF8
    }

    It 'lists bundle, package, and bare-manifest names in the completer' {
        $names = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($p) Get-PackageNameSuggestion -BucketPath $p
        } $script:tmpBucket
        $names | Should -Contain 'TestBundle'
        $names | Should -Contain 'alpha'
        $names | Should -Contain 'BareManifestPkg'
    }

    It 'logs scoop-install dispatch under -DryRun without invoking scoop' {
        $output = Install-Package -Name 'BareManifestPkg' -DryRun -SkipCompletion -BucketPath $script:tmpBucket *>&1 |
            Out-String
        $output | Should -Match "dispatching manifest 'BareManifestPkg' via scoop install"
        $output | Should -Match '\[DryRun\] scoop install BareManifestPkg'
    }

    It 'throws a helpful error when neither package, bundle, nor manifest matches' {
        { Install-Package -Name 'NoSuchThing' -DryRun -SkipCompletion -BucketPath $script:tmpBucket } |
            Should -Throw -ExpectedMessage "*no bundle declares a package named 'NoSuchThing'*"
    }
}

Describe 'Install-Package -- Companions cascade' -Tag 'Light', 'Module' {

    BeforeAll {
        $script:repoRoot3 = Split-Path -Parent $PSScriptRoot
        $script:psd1c     = Join-Path $script:repoRoot3 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'

        $script:tmpBucket3 = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-install-comp-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpBucket3 | Out-Null

        $bundleText = @"
`$scoopBucketPsd1 = '$($script:psd1c -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{ Name = 'Owner'; Installer = 'winget'; Id = 'Test.Owner'; Companions = @('OwnerCli') }
    [Package]@{
        Name        = 'OwnerCli'
        Installer   = 'winget'
        Id          = 'Test.OwnerCli'
        CliCommands = @('ownercli')
        Completion  = 'native'
        DependsOn   = @('Owner')
        NativeCommandScript = { 'noop' }
        ExpectedCompletions = @{ ownercli = @('--help') }
    }
    [Package]@{ Name = 'Unrelated'; Installer = 'winget'; Id = 'Test.Unrelated' }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'CompInstallBundle'
"@
        Set-Content -Path (Join-Path $script:tmpBucket3 'CompInstallBundle.ps1') -Value $bundleText -Encoding UTF8

        $bundleManifest = @{
            '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
            version   = '1.00.000'
            url       = @('https://example.invalid/comp-install-bundle')
            installer = @{ script = @('& "$dir\\CompInstallBundle.ps1"') }
        }
        Set-Content -LiteralPath (Join-Path $script:tmpBucket3 'CompInstallBundle.json') `
            -Value ($bundleManifest | ConvertTo-Json -Depth 4) -Encoding UTF8
    }

    AfterAll {
        if ($script:tmpBucket3 -and (Test-Path $script:tmpBucket3)) {
            Remove-Item -LiteralPath $script:tmpBucket3 -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'pulls the companion CLI into the plan when the desktop owner is requested, owner first' {
        $output = Install-Package -Name 'Owner' -DryRun -SkipCompletion -BucketPath $script:tmpBucket3 *>&1 |
            Out-String

        $output | Should -Match '=== Invoke-PackageInstall: CompInstallBundle \(2 packages\) ==='
        $output | Should -Match '\[install\] \[winget\] Owner'
        $output | Should -Match '\[install\] \[winget\] OwnerCli'
        # Owner must come BEFORE companion (install order: owner first).
        $ownerIdx = $output.IndexOf('[install] [winget] Owner')
        $cliIdx   = $output.IndexOf('[install] [winget] OwnerCli')
        $ownerIdx | Should -BeGreaterThan -1
        $ownerIdx | Should -BeLessThan $cliIdx
        $output | Should -Not -Match '\[install\] \[winget\] Unrelated'
    }
}
