#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the PII scrubbing pipeline (issue #46).
# Exercises typed PII detection, deterministic faker, substitutions store,
# verify-pass for typed PII, backwards-compat with PR #37, and the
# pii-llm-enrich stub.

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:SanitizeJs = Join-Path $script:ScriptsDir 'sanitize-har.js'
    $script:VerifyJs   = Join-Path $script:ScriptsDir 'verify-scrub.js'
    $script:PiiJs      = Join-Path $script:ScriptsDir 'pii.js'
    $script:EnrichJs   = Join-Path $script:ScriptsDir 'pii-enrich.js'
    $script:Planted    = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/pii-planted.har'

    function New-LegacyHar {
        param([Parameter(Mandatory)][string]$Path)
        $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'
        $hex = ('a' * 64)
        $payload = '{"log":{"entries":[{"request":{"headers":[{"name":"Authorization","value":"Bearer ' + $jwt + '"},{"name":"Cookie","value":"session=' + $hex + '"}]},"response":{"content":{"text":"{\"token\":\"' + $jwt + '\"}"}}}]}}'
        Set-Content -LiteralPath $Path -Value $payload -Encoding utf8 -NoNewline
    }
}

Describe 'pii.js shared module' {
    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:PiiJs | Should -BeTrue
    }

    It 'parses without syntax errors' {
        & node --check $script:PiiJs 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'pii-type-detect' {

    BeforeAll {
        $script:DetectScript = @"
const path = require('path');
const fs = require('fs');
const pii = require(path.resolve(process.argv[2]));
const har = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const detections = pii.detectPii(har);
process.stdout.write(JSON.stringify(detections));
"@
        $script:DetectScriptPath = Join-Path ([IO.Path]::GetTempPath()) ("pii-detect-" + [guid]::NewGuid() + ".js")
        Set-Content -LiteralPath $script:DetectScriptPath -Value $script:DetectScript -Encoding utf8

        $script:Detections = & node $script:DetectScriptPath $script:PiiJs $script:Planted | ConvertFrom-Json
    }

    AfterAll {
        if ($script:DetectScriptPath -and (Test-Path -LiteralPath $script:DetectScriptPath)) {
            Remove-Item -LiteralPath $script:DetectScriptPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'detects email addresses' {
        ($script:Detections | Where-Object { $_.type -eq 'email' }).Count | Should -BeGreaterThan 0
    }

    It 'detects phone numbers in E.164 format' {
        ($script:Detections | Where-Object { $_.type -eq 'phone' -and $_.value -match '\+1' }).Count | Should -BeGreaterThan 0
    }

    It 'detects US SSN' {
        ($script:Detections | Where-Object { $_.type -eq 'ssn' -and $_.value -eq '123-45-6789' }).Count | Should -Be 1
    }

    It 'detects Luhn-valid credit-card numbers' {
        ($script:Detections | Where-Object { $_.type -eq 'credit-card' -and $_.value -eq '4111111111111111' }).Count | Should -Be 1
    }

    It 'detects person-name via context (firstName field)' {
        ($script:Detections | Where-Object { $_.type -eq 'person-name' -and $_.value -eq 'Alice' }).Count | Should -BeGreaterThan 0
    }

    It 'detects street-address via context' {
        ($script:Detections | Where-Object { $_.type -eq 'street-address' -and $_.value -eq '742 Evergreen Terrace' }).Count | Should -BeGreaterThan 0
    }

    It 'detects city via context' {
        ($script:Detections | Where-Object { $_.type -eq 'city' -and $_.value -eq 'Springfield' }).Count | Should -BeGreaterThan 0
    }

    It 'detects postal-code via context' {
        ($script:Detections | Where-Object { $_.type -eq 'postal-code' -and $_.value -eq '62704' }).Count | Should -Be 1
    }

    It 'detects date-of-birth via context' {
        ($script:Detections | Where-Object { $_.type -eq 'dob' -and $_.value -eq '1985-06-15' }).Count | Should -Be 1
    }

    It 'detects IPv4 addresses' {
        ($script:Detections | Where-Object { $_.type -eq 'ip-address' -and $_.value -eq '203.0.113.42' }).Count | Should -BeGreaterThan 0
    }

    It 'detects geo-coordinates via context' {
        ($script:Detections | Where-Object { $_.type -eq 'geo-coordinates' }).Count | Should -BeGreaterOrEqual 2
    }

    It 'each detection has a location record' {
        $script:Detections | ForEach-Object { $_.location | Should -Not -BeNullOrEmpty }
    }
}

Describe 'pii-faker determinism' {

    BeforeAll {
        $script:FakerScript = @"
const path = require('path');
const pii = require(path.resolve(process.argv[2]));
const type = process.argv[3];
const value = process.argv[4];
process.stdout.write(JSON.stringify({ a: pii.fakeFor(type, value), b: pii.fakeFor(type, value) }));
"@
        $script:FakerScriptPath = Join-Path ([IO.Path]::GetTempPath()) ("pii-faker-" + [guid]::NewGuid() + ".js")
        Set-Content -LiteralPath $script:FakerScriptPath -Value $script:FakerScript -Encoding utf8
    }

    AfterAll {
        if ($script:FakerScriptPath -and (Test-Path -LiteralPath $script:FakerScriptPath)) {
            Remove-Item -LiteralPath $script:FakerScriptPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'produces identical output for identical inputs (email)' {
        $r = & node $script:FakerScriptPath $script:PiiJs 'email' 'alice@contoso.com' | ConvertFrom-Json
        $r.a | Should -Be $r.b
    }

    It 'fake email is RFC-shaped and uses example.invalid' {
        $r = & node $script:FakerScriptPath $script:PiiJs 'email' 'someone@real.com' | ConvertFrom-Json
        $r.a | Should -Match '^[A-Za-z0-9._%+-]+@example\.invalid$'
    }

    It 'fake phone uses E.164 with 555 area code' {
        $r = & node $script:FakerScriptPath $script:PiiJs 'phone' '+12025551111' | ConvertFrom-Json
        $r.a | Should -Match '^\+1555\d{7}$'
    }

    It 'fake SSN uses 9XX prefix (never issued)' {
        $r = & node $script:FakerScriptPath $script:PiiJs 'ssn' '111-22-3333' | ConvertFrom-Json
        $r.a | Should -Match '^9\d{2}-\d{2}-\d{4}$'
    }

    It 'fake credit-card passes Luhn check' {
        $r = & node $script:FakerScriptPath $script:PiiJs 'credit-card' '4111111111111111' | ConvertFrom-Json
        $cc = $r.a
        $cc | Should -Match '^\d{13,19}$'
        # Luhn
        $sum = 0; $alt = $false
        for ($i = $cc.Length - 1; $i -ge 0; $i--) {
            $d = [int][string]$cc[$i]
            if ($alt) { $d *= 2; if ($d -gt 9) { $d -= 9 } }
            $sum += $d; $alt = -not $alt
        }
        ($sum % 10) | Should -Be 0
    }

    It 'fake person-name is from embedded word list' {
        $r = & node $script:FakerScriptPath $script:PiiJs 'person-name' 'Alice Johnson' | ConvertFrom-Json
        $r.a | Should -Match '^[A-Z][a-z]+( [A-Z][a-z]+)?$'
    }
}

Describe 'sanitize-har.js with PII pipeline' {

    BeforeEach {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("pii-sani-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $script:OutHar  = Join-Path $script:Tmp 'out.har'
        $script:Subs    = Join-Path $script:Tmp 'subs.json'
        $script:PiiSubs = Join-Path $script:Tmp '.substitutions.json'
    }

    AfterEach {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
            Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'removes all planted PII originals from the scrubbed HAR' {
        & node $script:SanitizeJs --in $script:Planted --out $script:OutHar --subs $script:Subs --pii-subs $script:PiiSubs --salt 'test-salt'
        $LASTEXITCODE | Should -Be 0
        $content = Get-Content -LiteralPath $script:OutHar -Raw
        $content | Should -Not -Match 'alice\.johnson@contoso\.com'
        $content | Should -Not -Match '123-45-6789'
        $content | Should -Not -Match '4111111111111111'
        $content | Should -Not -Match '742 Evergreen Terrace'
        $content | Should -Not -Match 'Springfield'
        $content | Should -Not -Match '\+12025551234'
        $content | Should -Not -Match '"Alice"'
        $content | Should -Not -Match '1985-06-15'
    }

    It 'writes a substitutions store with the required schema' {
        & node $script:SanitizeJs --in $script:Planted --out $script:OutHar --subs $script:Subs --pii-subs $script:PiiSubs --salt 'test' --fixed-time '2026-01-01T00:00:00Z'
        Test-Path -LiteralPath $script:PiiSubs | Should -BeTrue
        $raw = Get-Content -LiteralPath $script:PiiSubs -Raw
        $raw | Should -Match '"version":\s*1'
        $raw | Should -Match '"createdAt":\s*"\d{4}-\d{2}-\d{2}T'
        $store = $raw | ConvertFrom-Json -AsHashtable
        $store['substitutions'].Count | Should -BeGreaterThan 0
        $store['substitutions'][0]['type']         | Should -Not -BeNullOrEmpty
        $store['substitutions'][0]['originalHash'] | Should -Match '^[0-9a-f]{8}$'
        $store['substitutions'][0]['replacement']  | Should -Not -BeNullOrEmpty
        $store['substitutions'][0]['locations']    | Should -Not -BeNullOrEmpty
    }

    It 'substitutions store contains NO plaintext originals (security-critical)' {
        & node $script:SanitizeJs --in $script:Planted --out $script:OutHar --subs $script:Subs --pii-subs $script:PiiSubs --salt 'test'
        $raw = Get-Content -LiteralPath $script:PiiSubs -Raw
        $raw | Should -Not -Match 'alice\.johnson@contoso\.com'
        $raw | Should -Not -Match 'john\.actual@gmail\.com'
        $raw | Should -Not -Match '123-45-6789'
        $raw | Should -Not -Match '4111111111111111'
        $raw | Should -Not -Match '742 Evergreen Terrace'
        $raw | Should -Not -Match 'Springfield'
        $raw | Should -Not -Match '"Alice"'
        # generic guard: no obvious-email pattern at all in the safe file
        $raw | Should -Not -Match '[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    }

    It 'is deterministic: identical inputs produce byte-identical .substitutions.json' {
        $a = Join-Path $script:Tmp 'a.substitutions.json'
        $b = Join-Path $script:Tmp 'b.substitutions.json'
        & node $script:SanitizeJs --in $script:Planted --out (Join-Path $script:Tmp 'a.har') --subs (Join-Path $script:Tmp 'as.json') --pii-subs $a --salt 'test' --fixed-time '2026-01-01T00:00:00Z'
        & node $script:SanitizeJs --in $script:Planted --out (Join-Path $script:Tmp 'b.har') --subs (Join-Path $script:Tmp 'bs.json') --pii-subs $b --salt 'test' --fixed-time '2026-01-01T00:00:00Z'
        (Get-FileHash $a).Hash | Should -Be (Get-FileHash $b).Hash
    }
}

Describe 'verify-scrub.js typed-PII pass' {

    BeforeEach {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("pii-verify-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    }

    AfterEach {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
            Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails (exit non-zero) when an unscrubbed real email is present' {
        $leaked = Join-Path $script:Tmp 'l.har'
        '{"log":{"entries":[{"response":{"content":{"text":"contact me at real.person@gmail.com please"}}}]}}' | Set-Content -LiteralPath $leaked -Encoding utf8 -NoNewline
        $out = & node $script:VerifyJs --in $leaked 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'email'
    }

    It 'fails when an unscrubbed SSN is present' {
        $leaked = Join-Path $script:Tmp 'l.har'
        '{"log":{"entries":[{"response":{"content":{"text":"ssn=123-45-6789"}}}]}}' | Set-Content -LiteralPath $leaked -Encoding utf8 -NoNewline
        $out = & node $script:VerifyJs --in $leaked 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'ssn'
    }

    It 'fails when an unscrubbed credit-card is present' {
        $leaked = Join-Path $script:Tmp 'l.har'
        '{"log":{"entries":[{"response":{"content":{"text":"card=4111111111111111"}}}]}}' | Set-Content -LiteralPath $leaked -Encoding utf8 -NoNewline
        $out = & node $script:VerifyJs --in $leaked 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'credit-card'
    }

    It 'fails when an unscrubbed real phone (non-555 area) is present' {
        $leaked = Join-Path $script:Tmp 'l.har'
        '{"log":{"entries":[{"response":{"content":{"text":"call +12025557777 wait that is fake try +14155551234 hmm also fake use +12025551234 also fake. Real: +12025557788 no still fake. Real: +12127773322 ."}}}]}}' | Set-Content -LiteralPath $leaked -Encoding utf8 -NoNewline
        # Use a clearly-non-555 number for clarity:
        '{"log":{"entries":[{"response":{"content":{"text":"call +12127773322"}}}]}}' | Set-Content -LiteralPath $leaked -Encoding utf8 -NoNewline
        $out = & node $script:VerifyJs --in $leaked 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'phone'
    }

    It 'passes when output of sanitize-har is fed back in' {
        $out = Join-Path $script:Tmp 'sanitized.har'
        & node $script:SanitizeJs --in $script:Planted --out $out --subs (Join-Path $script:Tmp 's.json') --pii-subs (Join-Path $script:Tmp '.substitutions.json') --salt 'test'
        & node $script:VerifyJs --in $out 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'backwards compatibility with PR #37' {

    BeforeEach {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("pii-bc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $script:LegacyIn  = Join-Path $script:Tmp 'legacy.har'
        $script:LegacyOut = Join-Path $script:Tmp 'legacy-out.har'
        New-LegacyHar -Path $script:LegacyIn
    }

    AfterEach {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
            Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still scrubs JWTs from a PR #37-style fixture' {
        & node $script:SanitizeJs --in $script:LegacyIn --out $script:LegacyOut --subs (Join-Path $script:Tmp 's.json') --salt 'test'
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath $script:LegacyOut -Raw) | Should -Not -Match 'eyJhbGciOiJIUzI1NiJ9'
    }

    It 'still scrubs 64-char hex tokens from a PR #37-style fixture' {
        & node $script:SanitizeJs --in $script:LegacyIn --out $script:LegacyOut --subs (Join-Path $script:Tmp 's.json') --salt 'test'
        (Get-Content -LiteralPath $script:LegacyOut -Raw) | Should -Not -Match ('a' * 64)
    }

    It 'verify-scrub still flags planted JWTs (legacy behavior intact)' {
        $leaked = Join-Path $script:Tmp 'leak.har'
        $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJsZWFrZWQifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'
        '{"log":{"entries":[{"response":{"content":{"text":"token=' + $jwt + '"}}}]}}' | Set-Content -LiteralPath $leaked -Encoding utf8 -NoNewline
        & node $script:VerifyJs --in $leaked 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'pii-llm-enrich (stub)' {

    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:EnrichJs | Should -BeTrue
    }

    It 'parses without syntax errors' {
        & node --check $script:EnrichJs 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'exits 0 with an informational message when no provider is configured' {
        $env:LLM_PROVIDER = $null
        $out = & node $script:EnrichJs --in $script:Planted 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'no provider'
    }
}
