#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for AIAgents bundle entries that need
    bundle-specific winget invocation tweaks.

.DESCRIPTION
    Warp ships a Squirrel-based installer whose progress UI pops a
    window during winget install. That is bad UX for interactive
    Install-Package calls and outright broken for headless CI. The
    bucket suppresses it by passing both --silent (installer UI off)
    and --disable-interactivity (winget itself stays non-interactive)
    via the Package.WingetExtraArgs surface.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:warpPkg = Get-Package -BucketPath $PSScriptRoot -Name 'Warp'
}

Describe 'AIAgents bundle: Warp winget invocation' -Tag 'Light','Bundle' {

    It 'declares the Warp package exactly once' {
        @($script:warpPkg).Count | Should -Be 1
    }

    It 'passes --silent to suppress the Squirrel installer progress UI' {
        $script:warpPkg.WingetExtraArgs | Should -Contain '--silent'
    }

    It 'passes --disable-interactivity to keep winget itself non-interactive' {
        $script:warpPkg.WingetExtraArgs | Should -Contain '--disable-interactivity'
    }
}

Describe 'AIAgents bundle: MCP configuration is declarative' -Tag 'Light','Bundle' {
    BeforeAll {
        $bundlePath = Join-Path $PSScriptRoot 'AIAgents.ps1'
        $script:mcpCfgPkg = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($p) Get-BundlePackageObjects -BundlePath $p
        } $bundlePath | Where-Object { $_.Name -eq 'MCP Server Configuration' }
    }

    It 'declares an MCP Server Configuration package exactly once' {
        @($script:mcpCfgPkg).Count | Should -Be 1
    }

    It 'wires the MCP servers through a declarative ConfigScript (not imperative tail code)' {
        $script:mcpCfgPkg.ConfigScript | Should -Not -BeNullOrEmpty
        $script:mcpCfgPkg.ConfigScript.GetType().Name | Should -Be 'ScriptBlock'
        # The script delegates to the self-contained apply function so the
        # framework re-applies the config on every install and every update.
        "$($script:mcpCfgPkg.ConfigScript)" | Should -Match 'Install-AIAgentsMcpConfiguration'
    }

    It 'depends on Node.js so npx-based MCP servers resolve at agent start-up' {
        $script:mcpCfgPkg.DependsOn | Should -Contain 'Node.js'
    }

    It 'resolves the helper dot-source under harvest with an empty $PSScriptRoot (#341)' {
        # Regression: a deferred `{ . (Join-Path $PSScriptRoot ...) }` body sees an
        # EMPTY automatic $PSScriptRoot when Update-Package invokes the harvested
        # scriptblock (a [scriptblock]::Create has no source file), so Join-Path
        # throws "Cannot bind argument to parameter 'Path' because it is an empty
        # string". The fix bakes the resolved helper path in eagerly at harvest
        # time. Isolate the dot-source (AIAgents.Mcp.ps1 is side-effect free on
        # dot-source) by dropping the Install call; the rebuilt probe is itself a
        # ::Create scriptblock, so its $PSScriptRoot is empty -- faithfully
        # reproducing the harvested run-time scope.
        $dotSourceOnly = ($script:mcpCfgPkg.ConfigScript.ToString() -split "`r?`n" |
                Where-Object { $_ -notmatch 'Install-AIAgentsMcpConfiguration' }) -join "`n"
        $probe = [scriptblock]::Create($dotSourceOnly)

        { & $probe } | Should -Not -Throw
        # Observable proof the helper actually loaded: dot-source the probe into
        # this scope and confirm a function defined only in AIAgents.Mcp.ps1 is
        # now available.
        . $probe
        Get-Command Get-PoshMcpServerEntry -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'AIAgents bundle: Gemini desktop -> Gemini CLI Companions' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:aiPkgs = @(Get-Package -BucketPath $PSScriptRoot -Bundle 'AIAgents')
    }

    It 'Gemini desktop declares Companions=@(Gemini CLI)' {
        $desktop = @($script:aiPkgs | Where-Object Name -EQ 'Gemini')[0]
        $desktop                       | Should -Not -BeNullOrEmpty
        @($desktop.Companions)         | Should -Contain 'Gemini CLI'
    }
}
