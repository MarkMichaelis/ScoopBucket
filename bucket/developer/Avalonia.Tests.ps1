#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Avalonia member manifest (issue #448).

.DESCRIPTION
    Avalonia Accelerate Community Edition tooling, as its OWN OPT-IN bundle.

    The opt-in requirement is the headline contract: Avalonia is a niche UI
    framework, so it must NOT install on every developer machine. An entry in
    DeveloperBasePackages would do exactly that, so a test here asserts the
    package is absent from that bundle -- the guard that pins the requirement
    rather than merely documenting it.

    "Community edition of Avalonia" resolves to Avalonia Accelerate
    **Community Edition** -- the named free tier of Avalonia's commercial
    tooling. Of its four tools, only DevTools is both free at the Community
    level AND installable non-interactively: it ships as the .NET global tool
    `AvaloniaUI.DeveloperTools`, exposing the `avdt` command.

    These tests pin that resolution so it cannot silently drift:

      * `AvaloniaUI.Parcel` must NOT be the installed id -- its own NuGet
        listing states "CLI is not available in free community license", so
        installing the CLI tool would hand the user a binary the community
        licence does not cover.
      * The engine must stay `dotnetTool`: no winget or scoop package for
        Avalonia tooling exists (probed 2026-10-02), so a future edit to
        `winget`/`scoop` would be installing something else entirely.
      * Scope must stay `user`, because `dotnet tool install -g` lands in
        %USERPROFILE%\.dotnet\tools and has no machine-wide variant.
      * `avdt` ships no completion generator and has no PSCompletions catalog
        entry, so completion must be a hand-curated native completer --
        mirroring aspire/python/adb elsewhere in the bucket.
      * The free MIT `Avalonia.Templates` must be installed too, mirroring
        Aspire's `Aspire.ProjectTemplates` step, so `dotnet new avalonia.mvvm`
        works after the bundle installs.
      * DependsOn must stay EMPTY. It is same-bundle-only -- Resolve-PackageOrder
        throws "DependsOn 'x' which is not defined in this bundle" -- so naming
        'dotnet' (which lives in DeveloperBasePackages) would break every
        install of this bundle. Naming 'Visual Studio' would additionally drag
        a multi-GB IDE in through the -Name transitive closure (#450).

    Tagged 'Light' -- parses the manifest and harvests the declarative
    [Package] entries; no install side effects.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    $script:ManifestPath = Join-Path $PSScriptRoot 'Avalonia.json'
    $script:Manifest     = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    $script:BundlePath   = Join-Path $PSScriptRoot 'Avalonia.ps1'
    $script:BundleSource = Get-Content -Raw -LiteralPath $script:BundlePath

    # Whole-bucket harvest: needed both to find the Avalonia bundle and to
    # prove the package is absent from DeveloperBasePackages.
    $script:AllPkgs  = @(Get-Package -BucketPath (Split-Path -Parent $PSScriptRoot))
    $script:Avalonia = @($script:AllPkgs | Where-Object { $_.Bundle -eq 'Avalonia' })
}

Describe 'Avalonia manifest' -Tag 'Light' {

    It 'runs the bundle script rather than an inline installer line' {
        $script:Manifest.installer.script | Should -Match 'Avalonia\.ps1'
    }

    It 'ships a non-empty version in the major.minor.patch shape the README mandates' {
        [string]$script:Manifest.version | Should -Match '^\d+\.\d{2}\.\d{3}$'
    }

    It 'points its url at its own bundle script' {
        @($script:Manifest.url) | Should -Contain 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/bucket/developer/Avalonia.ps1'
    }

    It 'declares the bundle by name so Install-Package -Name Avalonia resolves it' {
        # A bare config-only manifest would only be installable via scoop --
        # Install-Package cannot resolve bare manifests in subfolders (#452).
        # Declaring $Packages + Invoke-PackageInstall -Bundle 'Avalonia' is what
        # makes the normal bundle path work.
        $script:BundleSource | Should -Match "Invoke-PackageInstall\s+-Packages\s+\`$Packages\s+-Bundle\s+'Avalonia'"
    }
}

Describe 'Avalonia is opt-in, not installed by default (issue #448)' -Tag 'Light','Bundle' {

    It 'is NOT a package in DeveloperBasePackages' {
        # The headline requirement: an entry there would install Avalonia on
        # every developer machine.
        @($script:AllPkgs |
            Where-Object { $_.Bundle -eq 'DeveloperBasePackages' -and $_.Name -eq 'Avalonia Developer Tools' }) |
            Should -BeNullOrEmpty -Because 'Avalonia must be opt-in, not part of the default developer install'
    }

    It 'is NOT installed by any other bundle either' {
        @($script:AllPkgs | Where-Object { $_.Id -eq 'AvaloniaUI.DeveloperTools' }).Bundle |
            Should -Be @('Avalonia') -Because 'only the opt-in Avalonia bundle may install it'
    }

    It 'exists as a bundle of its own containing exactly one package' {
        $script:Avalonia.Count | Should -Be 1
        $script:Avalonia[0].Name | Should -Be 'Avalonia Developer Tools'
    }
}

