#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for issue #90.a: generated README must include a
# mobile-app coverage section. Delegates to the zero-dep Node script.

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:TestJs     = Join-Path $script:ScriptsDir 'readme-mobile-import-section.test.js'
}

Describe 'generate-wrapper README mobile-app coverage section (issue #90.a)' {
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
        ($out -join "`n") | Should -Match 'All readme-mobile-import-section tests passed'
    }
}
