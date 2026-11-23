#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Install-Package -Name '*' converges a machine (#454): every default package of
# every declarative bundle is installed or upgraded, while a package that opts
# out with Default = $false is only upgraded when it is already installed.
# Config-only bare manifests are never swept in, and a package that links to
# another declarative bundle (a "wrapper") is not dispatched, because '*'
# processes that bundle directly and a wrapper install would ignore its
# packages' defaults.

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    Import-Module $script:psd1 -Force

    function script:New-FixtureBundle {
        param([string]$Bucket, [string]$Bundle, [string]$PackagesText)
        $text = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
$PackagesText
)

Invoke-PackageInstall -Packages `$Packages -Bundle '$Bundle'
"@
        Set-Content -LiteralPath (Join-Path $Bucket "$Bundle.ps1") -Value $text -Encoding UTF8
        New-FixtureManifest -Bucket $Bucket -Name $Bundle -Script "& `"`$dir\\$Bundle.ps1`""
    }

    function script:New-FixtureManifest {
        param([string]$Bucket, [string]$Name, [string]$Script)
        $manifest = @{
            version   = '1.00.000'
            url       = @('https://example.invalid/placeholder')
            installer = @{ script = @($Script) }
        }
        Set-Content -LiteralPath (Join-Path $Bucket "$Name.json") `
            -Value ($manifest | ConvertTo-Json -Depth 4) -Encoding UTF8
    }

    $script:bucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-defaults-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:bucket | Out-Null

    New-FixtureBundle -Bucket $script:bucket -Bundle 'Base' -PackagesText @'
    [Package]@{ Name = 'alpha';        Installer = 'winget'; Id = 'Test.Alpha' }
    [Package]@{ Name = 'bravo';        Installer = 'winget'; Id = 'Test.Bravo'; Default = $false }
    [Package]@{ Name = 'charlie';      Installer = 'winget'; Id = 'Test.Charlie'; DependsOn = @('delta') }
    [Package]@{ Name = 'delta';        Installer = 'winget'; Id = 'Test.Delta'; Default = $false }
    [Package]@{ Name = 'Extra bundle'; Installer = 'scoop';  Id = 'MarkMichaelis/Extra' }
    [Package]@{ Name = 'kilo';         Installer = 'scoop';  Id = 'extras/Extra' }
'@
    # One package, optional in the bundle walked first and default in the last.
    New-FixtureBundle -Bucket $script:bucket -Bundle 'Aaa' -PackagesText @'
    [Package]@{ Name = 'twin optional'; Installer = 'winget'; Id = 'Test.Twin'; Default = $false }
'@
    New-FixtureBundle -Bucket $script:bucket -Bundle 'Zzz' -PackagesText @'
    [Package]@{ Name = 'twin default'; Installer = 'winget'; Id = 'Test.Twin' }
'@
    New-FixtureBundle -Bucket $script:bucket -Bundle 'Optional' -PackagesText @'
    [Package]@{ Name = 'hotel'; Installer = 'winget'; Id = 'Test.Hotel'; Default = $false }
'@
    New-FixtureBundle -Bucket $script:bucket -Bundle 'Extra' -PackagesText @'
    [Package]@{ Name = 'echo';       Installer = 'winget'; Id = 'Test.Echo' }
    [Package]@{ Name = 'foxtrot';    Installer = 'winget'; Id = 'Test.Foxtrot'; Default = $false }
    [Package]@{ Name = 'alpha twin'; Installer = 'winget'; Id = 'Test.Alpha' }
'@
    # A config-only manifest: no declarative bundle behind it.
    New-FixtureManifest -Bucket $script:bucket -Name 'ConfigOnly' -Script "Write-Host 'one-shot machine change'"

    $script:onlyManifests = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-defaults-empty-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:onlyManifests | Out-Null
    New-FixtureManifest -Bucket $script:onlyManifests -Name 'ConfigOnly' -Script "Write-Host 'one-shot machine change'"

    # A bundle whose declaration cannot be ordered (DependsOn names a package
    # it does not declare), next to a healthy one.
    $script:brokenBucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-defaults-broken-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:brokenBucket | Out-Null
    New-FixtureBundle -Bucket $script:brokenBucket -Bundle 'Broken' -PackagesText @'
    [Package]@{ Name = 'india'; Installer = 'winget'; Id = 'Test.India'; DependsOn = @('ghost') }
'@
    New-FixtureBundle -Bucket $script:brokenBucket -Bundle 'Good' -PackagesText @'
    [Package]@{ Name = 'juliet'; Installer = 'winget'; Id = 'Test.Juliet' }
'@
}

AfterAll {
    foreach ($dir in @($script:bucket, $script:onlyManifests, $script:brokenBucket)) {
        if ($dir -and (Test-Path $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Ignore }
    }
}

Describe 'Get-Package reports each package''s default (#454)' -Tag 'Light', 'Module' {
    It 'reports Default = $true unless the package opts out' {
        $packages = @(Get-Package -BucketPath $script:bucket)
        ($packages | Where-Object Name -eq 'alpha').Default | Should -Be $true
        ($packages | Where-Object Name -eq 'bravo').Default | Should -Be $false
    }
}

Describe 'Install-Package -Name ''*'' (#454)' -Tag 'Light', 'Module' {
    BeforeEach {
        # Nothing is installed unless a test says otherwise.
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackagePresence {
            @{ Present = $false; Reason = 'not installed (test)' }
        }
    }

    Context 'on a machine with none of the optional packages' {
        BeforeAll {
            $script:rows = @(Install-Package -Name '*' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)
        }

        It 'installs every default package of every declarative bundle' {
            $installed = @($script:rows | Where-Object Status -ne 'Skipped').Name
            $installed | Should -Contain 'alpha'
            $installed | Should -Contain 'charlie'
            $installed | Should -Contain 'echo'
        }

        It 'does not install an optional package that is absent, and says how to get it' {
            $bravo = @($script:rows | Where-Object Name -eq 'bravo')
            $bravo.Count     | Should -Be 1
            $bravo[0].Status | Should -Be 'Skipped'
            $bravo[0].Reason | Should -Match "Install-Package -Name 'bravo'"
            ($script:rows | Where-Object Name -eq 'foxtrot').Status | Should -Be 'Skipped'
        }

        It 'still installs an optional package that a default package depends on' {
            $delta = @($script:rows | Where-Object Name -eq 'delta')
            $delta.Count     | Should -Be 1
            $delta[0].Status | Should -Not -Be 'Skipped'
        }

        It 'does not dispatch a package that only links to another bundle' {
            $script:rows.Name | Should -Not -Contain 'Extra bundle'
        }

        It 'installs a package declared by two bundles only once' {
            @($script:rows | Where-Object { $_.Id -eq 'Test.Alpha' }).Count | Should -Be 1
        }

        It 'installs a package one bundle marks optional and another default, once, whatever the walk order' {
            $twin = @($script:rows | Where-Object { $_.Id -eq 'Test.Twin' })
            $twin.Count     | Should -Be 1
            $twin[0].Status | Should -Not -Be 'Skipped'
        }

        It 'installs a scoop package whose name only resembles a bundle in this bucket' {
            $kilo = @($script:rows | Where-Object Name -eq 'kilo')
            $kilo.Count     | Should -Be 1
            $kilo[0].Status | Should -Not -Be 'Skipped'
        }

        It 'reports a bundle whose packages are all optional and absent as skipped rows only' {
            $hotel = @($script:rows | Where-Object Name -eq 'hotel')
            $hotel.Count     | Should -Be 1
            $hotel[0].Status | Should -Be 'Skipped'
        }
    }

    It 'installs a bundle named explicitly in full, and does not also run the link to it' {
        $rows = @(Install-Package -Name '*', 'Extra' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)

        $rows.Name | Should -Not -Contain 'Extra bundle'
        ($rows | Where-Object Name -eq 'foxtrot').Status | Should -Not -Be 'Skipped'
        @($rows | Where-Object { $_.Id -eq 'Test.Alpha' }).Count | Should -Be 1
    }

    It 'previews with -WhatIf exactly as with -DryRun' {
        $dry    = @(Install-Package -Name '*' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)
        $whatIf = @(Install-Package -Name '*' -WhatIf -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)

        ($whatIf | ForEach-Object { "$($_.Name)=$($_.Status)" } | Sort-Object) |
            Should -Be ($dry | ForEach-Object { "$($_.Name)=$($_.Status)" } | Sort-Object)
    }

    It 'reports a bundle it cannot plan as failed and still converges the others' {
        $rows = @(Install-Package -Name '*' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:brokenBucket `
                -ErrorAction SilentlyContinue -ErrorVariable planErrors)

        ($rows | Where-Object Name -eq 'juliet').Status | Should -Not -Be 'Skipped'
        $broken = @($rows | Where-Object { $_.Bundle -eq 'Broken' })
        $broken.Status | Should -Contain 'Failed'
        @($planErrors | Where-Object { $_.FullyQualifiedErrorId -like 'PackageInstallFailed*' }).Count | Should -BeGreaterThan 0
    }

    It 'upgrades an optional package that is already installed' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackagePresence {
            @{ Present = $true; Reason = 'installed (test)' }
        } -ParameterFilter { $Package.Name -eq 'bravo' }

        $rows = @(Install-Package -Name '*' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)

        $bravo = @($rows | Where-Object Name -eq 'bravo')
        $bravo.Count     | Should -Be 1
        $bravo[0].Status | Should -Not -Be 'Skipped'
    }

    It 'leaves an optional package alone when it cannot tell whether it is installed' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackagePresence {
            @{ Present = $null; Reason = 'probe failed (test)' }
        } -ParameterFilter { $Package.Name -eq 'foxtrot' }

        $rows = @(Install-Package -Name '*' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)

        $foxtrot = @($rows | Where-Object Name -eq 'foxtrot')
        $foxtrot[0].Status | Should -Be 'Skipped'
        $foxtrot[0].Reason | Should -Match 'could not tell'
    }

    It 'installs an optional package that is also named explicitly' {
        $rows = @(Install-Package -Name '*', 'bravo' -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)

        $bravo = @($rows | Where-Object Name -eq 'bravo')
        $bravo.Count     | Should -Be 1
        $bravo[0].Status | Should -Not -Be 'Skipped'
    }

    It 'asks about presence only for optional packages' {
        $null = Install-Package -Name '*' -DryRun -SkipCompletion -BucketPath $script:bucket

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Get-PackagePresence -Times 0 -Exactly `
            -ParameterFilter { $Package.Name -in @('alpha', 'charlie', 'echo') }
    }

    It 'never runs a config-only manifest' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-ScoopCommand { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage { @{ State = 'Installed'; Reason = $null } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-ScoopPackage  { @{ State = 'Installed'; Reason = $null } }

        $null = Install-Package -Name '*' -SkipCompletion -BucketPath $script:bucket

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-ScoopCommand -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-ScoopPackage -Times 0 -Exactly `
            -ParameterFilter { $Package.Id -eq 'MarkMichaelis/Extra' }
    }

    It 'fails loudly when the bucket has no declarative bundle to converge' {
        { Install-Package -Name '*' -DryRun -SkipCompletion -BucketPath $script:onlyManifests } |
            Should -Throw '*no declarative bundle*'
    }
}
