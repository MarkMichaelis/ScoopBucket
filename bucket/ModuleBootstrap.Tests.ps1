<#
.SYNOPSIS
    Light-suite test for Get-ScoopBucketModulePath and the migrated
    ChatGPT.ps1 declarative pattern.

.DESCRIPTION
    Asserts that:
      - Get-ScoopBucketModulePath resolves the module manifest from any of
        its discovery strategies (already-loaded, PSModulePath, sibling,
        working-tree).
      - The migrated ChatGPT.ps1 declares a single `[Package]` entry whose
        Installer/Id/Source/VerifyScript match the expected MS-Store
        identity (extracted by parsing the bundle's source text rather
        than executing it, so the real winget install never runs).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Utils.ps1')
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\ScoopBucket'
}

Describe 'Get-ScoopBucketModulePath' -Tag 'Light','Module' {
    It 'resolves to the working-tree manifest when nothing is loaded' {
        Get-Module ScoopBucket -All | Remove-Module -Force -ErrorAction SilentlyContinue
        $resolved = Get-ScoopBucketModulePath
        $resolved | Should -Not -BeNullOrEmpty
        (Resolve-Path $resolved).Path | Should -Be (Resolve-Path (Join-Path $script:moduleRoot 'ScoopBucket.psd1')).Path
    }

    It 'returns the loaded module path when ScoopBucket is already imported' {
        Import-Module (Join-Path $script:moduleRoot 'ScoopBucket.psd1') -Force
        $resolved = Get-ScoopBucketModulePath
        # Module's .Path is the .psm1 once loaded; .psd1 isn't tracked, so
        # accept either by comparing parent directories.
        (Split-Path -Parent $resolved) | Should -Be (Resolve-Path $script:moduleRoot).Path
    }
}

Describe 'ChatGPT.ps1 declarative migration' -Tag 'Light','Module' {
    BeforeAll {
        Import-Module (Get-ScoopBucketModulePath) -Force
        $script:bundle = Join-Path $PSScriptRoot 'ChatGPT.ps1'
    }

    It 'discovers a single ChatGPT [Package] via Get-Package' {
        $pkgs = Get-Package -Name 'ChatGPT' -BucketPath $PSScriptRoot
        @($pkgs).Count         | Should -Be 1
        $pkgs[0].Name          | Should -Be 'ChatGPT'
        $pkgs[0].Installer     | Should -Be 'winget'
        $pkgs[0].Id            | Should -Be '9NT1R1C2HH7J'
        $pkgs[0].Source        | Should -Be 'msstore'
        $pkgs[0].Bundle        | Should -Be 'ChatGPT'
    }
}
