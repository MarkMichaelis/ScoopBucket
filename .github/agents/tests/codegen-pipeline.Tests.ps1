#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the HAR -> C# codegen pipeline (issue #48).

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts'
    $script:GenJs      = Join-Path $script:ScriptsDir 'generate-wrapper.js'
    $script:CaptureJs  = Join-Path $script:ScriptsDir 'capture-cdp.js'
    $script:RestHar    = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/rest-3endpoints.har'
    $script:GqlHar     = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/graphql.har'

    function New-OutDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("wrapgen-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $d | Out-Null
        return $d
    }

    function Invoke-Gen {
        param(
            [string[]]$Har,
            [string]$Out,
            [string]$ProjectName = 'ExampleEx',
            [string]$Namespace   = 'Example',
            [string]$BaseUrl     = 'https://api.example.com',
            [string]$Authors     = 'IntelliTect',
            [string]$Description = 'Example wrapper',
            [string]$RepoUrl     = 'https://github.com/example/example',
            [string]$Tags        = 'example;api;wrapper',
            [string]$AuthModel   = 'cookie'
        )
        $harArg = ($Har -join ',')
        $stdout = & node $script:GenJs `
            --har $harArg `
            --out $Out `
            --project-name $ProjectName `
            --namespace $Namespace `
            --base-url $BaseUrl `
            --auth-model $AuthModel `
            --authors $Authors `
            --description $Description `
            --repository-url $RepoUrl `
            --package-tags $Tags 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ($stdout -join "`n") }
    }
}

