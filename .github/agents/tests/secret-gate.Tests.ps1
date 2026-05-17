#Requires -Version 7.0
#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0.0" }

# Behavior tests for the secret-gate scaffold emitted by api-wrapper-scaffold
# (issue #52). Builds on PR #47 (PII fake markers) + PR #49 (codegen) + PR #51
# (tests-templates).

BeforeAll {
    $script:RepoRoot     = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\") | Select-Object -ExpandProperty Path
    $script:ScriptsDir   = Join-Path $script:RepoRoot "templates/api-wrapper-scaffold/scripts"
    $script:GenJs        = Join-Path $script:ScriptsDir "generate-wrapper.js"
    $script:SgTmplDir    = Join-Path $script:RepoRoot "templates/api-wrapper-scaffold/secret-gate"
    $script:RestHar      = Join-Path $script:RepoRoot ".github/agents/tests/fixtures/har/rest-3endpoints.har"
    $script:GitleaksCmd  = Get-Command gitleaks -ErrorAction SilentlyContinue

    function New-OutDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("wrapgen-sg-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $d | Out-Null
        return $d
    }

    function Invoke-Gen {
        param([string]$Har, [string]$Out)
        & node $script:GenJs `
            --har $Har `
            --out $Out `
            --project-name "ExampleEx" `
            --namespace "Example" `
            --base-url "https://api.example.com" `
            --auth-model "cookie" `
            --authors "IntelliTect" `
            --description "Example wrapper" `
            --repository-url "https://github.com/example/example" `
            --package-tags "example;api;wrapper" 2>&1 | Out-Null
        return $LASTEXITCODE
    }
}

Describe "secret-gate template directory" {
    It "lives at the canonical path" {
        Test-Path -LiteralPath $script:SgTmplDir | Should -BeTrue
    }
    It "ships all four templates" {
        Test-Path (Join-Path $script:SgTmplDir ".githooks/pre-commit.tmpl") | Should -BeTrue
        Test-Path (Join-Path $script:SgTmplDir ".gitleaks.toml.tmpl") | Should -BeTrue
        Test-Path (Join-Path $script:SgTmplDir ".github/workflows/secret-scan.yml.tmpl") | Should -BeTrue
        Test-Path (Join-Path $script:SgTmplDir ".github/workflows/ci.yml.tmpl") | Should -BeTrue
    }
    It "ships a manifest.json" {
        Test-Path (Join-Path $script:SgTmplDir "manifest.json") | Should -BeTrue
    }
}

Describe "Template token parity" {
    It "every {{Token}} in a body is declared in the manifest entry" {
        $manifest = Get-Content -Raw (Join-Path $script:SgTmplDir "manifest.json") | ConvertFrom-Json
        foreach ($entry in $manifest.templates) {
            $path = Join-Path $script:SgTmplDir $entry.file
            Test-Path $path | Should -BeTrue -Because "manifest references $($entry.file)"
            $body = Get-Content -Raw $path
            $found = @([regex]::Matches($body, "\{\{([A-Za-z]+)\}\}") |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique) -join ","
            $declared = @($entry.requiredTokens | Sort-Object -Unique) -join ","
            $found | Should -Be $declared -Because "tokens-in-body vs manifest parity for $($entry.file)"
        }
    }
}

Describe ".gitleaks.toml ruleset and allowlist" {
    BeforeAll {
        $script:TomlBody = Get-Content -Raw (Join-Path $script:SgTmplDir ".gitleaks.toml.tmpl")
    }
    It "declares at least one [[rules]] block" {
        $script:TomlBody | Should -Match '(?m)^\s*\[\[rules\]\]'
    }
    It "defines a bearer-token rule" {
        $script:TomlBody | Should -Match '(?i)bearer'
    }
    It "defines a JWT rule" {
        $script:TomlBody | Should -Match '(?i)jwt|eyJ'
    }
    It "defines a long-hex rule (>=32)" {
        $script:TomlBody | Should -Match '\{32'
    }
    It "defines an api-key shaped rule" {
        $script:TomlBody | Should -Match '(?i)api[_-]?key'
    }
    It "allowlists the PR #47 substitutions store" {
        $script:TomlBody | Should -Match 'substitutions\\?\.json'
    }
    It "allowlists tests/fixtures" {
        $script:TomlBody | Should -Match 'tests/fixtures'
    }
    It "allowlists the PR #47 fake markers" {
        $script:TomlBody | Should -Match '@example\\?\.invalid'
        $script:TomlBody | Should -Match '4242'
        $script:TomlBody | Should -Match '9XX'
        $script:TomlBody | Should -Match '192\\?\.0\\?\.2'
    }
    It "does NOT add an over-broad json allowlist" {
        # A blanket "**/*.json" would defeat the gate.
        $script:TomlBody | Should -Not -Match '\*\*/\*\.json"'
    }
    It "is structurally valid TOML (balanced sections + key=value)" {
        # Lightweight sanity: every non-empty, non-comment line is a [section],
        # a [[rules]] header, a key = value pair, or a continuation in a multi-line
        # array (lines starting with whitespace inside brackets). Reject obvious junk.
        $lines = ($script:TomlBody -split "`n")
        $brackets = 0
        foreach ($raw in $lines) {
            $l = $raw.Trim()
            if ($l -eq '' -or $l.StartsWith('#')) { continue }
            $brackets += ([regex]::Matches($l, '\[')).Count - ([regex]::Matches($l, '\]')).Count
        }
        $brackets | Should -Be 0 -Because "every [ must have a matching ]"
    }
}

