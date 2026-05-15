#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for the internal Resolve-PackageOrder helper in the
# MarkMichaelis.ScoopBucket module: validation of DependsOn references,
# transitive closure when filtering by -Name, -Skip handling, topological
# sort, cycle detection.

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket')
    $script:classPath  = Join-Path $script:moduleRoot 'Classes\Package.ps1'
    $script:resolvePath = Join-Path $script:moduleRoot 'Private\Resolve-PackageOrder.ps1'

    # Resolve-PackageOrder is private, so we dot-source it directly rather
    # than going through Import-Module. The class must be loaded first.
    . $script:classPath
    . $script:resolvePath

    function New-Pkg {
        param([string]$Name, [string[]]$DependsOn = @())
        [Package]@{
            Name = $Name
            Installer = 'scoop'
            Id = "main/$Name"
            DependsOn = $DependsOn
        }
    }
}

Describe 'Resolve-PackageOrder — happy paths' -Tag 'Light', 'Module' {
    It 'returns packages in declaration order when there are no deps' {
        $pkgs = @(
            (New-Pkg 'a'),
            (New-Pkg 'b'),
            (New-Pkg 'c')
        )
        $result = Resolve-PackageOrder -Packages $pkgs
        ($result | ForEach-Object Name) -join ',' | Should -Be 'a,b,c'
    }

    It 'orders dependencies before dependents' {
        $pkgs = @(
            (New-Pkg 'cli' -DependsOn 'core'),
            (New-Pkg 'core')
        )
        $result = Resolve-PackageOrder -Packages $pkgs
        ($result | ForEach-Object Name) -join ',' | Should -Be 'core,cli'
    }

    It 'handles deep dependency chains' {
        $pkgs = @(
            (New-Pkg 'd' -DependsOn 'c'),
            (New-Pkg 'a'),
            (New-Pkg 'c' -DependsOn 'b'),
            (New-Pkg 'b' -DependsOn 'a')
        )
        $result = Resolve-PackageOrder -Packages $pkgs
        ($result | ForEach-Object Name) -join ',' | Should -Be 'a,b,c,d'
    }
}

Describe 'Resolve-PackageOrder — -Name filter' -Tag 'Light', 'Module' {
    It 'includes only the requested package and its transitive deps' {
        $pkgs = @(
            (New-Pkg 'bitwarden'),
            (New-Pkg 'bitwardencli' -DependsOn 'bitwarden'),
            (New-Pkg 'unrelated')
        )
        $result = Resolve-PackageOrder -Packages $pkgs -Name 'bitwardencli'
        ($result | ForEach-Object Name) -join ',' | Should -Be 'bitwarden,bitwardencli'
    }

    It 'supports multiple -Name values' {
        $pkgs = @(
            (New-Pkg 'a'),
            (New-Pkg 'b'),
            (New-Pkg 'c')
        )
        $result = Resolve-PackageOrder -Packages $pkgs -Name @('a', 'c')
        ($result | ForEach-Object Name) -join ',' | Should -Be 'a,c'
    }

    It 'throws when -Name does not match' {
        $pkgs = @((New-Pkg 'a'))
        { Resolve-PackageOrder -Packages $pkgs -Name 'missing' } |
            Should -Throw -ExpectedMessage "*does not match any Package*"
    }
}

Describe 'Resolve-PackageOrder — -Skip filter' -Tag 'Light', 'Module' {
    It 'removes the named packages' {
        $pkgs = @(
            (New-Pkg 'a'),
            (New-Pkg 'b'),
            (New-Pkg 'c')
        )
        $result = Resolve-PackageOrder -Packages $pkgs -Skip 'b'
        ($result | ForEach-Object Name) -join ',' | Should -Be 'a,c'
    }
}

Describe 'Resolve-PackageOrder — error cases' -Tag 'Light', 'Module' {
    It 'rejects duplicate Names' {
        $pkgs = @(
            (New-Pkg 'a'),
            (New-Pkg 'a')
        )
        { Resolve-PackageOrder -Packages $pkgs } |
            Should -Throw -ExpectedMessage "*duplicate Package Name*"
    }

    It 'rejects DependsOn references to undefined packages' {
        $pkgs = @(
            (New-Pkg 'a' -DependsOn 'ghost')
        )
        { Resolve-PackageOrder -Packages $pkgs } |
            Should -Throw -ExpectedMessage "*DependsOn 'ghost'*not defined*"
    }

    It 'detects dependency cycles' {
        $pkgs = @(
            (New-Pkg 'a' -DependsOn 'b'),
            (New-Pkg 'b' -DependsOn 'a')
        )
        { Resolve-PackageOrder -Packages $pkgs } |
            Should -Throw -ExpectedMessage "*cycle or unresolved*"
    }
}
