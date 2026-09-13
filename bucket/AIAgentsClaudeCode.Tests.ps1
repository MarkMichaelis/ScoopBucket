#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pins the AIAgents Claude Code CLI entry's configuration phase (#412).

.DESCRIPTION
    The MarkMichaelis Claude Code setup (the tab-session hook that lets restored
    Windows Terminal tabs resume their session, the Prompt Spotlight theme, and the
    "Outcomes, not code" output style) is applied by the package's ConfigScript on
    every install and update. This fails with a named diagnostic if that hook or the
    committed files it applies go missing. Import-ClaudeCodeSettings itself is
    covered by module/.../Public/ToolSettingsImport.Tests.ps1.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:claudeCode = Get-Package -BucketPath $PSScriptRoot -Name 'Claude Code CLI'
}

Describe 'AIAgents: Claude Code CLI configuration' -Tag 'Light', 'Bundle' {

    It 'declares the Claude Code CLI package exactly once' {
        @($script:claudeCode).Count | Should -Be 1
    }

    It 'applies the MarkMichaelis Claude Code configuration during the configuration phase (ConfigScript)' {
        # Get-Package strips scriptblocks, exposing only the HasConfigScript projection.
        $script:claudeCode.HasConfigScript | Should -BeTrue
    }

    It 'runs its ConfigScript from the Update-Package/Install-Package harvest, where $PSScriptRoot is empty' {
        Mock Import-ClaudeCodeSettings -ModuleName MarkMichaelis.ScoopBucket { }
        $package = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($bundle) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq 'Claude Code CLI'
        } (Join-Path $PSScriptRoot 'AIAgents.ps1')

        { & $package.ConfigScript $package } | Should -Not -Throw
        Should -Invoke Import-ClaudeCodeSettings -ModuleName MarkMichaelis.ScoopBucket -Times 1 -Exactly
    }

    It 'ships the committed configuration with the hook, theme, and output style it installs' {
        $config = Join-Path $PSScriptRoot 'ai\MarkMichaelisClaudeCodeSettings.jsonc'
        $config | Should -Exist
        (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).settings.theme | Should -Be 'custom:prompt-spotlight'
        foreach ($name in 'MarkMichaelisClaudeTabSessionHook.js', 'MarkMichaelisClaudePromptSpotlightTheme.jsonc', 'MarkMichaelisClaudeOutcomesNotCode.md') {
            Join-Path $PSScriptRoot "ai\$name" | Should -Exist
        }
    }
}
