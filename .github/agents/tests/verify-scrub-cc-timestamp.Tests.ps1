#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for issue #87: verify-scrub no longer flags Luhn-valid
# 13-digit Unix-millisecond timestamps as credit-card leaks.
# Delegates to the zero-dep Node script `verify-scrub-cc-timestamp.test.js`.

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:TestJs     = Join-Path $script:ScriptsDir 'verify-scrub-cc-timestamp.test.js'
}

Describe 'verify-scrub credit-card vs Unix-ms timestamp (issue #87)' {
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
        ($out -join "`n") | Should -Match 'All verify-scrub-cc-timestamp tests passed'
    }
}
