#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    AIAgents' tail work runs even when a package fails (#522).

.DESCRIPTION
    Invoke-PackageInstall now finishes every package and then throws one
    summary error when any failed. AIAgents is the one bundle with work after
    that call (the -Reset prune and the completion sweep), so the call must sit
    in a try whose finally carries the tail -- otherwise one failed package
    skips the tail for every package that did install. Checked structurally:
    running the real tail needs MCP files and a profile-writing sweep.
#>

BeforeAll {
    $path = Join-Path $PSScriptRoot 'AIAgents.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $script:installCall = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-PackageInstall'
        }, $true) | Select-Object -First 1
    $script:enclosingTry = $script:installCall.Parent
    while ($script:enclosingTry -and $script:enclosingTry -isnot [System.Management.Automation.Language.TryStatementAst]) {
        $script:enclosingTry = $script:enclosingTry.Parent
    }
}

Describe 'AIAgents: tail work survives a failed package (#522)' -Tag 'Light', 'Bundle' {

    It 'calls Invoke-PackageInstall inside a try statement' {
        $script:enclosingTry | Should -Not -BeNullOrEmpty
        $script:enclosingTry.Body.Extent.Text | Should -Match 'Invoke-PackageInstall'
    }

    It 'runs the -Reset prune and the completion sweep from its finally block' {
        $finally = $script:enclosingTry.Finally.Extent.Text
        $finally | Should -Match 'Reset-AIAgentsMcpConfiguration'
        $finally | Should -Match 'Invoke-CliCompletionsSweep'
    }

    It 'still skips the tail in probe mode' {
        $script:enclosingTry.Finally.Extent.Text | Should -Match '__SBPKG_IS_PROBE'
    }
}
