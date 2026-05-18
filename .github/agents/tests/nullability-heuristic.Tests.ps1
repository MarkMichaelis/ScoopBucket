#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the nullability heuristic on generated record properties (issue #63).
# Delegates to the zero-dep Node script `nullability.test.js` and asserts exit code 0.

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:TestJs     = Join-Path $script:ScriptsDir 'nullability.test.js'
}

Describe 'nullability heuristic for generated record properties' {
    It 'test file exists at the canonical path' {
        Test-Path -LiteralPath $script:TestJs | Should -BeTrue
    }

    It 'parses without syntax errors' {
        & node --check $script:TestJs 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'all behavioral assertions pass' {
        $out = & node $script:TestJs 2>&1
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            Write-Host ($out -join "`n")
        }
        $exit | Should -Be 0
        ($out -join "`n") | Should -Match 'All nullability tests passed'
    }
}
