#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Install-Package -Name '*' and companions (#563), matching the picker's
# defaults:
#   - an optional companion (Default = $false) is not installed with its
#     package: Git's "Link ~\.ssh to Data" stays off;
#   - a companion of an optional package is not a default on its own:
#     Visual Studio's Git settings wait for Visual Studio;
#   - either is still upgraded where installed, and installed when named.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psd1 = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force

    $script:bucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-defcomp-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:bucket | Out-Null
    $text = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
Import-Module `$scoopBucketPsd1 -Force

`$Packages = [Package[]]@(
    [Package]@{ Name = 'app';     Installer = 'winget'; Id = 'Test.App'; Companions = @('app cfg', 'app opt') }
    [Package]@{ Name = 'app cfg'; Installer = 'winget'; Id = 'Test.AppCfg' }
    [Package]@{ Name = 'app opt'; Installer = 'winget'; Id = 'Test.AppOpt'; Default = `$false }
    [Package]@{ Name = 'ide';     Installer = 'winget'; Id = 'Test.Ide'; Default = `$false; Companions = @('ide cfg') }
    [Package]@{ Name = 'ide cfg'; Installer = 'winget'; Id = 'Test.IdeCfg' }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'Comp'
"@
    Set-Content -LiteralPath (Join-Path $script:bucket 'Comp.ps1') -Value $text -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:bucket 'Comp.json') -Value '{ "version": "1.00.000", "url": ["https://example.invalid/placeholder"], "installer": { "script": ["& \"$dir\\Comp.ps1\""] } }' -Encoding UTF8
    $script:bundle = [pscustomobject]@{ Bundle = 'Comp'; BundlePath = (Join-Path $script:bucket 'Comp.ps1') }

    $script:resolve = {
        param([string[]]$Installed = @(), [hashtable]$Requested = @{})
        & (Get-Module MarkMichaelis.ScoopBucket) {
            param($b, $installed, $requested)
            Mock Get-PackagePresence { [pscustomobject]@{ Present = ($installed -contains $Package.Name); Reason = '' } }
            Resolve-DefaultInstallSet -Bundle @($b) -Requested $requested
        } $script:bundle $Installed $Requested
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:bucket -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "Install-Package -Name '*' and companions (#563)" -Tag 'Light', 'Module' {
    It 'installs a package with its default companion' {
        $plan = & $script:resolve
        $plan.Names[$script:bundle.BundlePath] | Should -Contain 'app'
        $plan.Names[$script:bundle.BundlePath] | Should -Contain 'app cfg'
    }

    It 'leaves an optional companion out, and tells the installer to skip it' {
        $plan = & $script:resolve
        $plan.Names[$script:bundle.BundlePath] | Should -Not -Contain 'app opt'
        $plan.Skip[$script:bundle.BundlePath] | Should -Contain 'app opt'
        $plan.Skipped.Name | Should -Contain 'app opt'
    }

    It 'leaves out the companion of an optional package' {
        $plan = & $script:resolve
        $plan.Names[$script:bundle.BundlePath] | Should -Not -Contain 'ide cfg'
        ($plan.Skipped | Where-Object Name -eq 'ide cfg').Reason | Should -Match "'ide'"
    }

    It 'upgrades an optional companion that is installed' {
        $plan = & $script:resolve -Installed 'app opt'
        $plan.Names[$script:bundle.BundlePath] | Should -Contain 'app opt'
        @($plan.Skip[$script:bundle.BundlePath]) | Should -Not -Contain 'app opt'
    }

    It 'installs the default companion of an optional package that is named' {
        $plan = & $script:resolve -Requested @{ $script:bundle.BundlePath = @('ide') }
        @($plan.Skip[$script:bundle.BundlePath]) | Should -Not -Contain 'ide cfg'
    }

    It 'installs an optional companion that is named' {
        $plan = & $script:resolve -Requested @{ $script:bundle.BundlePath = @('app opt') }
        @($plan.Skip[$script:bundle.BundlePath]) | Should -Not -Contain 'app opt'
    }
}

Describe "Install-Package -Name '*' hands the skip list to the installer (#563)" -Tag 'Light', 'Module' {
    It 'does not install an optional companion with its package' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackagePresence { [pscustomobject]@{ Present = $false; Reason = '' } }
        $rows = @(Install-Package -Name '*' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket 3>$null 6>$null)
        @($rows | Where-Object Name -eq 'app').Status | Should -Not -Contain 'Skipped'
        @($rows | Where-Object Name -eq 'app opt').Status | Should -Be @('Skipped')
        @($rows | Where-Object Name -eq 'ide cfg').Status | Should -Be @('Skipped')
    }
}

Describe 'Install-Package -Name <package> and its optional companions (#563)' -Tag 'Light', 'Module' {
    It 'leaves out an optional companion of a package named on its own' {
        $rows = @(Install-Package -Name 'app' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket 3>$null 6>$null)
        $rows.Name | Should -Contain 'app cfg'
        $rows.Name | Should -Not -Contain 'app opt'
    }

    It 'installs the default companion of an optional package named on its own' {
        $rows = @(Install-Package -Name 'ide' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket 3>$null 6>$null)
        $rows.Name | Should -Contain 'ide cfg'
    }

    It 'installs an optional companion named alongside its package' {
        $rows = @(Install-Package -Name 'app', 'app opt' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket 3>$null 6>$null)
        $rows.Name | Should -Contain 'app opt'
    }
}
