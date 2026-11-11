#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    A bundle script may only call the module's EXPORTED functions (#524).

.DESCRIPTION
    Scoop runs a bundle .ps1 as a plain script after `Import-Module`, so every
    scriptblock literal in it -- ConfigScript, CustomInstallScript, VerifyScript
    and the rest -- is bound to the bundle's own scope. Only exported module
    functions resolve there. A private helper is invisible and the call throws
    "The term '...' is not recognized" at install time.

    The bug hides from tests that harvest packages through
    Get-BundlePackageObjects: that evaluates the $Packages array INSIDE the
    module, where private functions do resolve. So this check is static: it
    walks every bundle's AST and fails on any command naming a function the
    module defines but does not export.
#>

BeforeDiscovery {
    $script:bundleFiles = Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' -and $_.Name -notmatch '^Invoke-Tests\.ps1$' } |
        ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } }
}

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket'
    Import-Module (Join-Path $moduleRoot 'MarkMichaelis.ScoopBucket.psd1') -Force

    $exported = (Get-Module MarkMichaelis.ScoopBucket).ExportedCommands.Keys

    function Get-DefinedFunctionName([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
    }

    $moduleFunctions = Get-ChildItem -Path $moduleRoot -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
        ForEach-Object { Get-DefinedFunctionName $_.FullName }
    $script:privateFunctions = @($moduleFunctions | Where-Object { $_ -notin $exported } | Sort-Object -Unique)

    # A bundle may define (or dot-source) its own helper of the same name.
    $script:bundleFunctions = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
        ForEach-Object { Get-DefinedFunctionName $_.FullName } | Sort-Object -Unique)
}

Describe 'Bundle scripts call only exported module functions (#524)' -Tag 'Light','Bundle' {

    It 'finds the module''s private functions (guards the check itself)' {
        $script:privateFunctions | Should -Contain 'Get-CommandSourcePath'
    }

    It '<Name> calls no private module function' -ForEach $script:bundleFiles {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $offenders = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object {
                $cmd = $_.GetCommandName()
                if ($cmd -and $cmd -in $script:privateFunctions -and $cmd -notin $script:bundleFunctions) {
                    "${cmd} (line $($_.Extent.StartLineNumber))"
                }
            }
        $offenders | Should -BeNullOrEmpty -Because 'scoop runs bundles outside the module, where private functions do not resolve'
    }
}
