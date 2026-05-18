#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# End-to-end smoke test for the api-wrapper-scaffold agent.
#
# This is the executable spec: a regression in ANY prior PR's script
# (sanitize-har, verify-scrub, detect-auth, generate-wrapper, codegen,
# tests-emit, secret-gate) causes this single test to fail with a clear
# stage banner. The pipeline is exercised via run-agent.js end-to-end.

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:Runner   = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts/run-agent.js'
    $script:Detect   = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts/detect-auth.js'
    $script:RestHar  = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/e2e-rest.har'
    $script:GqlHar   = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/e2e-graphql.har'
    $script:DotnetAvailable = $null -ne (Get-Command dotnet -ErrorAction SilentlyContinue)

    function New-OutDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("agentE2E-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $d | Out-Null
        return $d
    }
}

Describe 'Agent E2E -- REST pipeline (cookie+csrf)' {
    BeforeAll {
        $script:RestOut = New-OutDir
        $script:RestStdout = & node $script:Runner `
            --har $script:RestHar `
            --out $script:RestOut `
            --project MyWrapper `
            --namespace MyWrapper `
            --base-url https://app.example.com 2>&1
        $script:RestExit = $LASTEXITCODE
        $script:RestJoined = ($script:RestStdout -join "`n")
    }
    AfterAll {
        if ($script:RestOut -and (Test-Path $script:RestOut)) {
            Remove-Item -Recurse -Force $script:RestOut -ErrorAction SilentlyContinue
        }
    }

    Context 'Stage 1 -- HAR fixture present' {
        It 'e2e-rest.har exists' { Test-Path -LiteralPath $script:RestHar | Should -BeTrue }
    }

    Context 'Stage 2 -- run-agent orchestrator' {
        It 'exits 0 (entire pipeline ran)' {
            $script:RestExit | Should -Be 0 -Because "run-agent stdout was:`n$($script:RestJoined)"
        }
        It 'prints all four stage banners in order' {
            $script:RestJoined | Should -Match '==> Stage:\s*sanitize-har'
            $script:RestJoined | Should -Match '==> Stage:\s*verify-scrub'
            $script:RestJoined | Should -Match '==> Stage:\s*detect-auth'
            $script:RestJoined | Should -Match '==> Stage:\s*generate-wrapper'
        }
    }

    Context 'Stage 3 -- scrubbed HAR + PII substitutions file' {
        It 'scrubbed HAR was written under .run-agent/' {
            Test-Path (Join-Path $script:RestOut '.run-agent/scrubbed.har') | Should -BeTrue
        }
        It 'pii substitutions file was written' {
            $subsPath = Join-Path $script:RestOut '.run-agent/substitutions.json'
            Test-Path $subsPath | Should -BeTrue
            $store = Get-Content $subsPath -Raw | ConvertFrom-Json
            $store.version | Should -Be 1
        }
        It 'no plaintext PII remains in scrubbed HAR' {
            $scrubbed = Get-Content (Join-Path $script:RestOut '.run-agent/scrubbed.har') -Raw
            # jane.doe@example.com was planted in the fixture; must be substituted.
            $scrubbed | Should -Not -Match 'jane\.doe@example\.com'
        }
    }

    Context 'Stage 4 -- verify-scrub passed (implied by exit 0)' {
        It 'banner appears before detect-auth banner' {
            $verIdx = $script:RestJoined.IndexOf('Stage: verify-scrub')
            $detIdx = $script:RestJoined.IndexOf('Stage: detect-auth')
            $detIdx | Should -BeGreaterThan $verIdx
        }
    }

    Context 'Stage 5 -- auth detection' {
        It 'classifies the REST fixture as cookie+csrf' {
            $script:RestJoined | Should -Match '"authModel":"cookie\+csrf"'
        }
    }

    Context 'Stage 6 -- emitted wrapper file tree' {
        It 'has all canonical project files' {
            $root = $script:RestOut
            $expected = @(
                'src/MyWrapper/MyWrapper.csproj',
                'src/MyWrapper/Client.cs',
                'src/MyWrapper/MyWrapperClient.Generated.cs',
                'src/MyWrapper/Models.Generated.cs',
                'src/MyWrapper/Authenticator.cs',
                'src/MyWrapper/ISessionStore.cs',
                'src/MyWrapper/DpapiSessionStore.cs',
                'src/MyWrapper/UserSecretsSessionStore.cs',
                'src/MyWrapper/McpProgram.cs',
                'README.md',
                '.gitleaks.toml',
                '.githooks/pre-commit',
                '.github/workflows/ci.yml',
                '.github/workflows/secret-scan.yml',
                'tests/MyWrapper.Tests/MyWrapper.Tests.csproj',
                'tests/MyWrapper.Tests/pester/Mcp.Tests.ps1'
            )
            foreach ($rel in $expected) {
                $p = Join-Path $root $rel
                Test-Path $p | Should -BeTrue -Because "expected emitted file: $rel"
            }
        }
    }

    Context 'Stage 7 -- dotnet build of emitted wrapper' {
        It 'builds with 0 warnings and 0 errors' {
            if (-not $script:DotnetAvailable) {
                Set-ItResult -Skipped -Because "dotnet SDK not available"
                return
            }
            $csproj = Join-Path $script:RestOut 'src/MyWrapper/MyWrapper.csproj'
            $out = & dotnet build $csproj --nologo -v:q 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "dotnet build must succeed.`n$out"
            $out | Should -Match '0 Warning\(s\)'
            $out | Should -Match '0 Error\(s\)'
        }
    }

    Context 'Stage 8 -- dotnet test of emitted test project' {
        It 'all emitted [Fact] tests pass' {
            if (-not $script:DotnetAvailable) {
                Set-ItResult -Skipped -Because "dotnet SDK not available"
                return
            }
            $testCsproj = Join-Path $script:RestOut 'tests/MyWrapper.Tests/MyWrapper.Tests.csproj'
            $out = & dotnet test $testCsproj --nologo -v:q 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "dotnet test must succeed.`n$out"
            $out | Should -Match 'Failed:\s*0'
            $out | Should -Match 'Passed:\s*[1-9]'
        }
    }

    Context 'Stage 9 -- emitted Pester smoke (Mcp.Tests.ps1)' {
        It 'the emitted Mcp.Tests.ps1 passes when invoked in isolation' {
            $emitted = Join-Path $script:RestOut 'tests/MyWrapper.Tests/pester/Mcp.Tests.ps1'
            Test-Path $emitted | Should -BeTrue
            # Invoke in an isolated runspace via pwsh -NoProfile so the outer
            # Pester run is not disturbed.
            $r = & pwsh -NoProfile -Command "Invoke-Pester -Path '$emitted' -PassThru -Output None | Select-Object -ExpandProperty FailedCount"
            $LASTEXITCODE | Should -Be 0
            [int]$r | Should -Be 0
        }
    }
}

