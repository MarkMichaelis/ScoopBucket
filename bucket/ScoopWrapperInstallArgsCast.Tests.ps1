<#
.SYNOPSIS
    Regression test for issue #255 -- the `scoop` wrapper must not declare
    `[InstallArgs]` on its locally-scoped $scoopArgs variable.

.DESCRIPTION
    `InstallArgs` is defined in a dot-sourced Private file rather than via
    the manifest's ScriptsToProcess. Any second load of the module (or a
    second runtime copy of the dot-sourced class in the same session)
    creates a new `[InstallArgs]` type identity. The cast on
    `Private/Legacy.ps1:207` then fails with the confusing:

        Cannot convert the "InstallArgs" value of type "InstallArgs" to
        type "InstallArgs".

    `Get-InstallArgs` already returns the correct shape, so the type
    constraint adds no value and must stay removed.

    This is an AST-level pin -- it fails for a behavioral reason
    (assertion failure naming the offending line) when the constraint is
    re-introduced.
#>

BeforeAll {
    $script:legacyPath = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\Private\Legacy.ps1')
}

Describe 'scoop wrapper -- InstallArgs cast (issue #255)' -Tag 'Light','Module' {

    It 'does not constrain $scoopArgs to [InstallArgs] inside function scoop' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:legacyPath, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty

        $scoopFn = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'scoop'
        }, $true) | Select-Object -First 1
        $scoopFn | Should -Not -BeNullOrEmpty -Because 'function scoop must exist in Legacy.ps1'

        $offending = $scoopFn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and
            $n.Type.TypeName.Name -eq 'InstallArgs'
        }, $true)

        $offending | Should -BeNullOrEmpty -Because @"
The [InstallArgs] cast inside `function scoop` triggers a type-identity
collision after the module is reloaded (issue #255). Get-InstallArgs
already returns an InstallArgs instance -- leave $scoopArgs untyped, the
same way the sibling `choco` wrapper does.
"@
    }
}
