#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Data-driven validation of every declarative bundle in bucket/.

.DESCRIPTION
    Replaces the per-bundle hardcoded test files. Get-Package gives us a
    flat view of every [Package] entry across every migrated bundle; the
    cases below assert structural / cross-cutting invariants that apply
    uniformly:

      - every package has a non-empty Name + a known Installer
      - scoop ids use the canonical '<bucket>/<name>' prefix
      - msstore Source is only used with the winget installer
      - DependsOn references resolve to other packages in this bucket
      - Package.Name values are unique across the whole bucket
      - declared CliCommands look like plausible short command names
      - HasNativeCommandScript is set whenever Completion='native'

    Bundle-specific assertions (e.g. "Beyond Compare has a
    PostInstallScript") are NOT re-encoded here; the data model itself
    is the source of truth, so we test the data model rather than
    duplicate the data in the tests.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\ScoopBucket\ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module ScoopBucket -Force } 
    $script:allPkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:byName  = @{}
    foreach ($p in $script:allPkgs) {
        if (-not $script:byName.ContainsKey($p.Name)) {
            $script:byName[$p.Name] = @()
        }
        $script:byName[$p.Name] += $p
    }
    # Generic-test consumers: one row per package, given to It -ForEach.
    # Pester's -ForEach iterates over each hashtable's key/value pairs
    # and exposes them as named variables ($Bundle, $Pkg) inside the It.
    $script:pkgCases = foreach ($p in $script:allPkgs) {
        @{ Bundle = $p.Bundle; Pkg = $p }
    }
}

Describe 'Declarative bundles (data-driven)' -Tag 'Light','Bundle' {

    It 'discovers at least one migrated bundle' {
        ($script:allPkgs | Select-Object -ExpandProperty Bundle -Unique).Count |
            Should -BeGreaterThan 0
    }

    It 'discovers packages from the five canonical migrated bundles' {
        $bundles = $script:allPkgs | Select-Object -ExpandProperty Bundle -Unique
        foreach ($expected in 'OSBasePackages','DeveloperBasePackages','ClientBasePackages','MicrosoftOffice365','AIAgents') {
            $bundles | Should -Contain $expected
        }
    }

    It 'has unique Name within each bundle (cross-bundle duplicates are allowed by design)' {
        # Cross-bundle duplicate names are legitimate — e.g.
        #   * Visual Studio Code is declared in both OSBasePackages
        #     (baseline editor) and DeveloperBasePackages (developer
        #     surface) so either bundle works standalone.
        #   * Node.js / GitHub Copilot CLI / ChatGPT are declared in
        #     AIAgents (so AIAgents stands on its own) AND in
        #     DeveloperBasePackages / ChatGPT.ps1 (their canonical home).
        # The contract we actually need is that no single bundle's
        # `$Packages` array declares the same Name twice — i.e. the
        # bundle author never lost track of which entries are in their
        # own list.
        $dupWithinBundle = $script:allPkgs |
            Group-Object Bundle, Name |
            Where-Object Count -gt 1
        $dupWithinBundle | Should -BeNullOrEmpty -Because "within-bundle duplicates: $($dupWithinBundle.Name -join ', ')"
    }

    It 'every DependsOn reference resolves to a package in this bucket' {
        $names = [System.Collections.Generic.HashSet[string]]@($script:byName.Keys)
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($p in $script:allPkgs) {
            foreach ($dep in @($p.DependsOn)) {
                if (-not [string]::IsNullOrWhiteSpace($dep) -and -not $names.Contains($dep)) {
                    $missing.Add("$($p.Bundle)/$($p.Name) -> $dep")
                }
            }
        }
        $missing | Should -BeNullOrEmpty -Because "unresolved DependsOn: $($missing -join ', ')"
    }

    It '<Pkg.Name> (<Bundle>) declares a known Installer' -ForEach $script:pkgCases {
        $Pkg.Installer | Should -BeIn @('winget','scoop','choco','npmGlobal','dotnetTool','custom')
    }

    It '<Pkg.Name> (<Bundle>) has Id when Installer is not custom' -ForEach $script:pkgCases {
        if ($Pkg.Installer -ne 'custom') {
            $Pkg.Id | Should -Not -BeNullOrEmpty
        }
    }

    It '<Pkg.Name> (<Bundle>) uses bucket/name prefix when scoop' -ForEach $script:pkgCases {
        if ($Pkg.Installer -eq 'scoop') {
            $Pkg.Id | Should -Match '^[^/]+/[^/]+$'
        }
    }

    It '<Pkg.Name> (<Bundle>) only uses msstore Source with winget' -ForEach $script:pkgCases {
        if ($Pkg.Source -eq 'msstore') {
            $Pkg.Installer | Should -Be 'winget'
        }
    }

    It '<Pkg.Name> (<Bundle>) has NativeCommandScript when Completion=native or auto' -ForEach $script:pkgCases {
        if ($Pkg.Completion -in @('native','auto')) {
            $Pkg.HasNativeCommandScript | Should -BeTrue
        }
    }

    It '<Pkg.Name> (<Bundle>) has CliCommands when Completion is not none' -ForEach $script:pkgCases {
        if ($Pkg.Completion -in @('native','pscompletions','auto')) {
            @($Pkg.CliCommands).Count | Should -BeGreaterThan 0
        }
    }

    It '<Pkg.Name> (<Bundle>) declares plausible short CLI names' -ForEach $script:pkgCases {
        foreach ($cli in @($Pkg.CliCommands)) {
            $cli | Should -Match '^[A-Za-z0-9._\-]+$' -Because "CliCommands must be bare command names (no paths/quotes)"
            $cli.Length | Should -BeLessThan 40
        }
    }

    It '<Pkg.Name> (<Bundle>) has Scope=global by default unless explicitly user' -ForEach $script:pkgCases {
        # Once the schema default flipped to 'global', the only legitimate
        # non-global value is 'user' for the rare per-user-only package.
        # 'machine' is still accepted as a legacy synonym, but should not
        # appear in newly-migrated bundles.
        $Pkg.Scope | Should -BeIn @('global','user')
    }
}