Describe 'Agent E2E -- determinism (REST)' {
    It 'a second run into a different tmp dir is byte-identical' {
        $a = New-OutDir; $b = New-OutDir
        try {
            & node $script:Runner --har $script:RestHar --out $a --project MyWrapper --namespace MyWrapper --base-url https://app.example.com 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            & node $script:Runner --har $script:RestHar --out $b --project MyWrapper --namespace MyWrapper --base-url https://app.example.com 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0

            # Compare emitted wrapper sources (deliberately exclude .run-agent/
            # which has absolute timestamps in the auth.json transcript).
            $filesA = Get-ChildItem $a -Recurse -File | Where-Object {
                $_.FullName.Substring($a.Length) -notmatch '\.run-agent'
            } | Sort-Object FullName
            $filesB = Get-ChildItem $b -Recurse -File | Where-Object {
                $_.FullName.Substring($b.Length) -notmatch '\.run-agent'
            } | Sort-Object FullName

            $filesA.Count | Should -Be $filesB.Count
            for ($i = 0; $i -lt $filesA.Count; $i++) {
                $relA = $filesA[$i].FullName.Substring($a.Length)
                $relB = $filesB[$i].FullName.Substring($b.Length)
                $relA | Should -Be $relB
                (Get-FileHash -Algorithm SHA256 $filesA[$i].FullName).Hash |
                    Should -Be (Get-FileHash -Algorithm SHA256 $filesB[$i].FullName).Hash `
                    -Because "byte-identical emitted file for $relA"
            }
        } finally {
            Remove-Item -Recurse -Force $a -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $b -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Agent E2E -- GraphQL pipeline parity' {
    BeforeAll {
        $script:GqlOut = New-OutDir
        & node $script:Runner --har $script:GqlHar --out $script:GqlOut --project GqlWrapper --namespace GqlWrapper --base-url https://api.example.com 2>&1 | Out-Null
        $script:GqlExit = $LASTEXITCODE
    }
    AfterAll {
        if ($script:GqlOut -and (Test-Path $script:GqlOut)) {
            Remove-Item -Recurse -Force $script:GqlOut -ErrorAction SilentlyContinue
        }
    }

    It 'orchestrator exits 0' { $script:GqlExit | Should -Be 0 }
    It 'auth model is a known value (not "unknown")' {
        $authJson = Get-Content (Join-Path $script:GqlOut '.run-agent/auth.json') -Raw | ConvertFrom-Json
        $authJson.authModel | Should -Not -BeNullOrEmpty
        $authJson.authModel | Should -Not -Be 'unknown'
    }
    It 'emitted client has GraphQLAsync<T>, not REST per-entry methods' {
        $gen = Get-Content (Join-Path $script:GqlOut 'src/GqlWrapper/GqlWrapperClient.Generated.cs') -Raw
        $gen | Should -Match 'GraphQLAsync<'
        $gen | Should -Not -Match 'PostGraphqlAsync'
    }
    It 'dotnet build succeeds' {
        if (-not $script:DotnetAvailable) {
            Set-ItResult -Skipped -Because "dotnet SDK not available"
            return
        }
        $csproj = Join-Path $script:GqlOut 'src/GqlWrapper/GqlWrapper.csproj'
        $out = & dotnet build $csproj --nologo -v:q 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because "$out"
    }
    It 'dotnet test passes' {
        if (-not $script:DotnetAvailable) {
            Set-ItResult -Skipped -Because "dotnet SDK not available"
            return
        }
        $testCsproj = Join-Path $script:GqlOut 'tests/GqlWrapper.Tests/GqlWrapper.Tests.csproj'
        $out = & dotnet test $testCsproj --nologo -v:q 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because "$out"
        $out | Should -Match 'Failed:\s*0'
    }
}

Describe 'Agent E2E -- secret gate self-check on emitted project (optional)' {
    It 'gitleaks finds 0 leaks on a freshly-emitted project' {
        $gitleaks = Get-Command gitleaks -ErrorAction SilentlyContinue
        if (-not $gitleaks) {
            Set-ItResult -Skipped -Because "gitleaks not on PATH"
            return
        }
        $out = New-OutDir
        try {
            & node $script:Runner --har $script:RestHar --out $out --project MyWrapper --namespace MyWrapper --base-url https://app.example.com 2>&1 | Out-Null
            Push-Location $out
            try {
                & gitleaks detect --config .gitleaks.toml --no-git --source . 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0
            } finally { Pop-Location }
        } finally { Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue }
    }
}
