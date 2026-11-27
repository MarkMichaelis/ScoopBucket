#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Sub-items in the package picker (#559). A package's Companions and
# DependsOn are shown under it:
#   - a companion is on by default (its own Default), checked and unchecked
#     with its package, and can be turned off on its own; it is never a
#     top-level item of its group.
#   - a dependency is locked on ([!]) while a package that needs it is
#     checked. It stays a top-level item of its group unless another
#     top-level group lists it as an item of its own.
#   - every choco package needs Chocolatey, shown as a locked sub-item.
#   - a package declared Required is always installed and cannot be unchecked.
#
# Fixture layout:
#   RootC.ps1  app (Companions 'app cfg', 'app cli'), app cfg, app cli
#              (optional), agent (DependsOn runtime), runtime (choco),
#              core (Required)
#   RootD.ps1  runtime (the same package, a top-level item here)
#              svc (Companions 'svc cfg', installed by this bucket's own
#              manifest SvcCfg), kit user (DependsOn 'Kit bundle', a link)
#   RootD.ps1  also links 'Kit bundle'
#   dev/Chocolatey.json  the bare manifest that installs choco
#   dev/SvcCfg.json, dev/Kit.ps1 (k1)

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psd1 = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:M = Get-Module MarkMichaelis.ScoopBucket

    function script:New-FixtureManifest {
        param([string]$Dir, [string]$Name, [string]$Script)
        $manifest = [ordered]@{
            version   = '1.00.000'
            url       = @('https://example.invalid/placeholder')
            installer = @{ script = @($Script) }
        }
        Set-Content -LiteralPath (Join-Path $Dir "$Name.json") -Value ($manifest | ConvertTo-Json -Depth 4) -Encoding UTF8
    }

    function script:New-FixtureBundle {
        param([string]$Dir, [string]$Bundle, [string]$PackagesText)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $text = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
$PackagesText
)

Invoke-PackageInstall -Packages `$Packages -Bundle '$Bundle'
"@
        Set-Content -LiteralPath (Join-Path $Dir "$Bundle.ps1") -Value $text -Encoding UTF8
        New-FixtureManifest -Dir $Dir -Name $Bundle -Script "& `"`$dir\\$Bundle.ps1`""
    }

    $script:bucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-subitems-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:bucket | Out-Null
    New-FixtureBundle -Dir $script:bucket -Bundle 'RootC' -PackagesText @'
    [Package]@{ Name = 'app';     Installer = 'winget'; Id = 'Test.App'; Companions = @('app cfg', 'app cli') }
    [Package]@{ Name = 'app cfg'; Installer = 'winget'; Id = 'Test.AppCfg' }
    [Package]@{ Name = 'app cli'; Installer = 'winget'; Id = 'Test.AppCli'; Default = $false }
    [Package]@{ Name = 'agent';   Installer = 'winget'; Id = 'Test.Agent'; DependsOn = @('runtime') }
    [Package]@{ Name = 'runtime'; Installer = 'choco';  Id = 'test-runtime' }
    [Package]@{ Name = 'core';    Installer = 'winget'; Id = 'Test.Core'; Required = $true }
    [Package]@{ Name = 'svc';     Installer = 'winget'; Id = 'Test.Svc'; Companions = @('svc cfg') }
    [Package]@{ Name = 'svc cfg'; Installer = 'scoop';  Id = 'MarkMichaelis/SvcCfg' }
    [Package]@{ Name = 'kit user';    Installer = 'winget'; Id = 'Test.KitUser'; DependsOn = @('Kit bundle') }
    [Package]@{ Name = 'Kit bundle';  Installer = 'scoop';  Id = 'MarkMichaelis/Kit' }
'@
    New-FixtureBundle -Dir $script:bucket -Bundle 'RootD' -PackagesText @'
    [Package]@{ Name = 'runtime'; Installer = 'choco';  Id = 'test-runtime' }
    [Package]@{ Name = 'Kit bundle';  Installer = 'scoop';  Id = 'MarkMichaelis/Kit' }
'@
    $dev = Join-Path $script:bucket 'dev'
    New-Item -ItemType Directory -Path $dev | Out-Null
    New-FixtureManifest -Dir $dev -Name 'Chocolatey' -Script "Write-Host 'choco'"
    New-FixtureManifest -Dir $dev -Name 'SvcCfg' -Script "Write-Host 'svc cfg'"
    New-FixtureBundle -Dir $dev -Bundle 'Kit' -PackagesText "    [Package]@{ Name = 'k1'; Installer = 'winget'; Id = 'Test.K1' }"

    $script:catalog = & $script:M { param($b) Get-PackageCatalog -BucketPath $b } $script:bucket
    $script:rootC = $script:catalog.Roots | Where-Object Name -eq 'Root C'
    $script:rootD = $script:catalog.Roots | Where-Object Name -eq 'Root D'
    $script:child = { param($parent, $name) $parent.Children | Where-Object Name -eq $name }
}