Describe 'Avalonia Accelerate Community Edition package contract (issue #448)' -Tag 'Light','Bundle' {

    It 'installs the Community-tier DevTools global dotnet tool' {
        $script:Avalonia[0].Installer | Should -Be 'dotnetTool'
        $script:Avalonia[0].Id        | Should -Be 'AvaloniaUI.DeveloperTools'
    }

    It 'does NOT install AvaloniaUI.Parcel, whose CLI is excluded from the community licence' {
        $script:Avalonia[0].Id | Should -Not -Be 'AvaloniaUI.Parcel'
        @($script:AllPkgs | Where-Object { $_.Id -like 'AvaloniaUI.Parcel*' }) | Should -BeNullOrEmpty
    }

    It "declares Scope='user' because dotnet tool install -g is per-user only" {
        $script:Avalonia[0].Scope | Should -Be 'user'
    }

    It 'declares CliCommands=avdt' {
        @($script:Avalonia[0].CliCommands) | Should -Be @('avdt')
    }

    It "uses Completion='auto' with a hand-curated NativeCommandScript" {
        $script:Avalonia[0].Completion             | Should -Be 'auto'
        $script:Avalonia[0].HasNativeCommandScript | Should -BeTrue
    }

    It 'declares non-empty ExpectedCompletions for avdt covering the documented subcommands' {
        $script:Avalonia[0].ExpectedCompletions.ContainsKey('avdt') | Should -BeTrue
        foreach ($expected in 'mcp', 'uninstall') {
            $script:Avalonia[0].ExpectedCompletions['avdt'] | Should -Contain $expected
        }
    }

    It 'NativeCommandScript renders a Register-ArgumentCompleter -Native for avdt' {
        $rendered = $script:Avalonia[0].NativeCommandOutputs['avdt']
        $rendered | Should -Not -BeNullOrEmpty
        $rendered | Should -Match 'Register-ArgumentCompleter\s+-Native'
        $rendered | Should -Match '-CommandName\s+avdt'
    }

    It 'NativeCommandScript offers every ExpectedCompletion it promises' {
        $rendered = $script:Avalonia[0].NativeCommandOutputs['avdt']
        foreach ($expected in @($script:Avalonia[0].ExpectedCompletions['avdt'])) {
            $rendered | Should -BeLike "*'$expected'*"
        }
    }

    It 'declares NO DependsOn, because DependsOn is same-bundle-only' {
        # Resolve-PackageOrder throws "DependsOn 'dotnet' which is not defined
        # in this bundle" -- verified empirically -- so naming dotnet here
        # would break every install of this bundle. Aspire.ps1 does the same.
        @($script:Avalonia[0].DependsOn) | Should -BeNullOrEmpty
    }

    It 'does NOT depend on Visual Studio, so a selective install cannot drag in a multi-GB IDE' {
        # Resolve-PackageOrder takes the TRANSITIVE CLOSURE of DependsOn
        # whenever -Name is passed, and Install-Package always passes -Name
        # (#450). avdt needs only the .NET SDK.
        $script:Avalonia[0].DependsOn | Should -Not -Contain 'Visual Studio'
    }

    It 'the bundle is still installable: Resolve-PackageOrder does not throw on its packages' {
        # Guards the DependsOn trap directly rather than by inspection: a
        # cross-bundle DependsOn makes Invoke-PackageInstall throw before
        # installing anything.
        $pkgObjs = InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ BundlePath = $script:BundlePath } {
            param($BundlePath)
            @(Get-BundlePackageObjects -BundlePath $BundlePath)
        }
        $pkgObjs.Count | Should -Be 1
        { InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Pkgs = $pkgObjs } {
            param($Pkgs)
            Resolve-PackageOrder -Packages ([Package[]]$Pkgs) | Out-Null
        } } | Should -Not -Throw
    }

    It 'installs the free MIT Avalonia project templates via a PostInstallScript' {
        $script:Avalonia[0].HasPostInstallScript | Should -BeTrue
        $script:BundleSource | Should -Match 'dotnet new install Avalonia\.Templates'
    }

    It 'records the licensing resolution in Notes so the choice is auditable' {
        $script:Avalonia[0].Notes | Should -Match 'Community'
        $script:Avalonia[0].Notes | Should -Match 'Parcel'
        $script:Avalonia[0].Notes | Should -Match 'OPT-IN'
    }
}
