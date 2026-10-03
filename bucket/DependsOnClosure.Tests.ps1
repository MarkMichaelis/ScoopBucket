#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first regression tests for the DependsOn transitive closure
    (issue #450).

.DESCRIPTION
    `DependsOn` is NOT an ordering hint. `Resolve-PackageOrder` BFS-expands
    it transitively whenever `-Name` is passed, and `Install-Package` always
    passes `-Name`. So every `DependsOn` entry is an install-set member, not
    merely a "schedule this first" nudge.

    Aspire declared `DependsOn = @('dotnet','Visual Studio')`, which meant
    `Install-Package -Name Aspire` resolved
    `MarkMichaelis/VisualStudio2026Enterprise` -- a multi-GB IDE -- into the
    install set in order to obtain a small CLI tool. Aspire needs the .NET
    SDK, not the IDE.

    These tests assert against the resolver's ACTUAL output for the real
    bundle declarations rather than grepping the declaration, so they also
    fail if the closure semantics themselves change.

    Tagged 'Light' -- harvests declarative [Package] entries and runs the
    pure resolver; no install side effects.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket')
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $script:psd1) { Import-Module $script:psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    # Resolve-PackageOrder is private; dot-source it directly (same approach
    # as PackageOrder.Tests.ps1). The class must be loaded first.
    . (Join-Path $script:moduleRoot 'Classes\Package.ps1')
    . (Join-Path $script:moduleRoot 'Private\Resolve-PackageOrder.ps1')

    # Real declarations, harvested from the bundle on disk.
    $script:devPkgs = @(Get-Package -BucketPath $PSScriptRoot -Bundle 'DeveloperBasePackages')

    # Resolve each CLI-bearing package on its own, exactly as
    # `Install-Package -Name <pkg>` would. Keyed by package name.
    # Resolve-PackageOrder returns `,$array` to preserve array-ness, so the
    # result must be assigned before it is enumerated.
    $script:resolved = @{}
    foreach ($p in $script:devPkgs) {
        $ordered = Resolve-PackageOrder -Packages $script:devPkgs -Name $p.Name
        $script:resolved[$p.Name] = @($ordered | ForEach-Object Name)
    }
}

Describe 'DependsOn closure — a small tool must not drag in an IDE' -Tag 'Light', 'Bundle' {

    It 'has the fixture packages this test reasons about' {
        @($script:devPkgs | Where-Object Name -EQ 'Aspire').Count | Should -Be 1
        @($script:devPkgs | Where-Object Name -EQ 'dotnet').Count | Should -Be 1
        @($script:devPkgs | Where-Object Name -EQ 'Visual Studio').Count | Should -Be 1
        # Guard against a vacuous pass: every package must have resolved to
        # a non-empty set containing at least itself.
        foreach ($p in $script:devPkgs) {
            $script:resolved[$p.Name] | Should -Contain $p.Name
        }
    }

    It 'resolves Aspire without pulling Visual Studio into the install set' {
        # The regression: Visual Studio resolves to
        # MarkMichaelis/VisualStudio2026Enterprise (multi-GB IDE). Asking for
        # a small CLI tool must never schedule it.
        $script:resolved['Aspire'] | Should -Not -Contain 'Visual Studio'
    }

    It 'still resolves the .NET SDK before Aspire' {
        # Aspire IS a dotnet global tool, so dotnet is a genuine dependency
        # and must still be scheduled first.
        $script:resolved['Aspire'] -join ',' | Should -Be 'dotnet,Aspire'
    }

    It 'never schedules a multi-GB IDE for any CLI-only developer tool' {
        # Generalized guard so the next author cannot reintroduce the same
        # shape on a sibling package. 'Visual Studio' may only appear in a
        # resolved set when it was asked for by name.
        $cliOnly = @(
            $script:devPkgs |
                Where-Object { $_.Name -ne 'Visual Studio' -and @($_.CliCommands).Count -gt 0 } |
                ForEach-Object Name
        )
        $cliOnly.Count | Should -BeGreaterThan 0

        $offenders = @(foreach ($n in $cliOnly) {
            if ($script:resolved[$n] -contains 'Visual Studio') { $n }
        })
        $offenders | Should -BeNullOrEmpty -Because "these CLI packages drag the IDE in via DependsOn: $($offenders -join ', ')"
    }
}
