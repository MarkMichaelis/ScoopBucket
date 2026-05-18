#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the api-wrapper-scaffold C# .tmpl files (issue #38).
# Covers token substitution, manifest contract, missing-token error reporting,
# and a real dotnet build of the substituted output.

BeforeAll {
    $script:RepoRoot     = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\") | Select-Object -ExpandProperty Path
    $script:CsharpDir    = Join-Path $script:RepoRoot "templates/api-wrapper-scaffold/csharp"
    $script:ManifestPath = Join-Path $script:CsharpDir "manifest.json"

    $script:Tokens = [ordered]@{
        ProjectName     = "ContosoEx"
        Namespace       = "Contoso"
        BaseUrl         = "https://contoso.example.com"
        AuthModel       = "cookie+csrf"
        IdpName         = "Google"
        IdpAuthorizeUrl = "https://accounts.google.com/o/oauth2/v2/auth"
        IdpTokenUrl     = "https://oauth2.googleapis.com/token"
        IdpClientId     = "contoso-client-id.apps.googleusercontent.com"
        IdpScopes       = "openid email profile"
        HasMobileCoverage = "true"
        MobileHarPaths    = "Samples/HAR-Original/mobile-android-20260101T000000Z.har"
    }

    function Expand-Template {
        param(
            [Parameter(Mandatory)][string]$Content,
            [Parameter(Mandatory)][System.Collections.IDictionary]$Tokens,
            [string[]]$Required = @()
        )
        $missing = @($Required | Where-Object { -not $Tokens.Contains($_) })
        if ($missing.Count -gt 0) {
            throw "Missing required token(s): $($missing -join ', ')"
        }
        $out = $Content
        foreach ($k in $Tokens.Keys) {
            $out = $out.Replace("{{$k}}", [string]$Tokens[$k])
        }
        return $out
    }

    function Get-Manifest {
        if (-not (Test-Path $script:ManifestPath)) {
            throw "Manifest not found at $script:ManifestPath"
        }
        return Get-Content -Raw $script:ManifestPath | ConvertFrom-Json
    }
}

Describe "C# template manifest" {
    It "exists and lists every .tmpl file in the csharp directory" {
        Test-Path $script:ManifestPath | Should -BeTrue
        $manifest = Get-Manifest
        $declared = @($manifest.templates | ForEach-Object { $_.file } | Sort-Object) -join ','
        $actual = @(Get-ChildItem $script:CsharpDir -Filter "*.tmpl" | ForEach-Object { $_.Name } | Sort-Object) -join ','
        $declared | Should -Be $actual
    }

    It "declares the required templates" {
        $manifest = Get-Manifest
        $expected = @(
            "Client.cs.tmpl",
            "Authenticator.cs.tmpl",
            "ISessionStore.cs.tmpl",
            "DpapiSessionStore.cs.tmpl",
            "UserSecretsSessionStore.cs.tmpl",
            "McpProgram.cs.tmpl",
            "OAuthPkceAuthenticator.cs.tmpl",
            "CrossPlatformSessionStore.cs.tmpl",
            "README.SSO.md.tmpl",
            "README.MobileDiscovery.md.tmpl",
            ".gitignore.tmpl"
        ) | Sort-Object
        $actual = @($manifest.templates | ForEach-Object { $_.file } | Sort-Object)
        ($actual -join ',') | Should -Be ($expected -join ',')
    }
}

