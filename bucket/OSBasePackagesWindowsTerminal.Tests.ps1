#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pins the OSBasePackages Windows Terminal entry's configuration phase (#412).

.DESCRIPTION
    The MarkMichaelis Windows Terminal setup (restore windows and tabs after a
    reboot, the Claude Tabs theme, a Git Bash profile, and per-repository tab
    colors with Claude session resume) is applied by the package's ConfigScript on
    every install and update. This fails with a named diagnostic if that hook or the
    committed files it applies go missing. Import-WindowsTerminalSettings itself is
    covered by module/.../Public/ToolSettingsImport.Tests.ps1.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:terminal = Get-Package -BucketPath $PSScriptRoot -Name 'Windows Terminal'
}

Describe 'OSBasePackages: Windows Terminal configuration' -Tag 'Light', 'Bundle' {

    It 'declares the Windows Terminal package exactly once' {
        @($script:terminal).Count | Should -Be 1
    }

    It 'applies the MarkMichaelis Windows Terminal configuration during the configuration phase (ConfigScript)' {
        # Get-Package strips scriptblocks, exposing only the HasConfigScript projection.
        $script:terminal.HasConfigScript | Should -BeTrue
    }

    It 'runs its ConfigScript from the Update-Package/Install-Package harvest, where $PSScriptRoot is empty' {
        Mock Import-WindowsTerminalSettings -ModuleName MarkMichaelis.ScoopBucket { }
        $package = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($bundle) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq 'Windows Terminal'
        } (Join-Path $PSScriptRoot 'OSBasePackages.ps1')

        { & $package.ConfigScript $package } | Should -Not -Throw
        Should -Invoke Import-WindowsTerminalSettings -ModuleName MarkMichaelis.ScoopBucket -Times 1 -Exactly
    }

    It 'ships the committed configuration next to the shell integration it installs' {
        $config = Join-Path $PSScriptRoot 'os\MarkMichaelisWindowsTerminalSettings.jsonc'
        $config | Should -Exist
        (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).settings.firstWindowPreference | Should -Be 'persistedWindowLayout'
        foreach ($extension in 'psm1', 'js', 'bash') {
            Join-Path $PSScriptRoot "os\MarkMichaelisClaudeTabs.$extension" | Should -Exist
        }
    }
}
