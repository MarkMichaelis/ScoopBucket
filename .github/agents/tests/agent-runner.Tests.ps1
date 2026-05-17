#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for templates/api-wrapper-scaffold/scripts/run-agent.js
# -- the thin orchestrator that chains sanitize -> verify -> detect -> generate.

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:Runner   = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts/run-agent.js'
    $script:RestHar  = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/e2e-rest.har'

    function New-TmpDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("runagent-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $d | Out-Null
        return $d
    }
}

Describe 'run-agent.js exists' {
    It 'lives at the canonical path' {
        Test-Path -LiteralPath $script:Runner | Should -BeTrue
    }
    It 'parses without syntax errors' {
        & node --check $script:Runner 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'run-agent.js CLI surface' {
    It 'exits non-zero with a usage message when required flags are missing' {
        $stderr = & node $script:Runner 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($stderr -join "`n") | Should -Match 'usage:.*run-agent\.js'
    }
    It 'exits non-zero when --har points to a missing file' {
        $missing = Join-Path ([IO.Path]::GetTempPath()) ("nope-" + [guid]::NewGuid() + ".har")
        $out = New-TmpDir
        try {
            & node $script:Runner --har $missing --out $out --project P --namespace P 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'run-agent.js stage banners (happy path)' {
    BeforeAll {
        $script:Out = New-TmpDir
        $script:Stdout = & node $script:Runner --har $script:RestHar --out $script:Out --project MyWrapper --namespace MyWrapper --base-url https://app.example.com 2>&1
        $script:Joined = ($script:Stdout -join "`n")
    }
    AfterAll {
        if ($script:Out -and (Test-Path $script:Out)) {
            Remove-Item -Recurse -Force $script:Out -ErrorAction SilentlyContinue
        }
    }
    It 'exits 0' { $LASTEXITCODE | Should -Be 0 }
    It 'prints the sanitize-har stage banner' { $script:Joined | Should -Match '==> Stage:\s*sanitize-har' }
    It 'prints the verify-scrub stage banner' { $script:Joined | Should -Match '==> Stage:\s*verify-scrub' }
    It 'prints the detect-auth stage banner'  { $script:Joined | Should -Match '==> Stage:\s*detect-auth' }
    It 'prints the generate-wrapper stage banner' { $script:Joined | Should -Match '==> Stage:\s*generate-wrapper' }
    It 'prints stages in the canonical order (sanitize -> verify -> detect -> generate)' {
        $sanIdx = $script:Joined.IndexOf('Stage: sanitize-har')
        $verIdx = $script:Joined.IndexOf('Stage: verify-scrub')
        $detIdx = $script:Joined.IndexOf('Stage: detect-auth')
        $genIdx = $script:Joined.IndexOf('Stage: generate-wrapper')
        $sanIdx | Should -BeGreaterThan -1
        $verIdx | Should -BeGreaterThan $sanIdx
        $detIdx | Should -BeGreaterThan $verIdx
        $genIdx | Should -BeGreaterThan $detIdx
    }
}

Describe 'run-agent.js fails fast on a corrupt HAR' {
    It 'sanitize-har stage fails; later stages do not run' {
        $bad = Join-Path ([IO.Path]::GetTempPath()) ("bad-" + [guid]::NewGuid() + ".har")
        Set-Content -LiteralPath $bad -Value 'not valid json at all {{{' -Encoding utf8
        $out = New-TmpDir
        try {
            $stdall = & node $script:Runner --har $bad --out $out --project P --namespace P 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            $joined = ($stdall -join "`n")
            $joined | Should -Match '==> Stage:\s*sanitize-har'
            # Later stages must not have run:
            $joined | Should -Not -Match '==> Stage:\s*verify-scrub'
            $joined | Should -Not -Match '==> Stage:\s*detect-auth'
            $joined | Should -Not -Match '==> Stage:\s*generate-wrapper'
        } finally {
            Remove-Item -LiteralPath $bad -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
        }
    }
}
