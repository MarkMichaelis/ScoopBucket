#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the OAuth PKCE / cross-platform-store / SSO-doc templates (issue #42).
# Mirrors the structure of csharp-templates.Tests.ps1 (issue #38).

BeforeAll {
    $script:RepoRoot     = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\") | Select-Object -ExpandProperty Path
    $script:CsharpDir    = Join-Path $script:RepoRoot "templates/api-wrapper-scaffold/csharp"
    $script:ManifestPath = Join-Path $script:CsharpDir "manifest.json"

    $script:Tokens = [ordered]@{
        ProjectName       = "ContosoEx"
        Namespace         = "Contoso"
        BaseUrl           = "https://contoso.example.com"
        AuthModel         = "oauth2-pkce"
        IdpName           = "Google"
        IdpAuthorizeUrl   = "https://accounts.google.com/o/oauth2/v2/auth"
        IdpTokenUrl       = "https://oauth2.googleapis.com/token"
        IdpClientId       = "contoso-client-id.apps.googleusercontent.com"
        IdpScopes         = "openid email profile"
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
        return Get-Content -Raw $script:ManifestPath | ConvertFrom-Json
    }
}

Describe "OAuth/SSO manifest extensions" {
    It "declares the new OAuth-related tokens" {
        $manifest = Get-Manifest
        $names = $manifest.tokens.PSObject.Properties.Name
        foreach ($t in 'IdpAuthorizeUrl','IdpTokenUrl','IdpClientId','IdpScopes') {
            $names | Should -Contain $t -Because "manifest.tokens must declare $t"
        }
    }

    It "lists the three new template files" {
        $files = (Get-Manifest).templates | ForEach-Object { $_.file }
        $files | Should -Contain 'OAuthPkceAuthenticator.cs.tmpl'
        $files | Should -Contain 'CrossPlatformSessionStore.cs.tmpl'
        $files | Should -Contain 'README.SSO.md.tmpl'
    }
}

Describe "OAuth/SSO template token contract" {
    It "<file> declares every {{Token}} appearing in its body and vice versa" -ForEach @(
        @{ file = "OAuthPkceAuthenticator.cs.tmpl" }
        @{ file = "CrossPlatformSessionStore.cs.tmpl" }
        @{ file = "README.SSO.md.tmpl" }
    ) {
        $manifest = Get-Manifest
        $entry = $manifest.templates | Where-Object { $_.file -eq $file }
        $entry | Should -Not -BeNullOrEmpty -Because "manifest must list $file"
        $path = Join-Path $script:CsharpDir $file
        Test-Path $path | Should -BeTrue -Because "$file must exist on disk"
        $body = Get-Content -Raw $path
        $found = @([regex]::Matches($body, "\{\{([A-Za-z]+)\}\}") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
        $declared = @($entry.requiredTokens | Sort-Object -Unique) -join ','
        $found | Should -Be $declared -Because "tokens-in-body must match manifest for $file"
    }
}

Describe "OAuth/SSO token substitution" {
    It "<file> contains no token markers after applying the canonical token map" -ForEach @(
        @{ file = "OAuthPkceAuthenticator.cs.tmpl" }
        @{ file = "CrossPlatformSessionStore.cs.tmpl" }
        @{ file = "README.SSO.md.tmpl" }
    ) {
        $manifest = Get-Manifest
        $entry = $manifest.templates | Where-Object { $_.file -eq $file }
        $body = Get-Content -Raw (Join-Path $script:CsharpDir $file)
        $expanded = Expand-Template -Content $body -Tokens $script:Tokens -Required $entry.requiredTokens
        $expanded | Should -Not -Match "\{\{" -Because "$file should contain no token markers after expansion"
    }

    It "OAuthPkceAuthenticator substitutes class name to {{ProjectName}}OAuthAuthenticator" {
        $body = Get-Content -Raw (Join-Path $script:CsharpDir "OAuthPkceAuthenticator.cs.tmpl")
        $expanded = $body.Replace("{{ProjectName}}", "Contoso").Replace("{{Namespace}}", "Contoso").Replace("{{IdpName}}", "Google").Replace("{{IdpAuthorizeUrl}}", "x").Replace("{{IdpTokenUrl}}", "x").Replace("{{IdpClientId}}", "x").Replace("{{IdpScopes}}", "x")
        $expanded | Should -Match "class ContosoOAuthAuthenticator"
    }

    It "README.SSO.md.tmpl mentions the loopback redirect URI convention" {
        $body = Get-Content -Raw (Join-Path $script:CsharpDir "README.SSO.md.tmpl")
        $expanded = Expand-Template -Content $body -Tokens $script:Tokens -Required @('IdpName')
        $expanded | Should -Match "http://localhost"
        $expanded | Should -Match "Google"
    }
}

Describe "OAuth buildable output" {
    BeforeAll {
        $script:DotnetAvailable = $null -ne (Get-Command dotnet -ErrorAction SilentlyContinue)
        $script:BuildDir = Join-Path ([System.IO.Path]::GetTempPath()) "ContosoOAuth-build-$([System.Guid]::NewGuid().ToString('N'))"
    }

    AfterAll {
        if ($script:BuildDir -and (Test-Path $script:BuildDir)) {
            Remove-Item -Recurse -Force $script:BuildDir -ErrorAction SilentlyContinue
        }
    }

    It "OAuthPkceAuthenticator + ISessionStore + DPAPI + UserSecrets + CrossPlatformSessionStore compile via dotnet build" {
        if (-not $script:DotnetAvailable) {
            Set-ItResult -Skipped -Because "dotnet SDK not available on this host"
            return
        }
        $manifest = Get-Manifest
        New-Item -ItemType Directory -Force -Path $script:BuildDir | Out-Null
        $authDir = Join-Path $script:BuildDir "Auth"
        New-Item -ItemType Directory -Force -Path $authDir | Out-Null

        $emitMap = [ordered]@{
            "ISessionStore.cs.tmpl"             = (Join-Path $authDir "ISessionStore.cs")
            "DpapiSessionStore.cs.tmpl"         = (Join-Path $authDir "DpapiSessionStore.cs")
            "UserSecretsSessionStore.cs.tmpl"   = (Join-Path $authDir "UserSecretsSessionStore.cs")
            "OAuthPkceAuthenticator.cs.tmpl"    = (Join-Path $authDir "ContosoExOAuthAuthenticator.cs")
            "CrossPlatformSessionStore.cs.tmpl" = (Join-Path $authDir "CrossPlatformSessionStore.cs")
        }

        foreach ($kv in $emitMap.GetEnumerator()) {
            $entry = $manifest.templates | Where-Object { $_.file -eq $kv.Key }
            $body = Get-Content -Raw (Join-Path $script:CsharpDir $kv.Key)
            $expanded = Expand-Template -Content $body -Tokens $script:Tokens -Required $entry.requiredTokens
            Set-Content -LiteralPath $kv.Value -Value $expanded -NoNewline
        }

        $csproj = "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <PropertyGroup>`n    <TargetFramework>net8.0</TargetFramework>`n    <Nullable>enable</Nullable>`n    <ImplicitUsings>enable</ImplicitUsings>`n    <RootNamespace>Contoso</RootNamespace>`n    <AssemblyName>Contoso</AssemblyName>`n  </PropertyGroup>`n  <ItemGroup>`n    <PackageReference Include=`"Microsoft.Extensions.Logging.Abstractions`" Version=`"8.0.0`" />`n    <PackageReference Include=`"System.Security.Cryptography.ProtectedData`" Version=`"8.0.0`" />`n  </ItemGroup>`n</Project>`n"
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