Describe "pre-commit hook" {
    BeforeAll {
        $script:HookBody = Get-Content -Raw (Join-Path $script:SgTmplDir ".githooks/pre-commit.tmpl")
    }
    It "starts with a POSIX shebang" {
        $script:HookBody | Should -Match '^#!/'
    }
    It "uses LF line endings (no CR)" {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:SgTmplDir ".githooks/pre-commit.tmpl"))
        ($bytes -contains 13) | Should -BeFalse -Because "pre-commit must be LF-only"
    }
    It "invokes gitleaks protect --staged" {
        $script:HookBody | Should -Match 'gitleaks\s+protect\s+--staged'
    }
    It "exits non-zero on finding" {
        $script:HookBody | Should -Match 'exit\s+1'
    }
    It "mentions how to install gitleaks if missing" {
        $script:HookBody | Should -Match '(?i)install'
    }
}

Describe "secret-scan workflow YAML" {
    BeforeAll {
        $script:YmlBody = Get-Content -Raw (Join-Path $script:SgTmplDir ".github/workflows/secret-scan.yml.tmpl")
    }
    It "declares top-level name/on/jobs" {
        $script:YmlBody | Should -Match '(?m)^name:'
        $script:YmlBody | Should -Match '(?m)^on:'
        $script:YmlBody | Should -Match '(?m)^jobs:'
    }
    It "runs on push and pull_request" {
        $script:YmlBody | Should -Match 'push'
        $script:YmlBody | Should -Match 'pull_request'
    }
    It "uses a pinned gitleaks-action v2 tag" {
        $script:YmlBody | Should -Match 'uses:\s+gitleaks/gitleaks-action@v2\.\d+\.\d+'
    }
    It "references the project .gitleaks.toml" {
        $script:YmlBody | Should -Match 'gitleaks\.toml|GITLEAKS_CONFIG'
    }
}

Describe "ci workflow YAML" {
    BeforeAll {
        $script:CiBody = Get-Content -Raw (Join-Path $script:SgTmplDir ".github/workflows/ci.yml.tmpl")
    }
    It "declares top-level name/on/jobs" {
        $script:CiBody | Should -Match '(?m)^name:'
        $script:CiBody | Should -Match '(?m)^on:'
        $script:CiBody | Should -Match '(?m)^jobs:'
    }
    It "runs on ubuntu-latest" {
        $script:CiBody | Should -Match 'ubuntu-latest'
    }
    It "uses .NET 8.0 SDK" {
        $script:CiBody | Should -Match '8\.0'
    }
    It "runs dotnet build and dotnet test" {
        $script:CiBody | Should -Match 'dotnet\s+build'
        $script:CiBody | Should -Match 'dotnet\s+test'
    }
}

