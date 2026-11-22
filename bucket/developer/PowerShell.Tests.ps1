#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# PowerShell Gallery modules installed by PowerShell.ps1 (#541).
#
# PowerShell.ps1 is shipped by PowerShellCore.json and PowerShellWindows.json
# and is the bucket's one place that installs PSGallery modules: one
# `Install-Module` line per module. Each line is bound with PowerShell's own
# StaticParameterBinder, so a positional module name resolves to -Name exactly
# as it would at run time, without installing anything.
#
# Tagged 'Light' -- parses the script only; no install side effects.
# ----------------------------------------------------------------------------

Describe 'PowerShell.ps1 PowerShell Gallery modules' -Tag 'Light' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot 'PowerShell.ps1'
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
        $script:ParseErrors = $parseErrors

        $commands = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Install-Module'
        }, $true)

        $script:ModuleInstalls = @(foreach ($command in $commands) {
            $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($command, $true).BoundParameters
            [pscustomobject]@{
                Name       = if ($bound.ContainsKey('Name'))       { $bound['Name'].ConstantValue }
                Repository = if ($bound.ContainsKey('Repository')) { $bound['Repository'].ConstantValue }
                Scope      = if ($bound.ContainsKey('Scope'))      { $bound['Scope'].ConstantValue }
                Force      = $bound.ContainsKey('Force')
            }
        })
    }

    It 'parses without errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'installs the Az rollup module from the PowerShell Gallery for all users' {
        # Az.Accounts, Az.Compute, Az.Resources and Az.Security all come from
        # the rollup, at matching versions.
        $az = @($script:ModuleInstalls | Where-Object Name -eq 'Az')
        $az | Should -HaveCount 1 -Because 'PowerShell.ps1 must install the Az rollup module exactly once'
        $az[0].Repository | Should -Be 'PSGallery'
        $az[0].Scope | Should -Be 'AllUsers' -Because 'every other module in PowerShell.ps1 installs for all users'
    }

    It 'does not force-reinstall Az on every run' {
        # README idempotency contract: no unconditional `Install-Module -Force`.
        # Az is about 80 sub-modules; -Force would re-download all of them on
        # every PowerShellCore / PowerShellWindows install or update.
        $az = @($script:ModuleInstalls | Where-Object Name -eq 'Az')
        $az | Should -HaveCount 1
        $az[0].Force | Should -BeFalse
    }
}
