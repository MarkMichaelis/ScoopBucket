#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the api-wrapper-scaffold auth detector (issue #40).
# Exercises detect-auth.js and its exported classifyAuth function against
# 8 hand-crafted synthetic HAR fixtures (one per supported AuthModel + ambiguous).

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:DetectJs   = Join-Path $script:ScriptsDir 'detect-auth.js'
    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures/har'

    function Invoke-Detect {
        param([Parameter(Mandatory)][string]$Fixture)
        $path = Join-Path $script:FixturesDir $Fixture
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Fixture not found: $path"
        }
        $stdout = & node $script:DetectJs $path 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "detect-auth.js exited $LASTEXITCODE for fixture $Fixture"
        }
        return ($stdout -join "`n") | ConvertFrom-Json
    }
}

Describe 'detect-auth.js classifier' {

    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:DetectJs | Should -BeTrue
    }

    It 'classifies cookie-only HAR as cookie' {
        $r = Invoke-Detect 'cookie.har'
        $r.authModel | Should -Be 'cookie'
        $r.evidence.Count | Should -BeGreaterThan 0
    }

    It 'classifies cookie + X-CSRF-Token HAR as cookie+csrf' {
        $r = Invoke-Detect 'cookie-csrf.har'
        $r.authModel | Should -Be 'cookie+csrf'
        $r.evidence.Count | Should -BeGreaterThan 0
    }

    It 'classifies plain Bearer HAR as bearer' {
        $r = Invoke-Detect 'bearer.har'
        $r.authModel | Should -Be 'bearer'
    }

    It 'classifies Google SSO redirect + Bearer as sso-google with idpName Google' {
        $r = Invoke-Detect 'sso-google.har'
        $r.authModel | Should -Be 'sso-google'
        $r.idpName   | Should -Be 'Google'
    }

    It 'classifies Microsoft SSO redirect + Bearer as sso-microsoft' {
        $r = Invoke-Detect 'sso-microsoft.har'
        $r.authModel | Should -Be 'sso-microsoft'
        $r.idpName   | Should -Be 'Microsoft'
    }

    It 'classifies Facebook OAuth dialog + Bearer as sso-facebook' {
        $r = Invoke-Detect 'sso-facebook.har'
        $r.authModel | Should -Be 'sso-facebook'
        $r.idpName   | Should -Be 'Facebook'
    }

    It 'classifies code_challenge_method=S256 + Bearer as oauth2-pkce' {
        $r = Invoke-Detect 'oauth2-pkce.har'
        $r.authModel | Should -Be 'oauth2-pkce'
    }

    It 'returns unknown with non-empty evidence for an ambiguous HAR' {
        $r = Invoke-Detect 'ambiguous.har'
        $r.authModel | Should -Be 'unknown'
        $r.evidence  | Should -Not -BeNullOrEmpty
    }

    It 'CLI exits non-zero when the HAR file does not exist' {
        $missing = Join-Path ([IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid() + ".har")
        & node $script:DetectJs $missing 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'CLI exits non-zero when no argument is given' {
        & node $script:DetectJs 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'detect-auth.js Akamai bot-management cookie detection (issue #66)' {
    BeforeAll {
        function New-AkamaiHar {
            param(
                [string[]] $RequestCookieNames = @(),
                [string[]] $SetCookieNames     = @()
            )
            $reqCookieValue = ($RequestCookieNames | ForEach-Object { "$_=opaque" }) -join '; '
            $reqHeaders = @(
                @{ name = 'Accept'; value = 'application/json' }
            )
            if ($reqCookieValue) {
                $reqHeaders += @{ name = 'Cookie'; value = $reqCookieValue }
            }
            $respHeaders = @(
                @{ name = 'Content-Type'; value = 'application/json' }
            )
            foreach ($n in $SetCookieNames) {
                $respHeaders += @{ name = 'Set-Cookie'; value = "$n=opaque; Path=/; HttpOnly" }
            }
            $har = @{
                log = @{
                    entries = @(
                        @{
                            startedDateTime = '2026-01-01T00:00:00Z'
                            request  = @{
                                method = 'GET'
                                url    = 'https://api.example.com/v1/widgets'
                                httpVersion = 'HTTP/1.1'
                                cookies = @()
                                headers = $reqHeaders
                                queryString = @()
                                headersSize = -1
                                bodySize = 0
                            }
                            response = @{
                                status      = 200
                                statusText  = 'OK'
                                httpVersion = 'HTTP/1.1'
                                cookies     = @()
                                headers     = $respHeaders
                                content     = @{ size = 0; mimeType = 'application/json'; text = '{}' }
                                redirectURL = ''
                                headersSize = -1
                                bodySize    = 0
                            }
                            cache    = @{}
                            timings  = @{ send = 0; wait = 1; receive = 0 }
                            time     = 1
                        }
                    )
                }
            }
            $path = Join-Path ([IO.Path]::GetTempPath()) ("akamai-" + [guid]::NewGuid() + ".har")
            Set-Content -Encoding utf8 -LiteralPath $path -Value ($har | ConvertTo-Json -Depth 12)
            return $path
        }

        function Invoke-DetectPath {
            param([Parameter(Mandatory)][string]$Path)
            $stdout = & node $script:DetectJs $Path 2>$null
            if ($LASTEXITCODE -ne 0) { throw "detect-auth.js exited $LASTEXITCODE" }
            return ($stdout -join "`n") | ConvertFrom-Json
        }
    }

    It 'flags _abck when present in request Cookie header' {
        $p = New-AkamaiHar -RequestCookieNames @('_abck','session_id')
        $r = Invoke-DetectPath -Path $p
        $r.antiBotCookies | Should -Contain '_abck'
    }

    It 'flags bm_sz when present in Set-Cookie response header' {
        $p = New-AkamaiHar -SetCookieNames @('bm_sz')
        $r = Invoke-DetectPath -Path $p
        $r.antiBotCookies | Should -Contain 'bm_sz'
    }

    It 'flags bm_sv when present in request Cookie header' {
        $p = New-AkamaiHar -RequestCookieNames @('bm_sv')
        $r = Invoke-DetectPath -Path $p
        $r.antiBotCookies | Should -Contain 'bm_sv'
    }

    It 'flags ak_bmsc when present in Set-Cookie response header' {
        $p = New-AkamaiHar -SetCookieNames @('ak_bmsc')
        $r = Invoke-DetectPath -Path $p
        $r.antiBotCookies | Should -Contain 'ak_bmsc'
    }

    It 'does NOT emit antiBotCookies array when no Akamai cookies are present' {
        $p = New-AkamaiHar -RequestCookieNames @('session_id') -SetCookieNames @('session_id')
        $r = Invoke-DetectPath -Path $p
        # Either absent, or present and empty.
        if ($null -ne $r.antiBotCookies) {
            @($r.antiBotCookies).Count | Should -Be 0
        }
    }
}