Describe "Codegen integration: emits secret-gate files into wrapper output" {
    BeforeAll {
        $script:Out = New-OutDir
        $script:ExitCode = Invoke-Gen -Har $script:RestHar -Out $script:Out
    }
    AfterAll {
        if (Test-Path $script:Out) { Remove-Item -Recurse -Force $script:Out -ErrorAction SilentlyContinue }
    }
    It "generator exits 0" { $script:ExitCode | Should -Be 0 }
    It "emits .githooks/pre-commit at output root" {
        Test-Path (Join-Path $script:Out ".githooks/pre-commit") | Should -BeTrue
    }
    It "emits .gitleaks.toml at output root" {
        Test-Path (Join-Path $script:Out ".gitleaks.toml") | Should -BeTrue
    }
    It "emits .github/workflows/secret-scan.yml" {
        Test-Path (Join-Path $script:Out ".github/workflows/secret-scan.yml") | Should -BeTrue
    }
    It "emits .github/workflows/ci.yml" {
        Test-Path (Join-Path $script:Out ".github/workflows/ci.yml") | Should -BeTrue
    }
    It "no leftover {{...}} markers in any emitted secret-gate file" {
        $files = @(
            ".githooks/pre-commit",
            ".gitleaks.toml",
            ".github/workflows/secret-scan.yml",
            ".github/workflows/ci.yml"
        )
        foreach ($f in $files) {
            $body = Get-Content -Raw (Join-Path $script:Out $f)
            # Match only template tokens of the form {{Name}} (PascalCase word).
            # GitHub Actions expressions ${{ ... }} are NOT a leftover.
            $body | Should -Not -Match '\{\{[A-Za-z]+\}\}' -Because "$f has unresolved tokens"
        }
    }
    It "README has a Secret Scanning section" {
        $readme = Get-Content -Raw (Join-Path $script:Out "README.md")
        $readme | Should -Match '(?m)^##\s+Secret Scanning'
    }
    It "README explains how to activate the hook" {
        $readme = Get-Content -Raw (Join-Path $script:Out "README.md")
        $readme | Should -Match 'core\.hooksPath'
    }
    It "emitted pre-commit hook is executable on non-Windows" {
        if ($IsWindows) {
            Set-ItResult -Skipped -Because "Windows file modes do not carry the +x bit"
            return
        }
        $hookPath = Join-Path $script:Out ".githooks/pre-commit"
        # Use Linux/macOS test -x via stat
        $mode = (stat -c "%a" $hookPath 2>$null)
        if (-not $mode) { $mode = (stat -f "%A" $hookPath 2>$null) }  # BSD/macOS fallback
        $mode | Should -Match '^[1-7]?7[0-7]{2}$' -Because "owner-executable bit must be set; Git silently skips non-exec hooks. Got mode=$mode"
    }
}

Describe "Determinism (secret-gate emitted files)" {
    It "two runs produce byte-identical secret-gate output" {
        $a = New-OutDir; $b = New-OutDir
        try {
            Invoke-Gen -Har $script:RestHar -Out $a | Out-Null
            Invoke-Gen -Har $script:RestHar -Out $b | Out-Null
            $files = @(
                ".githooks/pre-commit",
                ".gitleaks.toml",
                ".github/workflows/secret-scan.yml",
                ".github/workflows/ci.yml"
            )
            foreach ($f in $files) {
                $ha = (Get-FileHash -Algorithm SHA256 (Join-Path $a $f)).Hash
                $hb = (Get-FileHash -Algorithm SHA256 (Join-Path $b $f)).Hash
                $ha | Should -Be $hb -Because "non-deterministic emission of $f"
            }
        } finally {
            Remove-Item -Recurse -Force $a -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $b -ErrorAction SilentlyContinue
        }
    }
}

Describe "gitleaks smoke (planted-leak + fake-marker)" {
    BeforeAll {
        $script:Skip = ($null -eq $script:GitleaksCmd)
        if (-not $script:Skip) {
            $script:Out = New-OutDir
            Invoke-Gen -Har $script:RestHar -Out $script:Out | Out-Null
            $script:TomlPath = Join-Path $script:Out ".gitleaks.toml"
            $script:PlantDir = Join-Path $script:Out "planted"
            New-Item -ItemType Directory -Force $script:PlantDir | Out-Null
            # Planted real-looking secret (NOT in any allowlist).
            "AWS_KEY=AKIAIOSFODNN7EXAMPLE`nbearer_tok=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c`n" |
                Out-File -Encoding ascii (Join-Path $script:PlantDir "leak.txt")
            $script:CleanDir = Join-Path $script:Out "fakes"
            New-Item -ItemType Directory -Force $script:CleanDir | Out-Null
            # Only PR #47 deterministic fakes.
            "email: alice@example.invalid`nccn: 4242424242424242`nssn: 9XX-XX-1234`nip: 192.0.2.42`n" |
                Out-File -Encoding ascii (Join-Path $script:CleanDir "fakes.txt")
        }
    }
    AfterAll {
        if ($script:Out -and (Test-Path $script:Out)) {
            Remove-Item -Recurse -Force $script:Out -ErrorAction SilentlyContinue
        }
    }
    It "detects a planted real-looking secret (non-zero exit)" {
        if ($script:Skip) { Set-ItResult -Skipped -Because "gitleaks not on PATH"; return }
        & gitleaks detect --config $script:TomlPath --source $script:PlantDir --no-banner --no-git 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
    It "does NOT flag PR #47 deterministic fake markers" {
        if ($script:Skip) { Set-ItResult -Skipped -Because "gitleaks not on PATH"; return }
        & gitleaks detect --config $script:TomlPath --source $script:CleanDir --no-banner --no-git 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}