Describe "Per-template token contract" {
    BeforeAll {
        $script:Manifest = Get-Manifest
    }

    It "<file> declares every token appearing in its body and vice versa" -ForEach @(
        @{ file = "Client.cs.tmpl" }
        @{ file = "Authenticator.cs.tmpl" }
        @{ file = "ISessionStore.cs.tmpl" }
        @{ file = "DpapiSessionStore.cs.tmpl" }
        @{ file = "UserSecretsSessionStore.cs.tmpl" }
        @{ file = "McpProgram.cs.tmpl" }
    ) {
        $entry = $script:Manifest.templates | Where-Object { $_.file -eq $file }
        $entry | Should -Not -BeNullOrEmpty -Because "manifest must list $file"
        $path = Join-Path $script:CsharpDir $file
        $body = Get-Content -Raw $path
        $found = @([regex]::Matches($body, "\{\{([A-Za-z]+)\}\}") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
        $declared = @($entry.requiredTokens | Sort-Object -Unique) -join ','
        $found | Should -Be $declared -Because "tokens-in-body must match manifest for $file"
    }
}

Describe "Token substitution" {
    It "leaves no token markers in any template after applying the canonical token map" {
        $manifest = Get-Manifest
        foreach ($entry in $manifest.templates) {
            $body = Get-Content -Raw (Join-Path $script:CsharpDir $entry.file)
            $expanded = Expand-Template -Content $body -Tokens $script:Tokens -Required $entry.requiredTokens
            $expanded | Should -Not -Match "\{\{" -Because "$($entry.file) should contain no token markers after expansion"
        }
    }

    It "throws a clear error when a required token is missing" {
        $entry = (Get-Manifest).templates | Where-Object { $_.requiredTokens.Count -gt 0 } | Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty
        $body = Get-Content -Raw (Join-Path $script:CsharpDir $entry.file)
        $partial = @{}
        { Expand-Template -Content $body -Tokens $partial -Required $entry.requiredTokens } |
            Should -Throw -ExpectedMessage "*Missing required token*"
    }
}

Describe "Authenticator.cs.tmpl uses Microsoft.Playwright (issue #97)" {
    BeforeAll {
        $script:AuthBody = Get-Content -Raw (Join-Path $script:CsharpDir "Authenticator.cs.tmpl")
    }

    It "does NOT contain a credential-form-post login path" {
        $script:AuthBody | Should -Not -Match "TryCliLoginAsync" -Because "wrapper must never accept the user's password"
        $script:AuthBody | Should -Not -Match "LoginChallengeException" -Because "the credential-flow exception is no longer needed"
        $script:AuthBody | Should -Not -Match "userName" -Because "no username parameter belongs in the Authenticator surface"
        $script:AuthBody | Should -Not -Match "password" -Because "no password parameter belongs in the Authenticator surface"
        $script:AuthBody | Should -Not -Match '/login' -Because "wrappers must not POST credentials to {BaseUrl}/login"
    }

    It "does NOT shell out to node + capture-cdp.js for runtime auth" {
        $script:AuthBody | Should -Not -Match 'capture-cdp\.js' -Because "runtime auth must use Microsoft.Playwright directly, not the HAR-capture node script"
        $script:AuthBody | Should -Not -Match 'Process\.Start' -Because "no node subprocess for runtime auth"
        $script:AuthBody | Should -Not -Match 'ProcessStartInfo' -Because "no node subprocess for runtime auth"
    }

    It "uses Microsoft.Playwright directly from C#" {
        $script:AuthBody | Should -Match 'using Microsoft\.Playwright;'
        $script:AuthBody | Should -Match 'IPlaywright|Playwright\.CreateAsync'
        $script:AuthBody | Should -Match 'Chromium\.LaunchAsync'
        $script:AuthBody | Should -Match 'CookiesAsync' -Because "session credentials are extracted from the live browser context"
    }

    It "uses Channel = `"chrome`" to reuse the user's installed browser" {
        $script:AuthBody | Should -Match 'Channel\s*=\s*"chrome"' -Because "matches the CodiwomplerSocialMedia reference pattern and avoids the 150MB Chromium download"
    }
}

Describe "Generated csproj declares Microsoft.Playwright (issue #97)" {
    It "generate-wrapper.js emitCsproj output includes Microsoft.Playwright PackageReference" {
        $generator = Get-Content -Raw (Join-Path $script:RepoRoot "templates/api-wrapper-scaffold/scripts/generate-wrapper.js")
        $generator | Should -Match 'Microsoft\.Playwright' -Because "the generated client csproj must reference Microsoft.Playwright so the Authenticator compiles"
    }
}

Describe "Buildable output" {
    BeforeAll {
        $script:DotnetAvailable = $null -ne (Get-Command dotnet -ErrorAction SilentlyContinue)
        $script:BuildDir = Join-Path ([System.IO.Path]::GetTempPath()) "ContosoEx-build-$([System.Guid]::NewGuid().ToString('N'))"
    }

    AfterAll {
        if ($script:BuildDir -and (Test-Path $script:BuildDir)) {
            Remove-Item -Recurse -Force $script:BuildDir -ErrorAction SilentlyContinue
        }
    }

    It "substituted Client + Authenticator + SessionStore templates compile via dotnet build" {
        if (-not $script:DotnetAvailable) {
            Set-ItResult -Skipped -Because "dotnet SDK not available on this host"
            return
        }
        $manifest = Get-Manifest
        New-Item -ItemType Directory -Force -Path $script:BuildDir | Out-Null
        $authDir = Join-Path $script:BuildDir "Auth"
        New-Item -ItemType Directory -Force -Path $authDir | Out-Null

        $emitMap = [ordered]@{
            "Client.cs.tmpl"                  = (Join-Path $script:BuildDir "ContosoExClient.cs")
            "Authenticator.cs.tmpl"           = (Join-Path $authDir "ContosoExAuthenticator.cs")
            "ISessionStore.cs.tmpl"           = (Join-Path $authDir "ISessionStore.cs")
            "DpapiSessionStore.cs.tmpl"       = (Join-Path $authDir "DpapiSessionStore.cs")
            "UserSecretsSessionStore.cs.tmpl" = (Join-Path $authDir "UserSecretsSessionStore.cs")
        }

        foreach ($kv in $emitMap.GetEnumerator()) {
            $entry = $manifest.templates | Where-Object { $_.file -eq $kv.Key }
            $body = Get-Content -Raw (Join-Path $script:CsharpDir $kv.Key)
            $expanded = Expand-Template -Content $body -Tokens $script:Tokens -Required $entry.requiredTokens
            Set-Content -LiteralPath $kv.Value -Value $expanded -NoNewline
        }

        $csproj = "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <PropertyGroup>`n    <TargetFramework>net8.0</TargetFramework>`n    <Nullable>enable</Nullable>`n    <ImplicitUsings>enable</ImplicitUsings>`n    <RootNamespace>Contoso</RootNamespace>`n    <AssemblyName>Contoso</AssemblyName>`n  </PropertyGroup>`n  <ItemGroup>`n    <PackageReference Include=`"Microsoft.Extensions.Logging.Abstractions`" Version=`"8.0.0`" />`n    <PackageReference Include=`"Microsoft.Playwright`" Version=`"1.49.0`" />`n    <PackageReference Include=`"System.Security.Cryptography.ProtectedData`" Version=`"8.0.0`" />`n  </ItemGroup>`n</Project>`n"
        Set-Content -LiteralPath (Join-Path $script:BuildDir "Contoso.csproj") -Value $csproj -NoNewline

        Push-Location $script:BuildDir
        try {
            $buildOut = & dotnet build --nologo -v minimal 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "dotnet build must succeed. Output:`n$buildOut"
        } finally {
            Pop-Location
        }
    }
}
