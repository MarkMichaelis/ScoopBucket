#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the api-wrapper-scaffold capture/scrub script templates
# (issue #36). These exercise sanitize-har.js, verify-scrub.js, and
# Invoke-SanitizeHar.ps1 against a synthetic HAR fixture.

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:SanitizeJs = Join-Path $script:ScriptsDir 'sanitize-har.js'
    $script:VerifyJs   = Join-Path $script:ScriptsDir 'verify-scrub.js'
    $script:WrapperPs1 = Join-Path $script:ScriptsDir 'Invoke-SanitizeHar.ps1'
    $script:CaptureJs  = Join-Path $script:ScriptsDir 'capture-cdp.js'

    function New-FixtureHar {
        param(
            [Parameter(Mandatory)][string]$Path,
            [string]$Jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c',
            [string]$HexToken = ('a' * 64),
            [string]$Email = 'jane.doe@example.com'
        )
        $har = @{
            log = @{
                version = '1.2'
                creator = @{ name = 'test'; version = '1.0' }
                entries = @(
                    @{
                        startedDateTime = '2026-01-01T00:00:00Z'
                        time            = 1
                        request         = @{
                            method      = 'GET'
                            url         = 'https://example.com/api/me'
                            httpVersion = 'HTTP/1.1'
                            headers     = @(
                                @{ name = 'Authorization'; value = "Bearer $Jwt" },
                                @{ name = 'Cookie';        value = "session=$HexToken" },
                                @{ name = 'X-User-Email';  value = $Email }
                            )
                            queryString = @()
                            cookies     = @()
                            headersSize = -1
                            bodySize    = 0
                        }
                        response        = @{
                            status      = 200
                            statusText  = 'OK'
                            httpVersion = 'HTTP/1.1'
                            headers     = @(
                                @{ name = 'Set-Cookie'; value = "session=$HexToken; Path=/" }
                            )
                            cookies     = @()
                            content     = @{
                                size     = 0
                                mimeType = 'application/json'
                                text     = "{`"email`":`"$Email`",`"token`":`"$Jwt`"}"
                            }
                            redirectURL = ''
                            headersSize = -1
                            bodySize    = 0
                        }
                        cache           = @{}
                        timings         = @{ send = 0; wait = 1; receive = 0 }
                    }
                )
            }
        }
        $json = $har | ConvertTo-Json -Depth 20
        Set-Content -LiteralPath $Path -Value $json -Encoding utf8
    }
}

Describe 'sanitize-har.js' {

    BeforeEach {
        $script:Tmp     = Join-Path ([IO.Path]::GetTempPath()) ("har-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $script:InHar   = Join-Path $script:Tmp 'in.har'
        $script:OutHar  = Join-Path $script:Tmp 'out.har'
        $script:SubsMap = Join-Path $script:Tmp 'subs.json'
        New-FixtureHar -Path $script:InHar
    }

    AfterEach {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
            Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:SanitizeJs | Should -BeTrue
    }

    It 'removes a JWT from the scrubbed HAR' {
        & node $script:SanitizeJs --in $script:InHar --out $script:OutHar --subs $script:SubsMap --salt 'test-salt'
        $LASTEXITCODE | Should -Be 0
        $scrubbed = Get-Content -LiteralPath $script:OutHar -Raw
        $scrubbed | Should -Not -Match 'eyJhbGciOiJIUzI1NiJ9'
    }

    It 'removes a 64-char hex session token from the scrubbed HAR' {
        & node $script:SanitizeJs --in $script:InHar --out $script:OutHar --subs $script:SubsMap --salt 'test-salt'
        $LASTEXITCODE | Should -Be 0
        $scrubbed = Get-Content -LiteralPath $script:OutHar -Raw
        $scrubbed | Should -Not -Match ('a' * 64)
    }

    It 'removes email addresses from the scrubbed HAR' {
        & node $script:SanitizeJs --in $script:InHar --out $script:OutHar --subs $script:SubsMap --salt 'test-salt'
        $LASTEXITCODE | Should -Be 0
        $scrubbed = Get-Content -LiteralPath $script:OutHar -Raw
        $scrubbed | Should -Not -Match 'jane\.doe@example\.com'
    }

    It 'persists a substitution map' {
        & node $script:SanitizeJs --in $script:InHar --out $script:OutHar --subs $script:SubsMap --salt 'test-salt'
        Test-Path -LiteralPath $script:SubsMap | Should -BeTrue
        $map = Get-Content -LiteralPath $script:SubsMap -Raw | ConvertFrom-Json
        $map.PSObject.Properties.Count | Should -BeGreaterThan 0
    }

    It 'is deterministic: same input + same salt produce same output' {
        $out1 = Join-Path $script:Tmp 'out1.har'
        $out2 = Join-Path $script:Tmp 'out2.har'
        & node $script:SanitizeJs --in $script:InHar --out $out1 --subs (Join-Path $script:Tmp 's1.json') --salt 'fixed'
        & node $script:SanitizeJs --in $script:InHar --out $out2 --subs (Join-Path $script:Tmp 's2.json') --salt 'fixed'
        (Get-FileHash $out1).Hash | Should -Be (Get-FileHash $out2).Hash
    }
}

Describe 'verify-scrub.js' {

    BeforeEach {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("verify-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $script:CleanHar = Join-Path $script:Tmp 'clean.har'
        New-FixtureHar -Path (Join-Path $script:Tmp 'src.har')
        & node $script:SanitizeJs `
            --in   (Join-Path $script:Tmp 'src.har') `
            --out  $script:CleanHar `
            --subs (Join-Path $script:Tmp 'subs.json') `
            --salt 'test'
    }

    AfterEach {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
            Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:VerifyJs | Should -BeTrue
    }

    It 'exits zero on a properly scrubbed HAR' {
        & node $script:VerifyJs --in $script:CleanHar
        $LASTEXITCODE | Should -Be 0
    }

    It 'exits non-zero when a JWT is planted in the HAR' {
        $leaked = Join-Path $script:Tmp 'leaked.har'
        $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJsZWFrZWQifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'
        $payload = '{"log":{"entries":[{"response":{"content":{"text":"token=' + $jwt + '"}}}]}}'
        Set-Content -LiteralPath $leaked -Value $payload -Encoding utf8
        & node $script:VerifyJs --in $leaked 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'exits non-zero when a long hex token is planted in the HAR' {
        $leaked = Join-Path $script:Tmp 'leaked-hex.har'
        $hex = 'F' * 64
        $payload = '{"log":{"entries":[{"response":{"content":{"text":"session=' + $hex + '"}}}]}}'
        Set-Content -LiteralPath $leaked -Value $payload -Encoding utf8
        & node $script:VerifyJs --in $leaked 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'Invoke-SanitizeHar.ps1' {

    BeforeEach {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("wrap-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $script:InHar = Join-Path $script:Tmp 'in.har'
        $script:OutHar = Join-Path $script:Tmp 'out.har'
        New-FixtureHar -Path $script:InHar
    }

    AfterEach {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
            Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:WrapperPs1 | Should -BeTrue
    }

    It 'runs sanitize then verify and produces a scrubbed HAR' {
        & $script:WrapperPs1 -InputHar $script:InHar -OutputHar $script:OutHar -Salt 'test'
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $script:OutHar | Should -BeTrue
        (Get-Content -LiteralPath $script:OutHar -Raw) | Should -Not -Match 'eyJhbGciOiJIUzI1NiJ9'
    }

    It 'propagates a non-zero exit code when verification fails' {
        $leaked = Join-Path $script:Tmp 'leaked.har'
        $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJsZWFrZWQifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'
        $payload = '{"log":{"entries":[{"response":{"content":{"text":"' + $jwt + '"}}}]}}'
        Set-Content -LiteralPath $leaked -Value $payload -Encoding utf8
        & $script:WrapperPs1 -InputHar $leaked -OutputHar (Join-Path $script:Tmp 'ignored.har') -Salt 'test' -VerifyOnly 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'capture-cdp.js' {
    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:CaptureJs | Should -BeTrue
    }

    It 'is valid JavaScript (parses without syntax errors)' {
        # `node --check` returns 0 on valid syntax, non-zero on parse error.
        & node --check $script:CaptureJs 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'documents the --storage-state flag' {
        (Get-Content -LiteralPath $script:CaptureJs -Raw) | Should -Match '--storage-state'
    }

    It 'documents the --out flag for HAR output' {
        (Get-Content -LiteralPath $script:CaptureJs -Raw) | Should -Match '--out'
    }
}
