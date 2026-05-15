<#
.SYNOPSIS
    Light-suite test for MarkMichaelis.ScoopBucket module bootstrap.

.DESCRIPTION
    Asserts that:
      - The MarkMichaelis.ScoopBucket module loads from its working-tree manifest.
      - The migrated [Package] surface (class, Install-Package, Get-Package,
        Invoke-PackageInstall) is importable in the caller's scope after a
        plain `Import-Module MarkMichaelis.ScoopBucket`.
      - ChatGPT.ps1 contributes its canonical declarative entry to
        Get-Package output.
#>

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'
}

Describe 'MarkMichaelis.ScoopBucket module bootstrap' -Tag 'Light', 'Module' {
    It 'imports cleanly from the working-tree manifest' {
        { Import-Module $script:psd1 -Force -ErrorAction Stop } | Should -Not -Throw
        Get-Module MarkMichaelis.ScoopBucket | Should -Not -BeNullOrEmpty
    }

    It 'exports the declarative public surface' {
        Import-Module $script:psd1 -Force
        $exports = (Get-Module MarkMichaelis.ScoopBucket).ExportedFunctions.Keys
        foreach ($fn in @('Install-Package', 'Get-Package', 'Invoke-PackageInstall',
                          'Register-CliCompletion', 'Test-ScoopPackageInstalled')) {
            $exports | Should -Contain $fn
        }
    }

    It 'makes the [Package] class available to the caller scope' {
        Import-Module $script:psd1 -Force
        $p = [Package]@{ Name = 'x'; Installer = 'scoop'; Id = 'main/x' }
        $p.Name | Should -Be 'x'
    }
}

Describe 'ChatGPT.ps1 declarative migration' -Tag 'Light', 'Module' {
    BeforeAll {
        Import-Module $script:psd1 -Force
    }

    It 'discovers the canonical ChatGPT [Package] via Get-Package' {
        $pkgs = Get-Package -Name 'ChatGPT' -BucketPath $PSScriptRoot |
            Where-Object Bundle -eq 'ChatGPT'
        @($pkgs).Count     | Should -Be 1
        $pkgs[0].Name      | Should -Be 'ChatGPT'
        $pkgs[0].Installer | Should -Be 'winget'
        $pkgs[0].Id        | Should -Be '9NT1R1C2HH7J'
        $pkgs[0].Source    | Should -Be 'msstore'
        $pkgs[0].Bundle    | Should -Be 'ChatGPT'
    }
}