AfterAll {
    if ($script:bucket -and (Test-Path $script:bucket)) { Remove-Item -LiteralPath $script:bucket -Recurse -Force -ErrorAction Ignore }
}

Describe 'Picker sub-items in the tree (#559)' -Tag 'Light', 'Module' {
    It 'lists a package''s companions under it, not as items of the group' {
        $app = & $script:child $script:rootC 'app'
        $app.Children.Name | Should -Be @('app cfg', 'app cli')
        $app.Children | ForEach-Object { $_.Role | Should -Be 'Companion' }
        $script:rootC.Children.Name | Should -Not -Contain 'app cfg'
        $script:rootC.Children.Name | Should -Not -Contain 'app cli'
    }

    It 'lists a companion installed by one of this bucket''s manifests' {
        $svc = & $script:child $script:rootC 'svc'
        (& $script:child $svc 'svc cfg').Role | Should -Be 'Companion'
        $script:rootC.Children.Name | Should -Not -Contain 'svc cfg'
    }

    It 'lists a dependency that is another bundle under the package that needs it' {
        $kitUser = & $script:child $script:rootC 'kit user'
        (& $script:child $kitUser 'k1').Role | Should -Be 'Dependency'
        $script:rootC.Children.Name | Should -Not -Contain 'k1'
        $script:rootD.Children.Name | Should -Contain 'k1'
        (& $script:child $script:rootD 'k1').Role | Should -BeNullOrEmpty -Because 'the copy under kit user carries the role, not the shared node'
    }

    It 'lists a dependency under the package that needs it' {
        $agent = & $script:child $script:rootC 'agent'
        $runtime = & $script:child $agent 'runtime'
        $runtime.Role | Should -Be 'Dependency'
    }

    It 'keeps a dependency out of the group''s items when another group lists it as its own' {
        $script:rootC.Children.Name | Should -Not -Contain 'runtime'
        $script:rootD.Children.Name | Should -Contain 'runtime'
    }

    It 'shows Chocolatey as a locked sub-item of every choco package' {
        $runtime = & $script:child $script:rootD 'runtime'
        $choco = & $script:child $runtime 'Chocolatey'
        $choco.Role | Should -Be 'Dependency'
        $choco.Kind | Should -Be 'Manifest'
    }

    It 'does not offer Chocolatey again under "Also available"' {
        $script:catalog.Roots.Name | Should -Not -Contain 'Dev'
    }
}

Describe 'Install-Package names a bundle file that is gone (#559)' -Tag 'Light', 'Module' {
    It 'reports the missing file instead of an empty-array binding error' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PickerInteractive { $true }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-InstalledPackageMap { @{} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Show-PackagePicker {
            $gone = Join-Path $TestDrive 'gone\RootC.ps1'
            [pscustomobject]@{
                ByBundle  = @{ $gone = [pscustomobject]@{ BundlePath = $gone; Bundle = 'RootC'; Names = @('app'); Skip = @() } }
                Manifests = @()
            }
        }

        $rows = @(Install-Package -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket -ErrorAction SilentlyContinue -ErrorVariable errs)

        $failed = $rows | Where-Object Status -eq 'Failed'
        $failed | Should -Not -BeNullOrEmpty
        ($failed.Reason + ' ' + ($errs -join ' ')) | Should -Match 'not found'
        ($errs -join ' ') | Should -Not -Match 'empty array'
    }
}