Describe 'generate-wrapper.js exists' {
    It 'lives at the canonical path' {
        Test-Path -LiteralPath $script:GenJs | Should -BeTrue
    }
    It 'parses without syntax errors' {
        & node --check $script:GenJs 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'har-codegen end-to-end (REST)' {
    BeforeAll {
        $script:RestOut = New-OutDir
        $script:RestRes = Invoke-Gen -Har @($script:RestHar) -Out $script:RestOut
    }
    AfterAll {
        if (Test-Path $script:RestOut) { Remove-Item -Recurse -Force $script:RestOut }
    }
    It 'exits 0' { $script:RestRes.ExitCode | Should -Be 0 }
    It 'emits Client.Generated.cs' {
        Test-Path (Join-Path $script:RestOut 'src/ExampleEx/ExampleExClient.Generated.cs') | Should -BeTrue
    }
    It 'emits Models.Generated.cs' {
        Test-Path (Join-Path $script:RestOut 'src/ExampleEx/Models.Generated.cs') | Should -BeTrue
    }
    It 'emits the .csproj' {
        Test-Path (Join-Path $script:RestOut 'src/ExampleEx/ExampleEx.csproj') | Should -BeTrue
    }
    It 'emits the hand-written Client.cs (template substituted)' {
        Test-Path (Join-Path $script:RestOut 'src/ExampleEx/Client.cs') | Should -BeTrue
    }
    It 'method names match URL paths' {
        $code = Get-Content (Join-Path $script:RestOut 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
        $code | Should -Match 'GetMeAsync'
        $code | Should -Match 'GetUsers.*Async'
    }
}

Describe 'endpoint-dedup' {
    It 'collapses /users/{int} into a single method with id param' {
        $out = New-OutDir
        try {
            $r = Invoke-Gen -Har @($script:RestHar) -Out $out
            $r.ExitCode | Should -Be 0
            $code = Get-Content (Join-Path $out 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
            # exactly one GetUsers<id>Async method (the /users/{id} endpoint)
            $matches = [regex]::Matches($code, 'public\s+async\s+Task<.*?>\s+GetUsersByIdAsync\s*\(')
            $matches.Count | Should -Be 1
            # signature carries an int id
            $code | Should -Match 'GetUsersByIdAsync\s*\(\s*int\s+id'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'shape-merging' {
    It 'merges /me captures into one record with nullable optional fields' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $models = Get-Content (Join-Path $out 'src/ExampleEx/Models.Generated.cs') -Raw
            # required fields (present in both): Id, Name, Email -> non-nullable string
            $models | Should -Match 'public\s+string\s+Id\s*\{\s*get'
            $models | Should -Match 'public\s+string\s+Email\s*\{\s*get'
            # optional field (only present in second capture): Avatar -> nullable
            $models | Should -Match 'public\s+string\?\s+Avatar\s*\{\s*get'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'graphql-detector' {
    It 'emits a GraphQLAsync method for graphql endpoints' {
        $out = New-OutDir
        try {
            $r = Invoke-Gen -Har @($script:GqlHar) -Out $out -ProjectName 'GqlEx' -Namespace 'Gql'
            $r.ExitCode | Should -Be 0
            $code = Get-Content (Join-Path $out 'src/GqlEx/GqlExClient.Generated.cs') -Raw
            $code | Should -Match 'GraphQLAsync<'
            # should NOT have generated a REST-style PostGraphqlAsync per individual entry
            $code | Should -Not -Match 'PostGraphqlAsync'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'partial-class-codegen' {
    It 'declares the generated class as partial' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $code = Get-Content (Join-Path $out 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
            $code | Should -Match 'partial\s+class\s+ExampleExClient'
            # And the hand-written Client.cs (template substituted) also declares partial
            $client = Get-Content (Join-Path $out 'src/ExampleEx/Client.cs') -Raw
            $client | Should -Match 'partial\s+class\s+ExampleExClient'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'mcp-descriptions' {
    It 'emits [Description] attributes on each generated method' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $code = Get-Content (Join-Path $out 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
            $code | Should -Match '\[Description\("[^"]+"\)\]'
            # mentions the path noun
            $code | Should -Match '\[Description\("[^"]*[Uu]sers[^"]*"\)\]'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'auto-generated header' {
    It 'has do-not-edit banner + source HAR sha-256' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $code = Get-Content (Join-Path $out 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
            $code | Should -Match '<auto-generated'
            $code | Should -Match 'do not edit'
            $code | Should -Match 'source HAR sha-256:\s*[0-9a-f]{64}'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'test-fixtures emitted' {
    It 'writes one JSON per detected endpoint into tests/fixtures/' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $fixDir = Join-Path $out 'tests/fixtures'
            Test-Path $fixDir | Should -BeTrue
            $files = Get-ChildItem $fixDir -Filter '*.json'
            $files.Count | Should -BeGreaterOrEqual 3
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'readme-recipes' {
    It 'emits a README.md with >=3 fenced csharp code blocks' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $readme = Get-Content (Join-Path $out 'README.md') -Raw
            $fences = [regex]::Matches($readme, '(?ms)^```csharp\b.*?^```')
            $fences.Count | Should -BeGreaterOrEqual 3
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'polite-crawl note' {
    It 'README contains rate-limit guidance' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $readme = Get-Content (Join-Path $out 'README.md') -Raw
            $readme | Should -Match '(?i)1\s*req(uest)?/sec|rate.?limit|robots\.txt'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'anti-bot challenge warning (issue #66)' {
    BeforeAll {
        function New-AkamaiHarFixture {
            param(
                [Parameter(Mandatory)][string] $Path,
                [switch] $IncludeAkamai
            )
            $reqHeaders = @(
                @{ name = 'Accept'; value = 'application/json' }
            )
            $respHeaders = @(
                @{ name = 'Content-Type'; value = 'application/json' }
            )
            if ($IncludeAkamai) {
                $reqHeaders += @{ name = 'Cookie'; value = '_abck=opaque; session_id=abc' }
                $respHeaders += @{ name = 'Set-Cookie'; value = 'bm_sz=opaque; Path=/; HttpOnly' }
            } else {
                $reqHeaders += @{ name = 'Cookie'; value = 'session_id=abc' }
                $respHeaders += @{ name = 'Set-Cookie'; value = 'session_id=abc; Path=/; HttpOnly' }
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
                                content     = @{ size = 2; mimeType = 'application/json'; text = '{}' }
                                redirectURL = ''
                                headersSize = -1
                                bodySize    = 2
                            }
                            cache    = @{}
                            timings  = @{ send = 0; wait = 1; receive = 0 }
                            time     = 1
                        }
                    )
                }
            }
            Set-Content -Encoding utf8 -LiteralPath $Path -Value ($har | ConvertTo-Json -Depth 12)
        }
    }

    It 'README includes an Anti-bot challenge warning section when Akamai cookies are present' {
        $out = New-OutDir
        $har = Join-Path ([IO.Path]::GetTempPath()) ("akamai-" + [guid]::NewGuid() + ".har")
        try {
            New-AkamaiHarFixture -Path $har -IncludeAkamai
            Invoke-Gen -Har @($har) -Out $out | Out-Null
            $readme = Get-Content (Join-Path $out 'README.md') -Raw
            $readme | Should -Match '(?i)Anti-bot challenge warning'
            $readme | Should -Match '_abck'
            $readme | Should -Match 'bm_sz'
            $readme | Should -Match '(?i)public landing page'
        } finally {
            if (Test-Path $out) { Remove-Item -Recurse -Force $out }
            if (Test-Path $har) { Remove-Item -Force $har }
        }
    }

    It 'README does NOT include the warning section when no Akamai cookies are present' {
        $out = New-OutDir
        $har = Join-Path ([IO.Path]::GetTempPath()) ("akamai-" + [guid]::NewGuid() + ".har")
        try {
            New-AkamaiHarFixture -Path $har
            Invoke-Gen -Har @($har) -Out $out | Out-Null
            $readme = Get-Content (Join-Path $out 'README.md') -Raw
            $readme | Should -Not -Match '(?i)Anti-bot challenge warning'
        } finally {
            if (Test-Path $out) { Remove-Item -Recurse -Force $out }
            if (Test-Path $har) { Remove-Item -Force $har }
        }
    }
}

Describe 'nuget-metadata' {
    It '.csproj contains required Package* elements' {
        $out = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $out | Out-Null
            $csproj = Get-Content (Join-Path $out 'src/ExampleEx/ExampleEx.csproj') -Raw
            $csproj | Should -Match '<PackageId>ExampleEx</PackageId>'
            $csproj | Should -Match '<Description>Example wrapper</Description>'
            $csproj | Should -Match '<Authors>IntelliTect</Authors>'
            $csproj | Should -Match '<RepositoryUrl>https://github\.com/example/example</RepositoryUrl>'
            $csproj | Should -Match '<PackageTags>example;api;wrapper</PackageTags>'
            $csproj | Should -Match '<TargetFramework>net8\.0</TargetFramework>'
        } finally { Remove-Item -Recurse -Force $out }
    }
}

Describe 'top-level solution file (issue #65)' {
    BeforeAll {
        $script:SlnOut = New-OutDir
        Invoke-Gen -Har @($script:RestHar) -Out $script:SlnOut | Out-Null
        $script:SlnxPath = Join-Path $script:SlnOut 'ExampleEx.slnx'
    }
    AfterAll {
        if (Test-Path $script:SlnOut) { Remove-Item -Recurse -Force $script:SlnOut }
    }
    It 'emits ExampleEx.slnx at the wrapper root' {
        Test-Path -LiteralPath $script:SlnxPath | Should -BeTrue
    }
    It 'references the client csproj' {
        $body = Get-Content -LiteralPath $script:SlnxPath -Raw
        $body | Should -Match 'src/ExampleEx/ExampleEx\.csproj'
    }
    It 'references the tests csproj' {
        $body = Get-Content -LiteralPath $script:SlnxPath -Raw
        $body | Should -Match 'tests/ExampleEx\.Tests/ExampleEx\.Tests\.csproj'
    }
    It 'uses POSIX-style forward slashes for cross-platform determinism' {
        $body = Get-Content -LiteralPath $script:SlnxPath -Raw
        $body | Should -Not -Match '\\'
    }
    It 'is wrapped in a <Solution> root element (slnx schema)' {
        $body = Get-Content -LiteralPath $script:SlnxPath -Raw
        $body | Should -Match '<Solution>'
        $body | Should -Match '</Solution>'
    }
}

Describe 'storage-state-flag (capture-cdp --validate-only)' {
    It 'exits 0 when storage-state file exists' {
        $tmpState = Join-Path ([IO.Path]::GetTempPath()) ("ss-" + [guid]::NewGuid() + ".json")
        Set-Content -LiteralPath $tmpState -Value '{"cookies":[],"origins":[]}' -Encoding utf8
        try {
            & node $script:CaptureJs --validate-only --storage-state $tmpState --url https://x --out x.har 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally { Remove-Item -LiteralPath $tmpState -ErrorAction SilentlyContinue }
    }
    It 'exits non-zero when storage-state file is missing' {
        $missing = Join-Path ([IO.Path]::GetTempPath()) ("ss-missing-" + [guid]::NewGuid() + ".json")
        & node $script:CaptureJs --validate-only --storage-state $missing --url https://x --out x.har 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'determinism' {
    It 'produces byte-identical output on repeat runs' {
        $a = New-OutDir; $b = New-OutDir
        try {
            Invoke-Gen -Har @($script:RestHar) -Out $a | Out-Null
            Invoke-Gen -Har @($script:RestHar) -Out $b | Out-Null
            $filesA = Get-ChildItem $a -Recurse -File | Sort-Object FullName
            $filesB = Get-ChildItem $b -Recurse -File | Sort-Object FullName
            $filesA.Count | Should -Be $filesB.Count
            for ($i = 0; $i -lt $filesA.Count; $i++) {
                $relA = $filesA[$i].FullName.Substring($a.Length)
                $relB = $filesB[$i].FullName.Substring($b.Length)
                $relA | Should -Be $relB
                $hashA = (Get-FileHash -Algorithm SHA256 $filesA[$i].FullName).Hash
                $hashB = (Get-FileHash -Algorithm SHA256 $filesB[$i].FullName).Hash
                $hashA | Should -Be $hashB
            }
        } finally {
            Remove-Item -Recurse -Force $a
            Remove-Item -Recurse -Force $b
        }
    }
}

Describe 'verb-passthrough (issue #100)' {
    BeforeAll {
        $script:PostHar = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/rest-post-and-get.har'
        $script:PostOut = New-OutDir
        $script:PostRes = Invoke-Gen -Har @($script:PostHar) -Out $script:PostOut
    }
    AfterAll {
        if (Test-Path $script:PostOut) { Remove-Item -Recurse -Force $script:PostOut }
    }

    It 'codegen exits 0 on the POST/GET fixture' {
        $script:PostRes.ExitCode | Should -Be 0 -Because $script:PostRes.Output
    }

    It 'generated POST endpoint passes HttpMethod.Post to SendRawAsync' {
        $code = Get-Content (Join-Path $script:PostOut 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
        $code | Should -Match 'CreateWidgetsCreateAsync'
        # The generated POST wrapper must thread the verb through to SendRawAsync.
        $code | Should -Match 'CreateWidgetsCreateAsync[\s\S]*?SendRawAsync\([^)]*HttpMethod\.Post'
    }

    It 'generated POST endpoint accepts an optional body parameter' {
        $code = Get-Content (Join-Path $script:PostOut 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
        $code | Should -Match 'CreateWidgetsCreateAsync\(\s*string\?\s+body\s*=\s*null'
    }

    It 'generated GET endpoint passes HttpMethod.Get to SendRawAsync' {
        $code = Get-Content (Join-Path $script:PostOut 'src/ExampleEx/ExampleExClient.Generated.cs') -Raw
        $code | Should -Match 'GetWidgetsListAsync[\s\S]*?SendRawAsync\([^)]*HttpMethod\.Get'
    }
}

Describe 'Client.cs.tmpl SendRawAsync verb support (issue #100)' {
    BeforeAll {
        $tmpl = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/csharp/Client.cs.tmpl'
        $script:ClientTmpl = Get-Content -Raw $tmpl
    }

    It 'SendRawAsync signature includes an HttpMethod parameter' {
        $script:ClientTmpl | Should -Match 'SendRawAsync\([\s\S]*?HttpMethod\??\s+method'
    }

    It 'SendRawAsync signature accepts an optional JSON body' {
        $script:ClientTmpl | Should -Match 'SendRawAsync\([\s\S]*?string\?\s+jsonBody'
    }

    It 'HttpRequestMessage uses the supplied method, not a hard-coded GET' {
        $script:ClientTmpl | Should -Not -Match 'new HttpRequestMessage\(HttpMethod\.Get,'
        $script:ClientTmpl | Should -Match 'new HttpRequestMessage\(method,'
    }
}