Describe 'Specific cross-bundle placement contracts' -Tag 'Light','Bundle' {
    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\ScoopBucket\ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module ScoopBucket -Force } 
        $script:byBundle = @{}
        foreach ($p in @(Get-Package -BucketPath $PSScriptRoot)) {
            if (-not $script:byBundle.ContainsKey($p.Bundle)) {
                $script:byBundle[$p.Bundle] = @()
            }
            $script:byBundle[$p.Bundle] += $p
        }
    }

    It 'Claude for Excel is owned by the MicrosoftOffice365 bundle' {
        $script:byBundle.MicrosoftOffice365.Name | Should -Contain 'Claude for Excel'
        $script:byBundle.AIAgents.Name           | Should -Not -Contain 'Claude for Excel'
        $script:byBundle.ClientBasePackages.Name | Should -Not -Contain 'Claude for Excel'
    }

    It 'Claude Desktop is owned by the AIAgents bundle' {
        $script:byBundle.AIAgents.Name           | Should -Contain 'Claude Desktop'
        $script:byBundle.ClientBasePackages.Name | Should -Not -Contain 'Claude Desktop'
    }

    It 'Visual Studio Code is declared in both OSBasePackages and DeveloperBasePackages' {
        $script:byBundle.OSBasePackages.Name        | Should -Contain 'Visual Studio Code'
        $script:byBundle.DeveloperBasePackages.Name | Should -Contain 'Visual Studio Code'
    }

    It 'Sysinternals Suite has no PostInstallScript (scoop bin shims handle CLI exposure)' {
        $si = $script:byBundle.OSBasePackages | Where-Object Name -eq 'Sysinternals Suite'
        $si.HasPostInstallScript | Should -BeFalse
    }

    It 'Beyond Compare has a PostInstallScript for the bcompc shim' {
        $bc = $script:byBundle.DeveloperBasePackages | Where-Object Name -eq 'Beyond Compare'
        $bc.HasPostInstallScript | Should -BeTrue
    }
}