Describe 'Picker sub-item behaviour (#559)' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:state = & $script:M { param($c) New-PickerState -Catalog $c -Installed @{} } $script:catalog
        $script:box = { param($node) & $script:M { param($s, $n) Get-PickerBox -State $s -Node $n } $script:state $node }
        $script:toggle = { param($node) & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state $node }
        $script:plan = { & $script:M { param($s) Get-PickerPlan -State $s } $script:state }
        $script:app = & $script:child $script:rootC 'app'
        $script:cfg = & $script:child $script:app 'app cfg'
        $script:cli = & $script:child $script:app 'app cli'
    }

    It 'checks a companion by its own default' {
        & $script:box $script:cfg | Should -Be '[x]'
        & $script:box $script:cli | Should -Be '[ ]'
    }

    It 'lets a companion be turned off while its package stays checked' {
        & $script:toggle $script:cfg
        & $script:box $script:cfg | Should -Be '[ ]'
        & $script:box $script:app | Should -Be '[x]'
    }

    It 'leaves an unchecked companion out of the install' {
        & $script:toggle $script:cfg
        $rootC = (& $script:plan).ByBundle.Values | Where-Object Bundle -eq 'RootC'
        $rootC.Names | Should -Contain 'app'
        $rootC.Skip | Should -Contain 'app cfg'
        $rootC.Skip | Should -Contain 'app cli'
    }

    It 'unchecks a package''s companions with it, and checks the default ones again with it' {
        & $script:toggle $script:app
        & $script:box $script:cfg | Should -Be '[ ]'
        & $script:toggle $script:app
        & $script:box $script:cfg | Should -Be '[x]'
        & $script:box $script:cli | Should -Be '[ ]'
    }

    It 'keeps a dependency installed when it is unchecked while a package that needs it is checked' {
        $runtime = & $script:child (& $script:child $script:rootC 'agent') 'runtime'
        & $script:box $runtime | Should -Be '[x]'
        & $script:toggle $runtime
        & $script:box $runtime | Should -Be '[!]'
    }

    It 'locks Chocolatey on while a choco package is needed' {
        $runtime = & $script:child (& $script:child $script:rootC 'agent') 'runtime'
        & $script:box (& $script:child $runtime 'Chocolatey') | Should -Be '[!]'
        (& $script:plan).Manifests | Should -Contain 'Chocolatey'
    }

    It 'keeps a Required package on even when everything is unchecked' {
        & $script:M { param($s) Set-PickerSelection -State $s -Mode None } $script:state
        & $script:box (& $script:child $script:rootC 'core') | Should -Be '[!]'
        ((& $script:plan).ByBundle.Values | Where-Object Bundle -eq 'RootC').Names | Should -Contain 'core'
    }

    It 'does not install a companion the owner unchecked' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PickerInteractive { $true }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-InstalledPackageMap { @{} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Show-PackagePicker {
            & (Get-Module MarkMichaelis.ScoopBucket) {
                param($c, $i)
                $state = New-PickerState -Catalog $c -Installed $i
                Set-PickerSelection -State $state -Mode None
                $app = ($c.Roots | Where-Object Name -eq 'Root C').Children | Where-Object Name -eq 'app'
                Switch-PickerNode -State $state -Node $app
                Switch-PickerNode -State $state -Node ($app.Children | Where-Object Name -eq 'app cfg')
                Get-PickerPlan -State $state
            } $Catalog $Installed
        }

        $rows = @(Install-Package -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)

        $rows.Name | Should -Contain 'app'
        $rows.Name | Should -Not -Contain 'app cfg'
        $rows.Name | Should -Not -Contain 'app cli'
    }

    It 'opens a package with sub-items like a group' {
        $rows = & $script:M { param($s) Get-PickerRows -State $s } $script:state
        [void]$script:state.Expanded.Add(($rows | Where-Object { $_.Node.Name -eq 'Root C' }).Path)
        $rows = & $script:M { param($s) Get-PickerRows -State $s } $script:state
        $appRow = $rows | Where-Object { $_.Node.Name -eq 'app' } | Select-Object -First 1
        $appRow | Should -Not -BeNullOrEmpty
        $rows.Node.Name | Should -Not -Contain 'app cfg'
        [void]$script:state.Expanded.Add($appRow.Path)
        $rows = & $script:M { param($s) Get-PickerRows -State $s } $script:state
        ($rows | Where-Object { $_.Node.Name -eq 'app cfg' }).Depth | Should -Be ($appRow.Depth + 1)
    }

    It 'marks a package row that unfolds, the way a group row is marked' {
        $rows = & $script:M { param($s) Get-PickerRows -State $s } $script:state
        [void]$script:state.Expanded.Add(($rows | Where-Object { $_.Node.Name -eq 'Root C' }).Path)
        $lines = (& $script:M { param($s) Format-PickerScreen -State $s -Width 100 -Height 30 } $script:state).Text
        ($lines | Where-Object { $_ -match '\] app\b' }) | Should -Match '\] app\s+\+'
        ($lines | Where-Object { $_ -match '\] core\b' }) | Should -Not -Match '\+'
    }

    It 'says a Required package is required' {
        $rows = & $script:M { param($s) Get-PickerRows -State $s } $script:state
        [void]$script:state.Expanded.Add(($rows | Where-Object { $_.Node.Name -eq 'Root C' }).Path)
        $lines = (& $script:M { param($s) Format-PickerScreen -State $s -Width 100 -Height 30 } $script:state).Text
        ($lines | Where-Object { $_ -match '\] core\b' }) | Should -Match 'required'
        ($lines | Where-Object { $_ -match '\] agent\b' }) | Should -Not -Match 'required'
    }
}
