#Requires -Version 7.0
#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0.0" }

# Behavior tests for the xUnit + Pester test scaffolds emitted by
# api-wrapper-scaffold codegen (issue #50). Builds on PR #49 (codegen pipeline).

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\") | Select-Object -ExpandProperty Path
    $script:ScriptsDir = Join-Path $script:RepoRoot "templates/api-wrapper-scaffold/scripts"
    $script:GenJs      = Join-Path $script:ScriptsDir "generate-wrapper.js"
    $script:TmplDir    = Join-Path $script:RepoRoot "templates/api-wrapper-scaffold/csharp/tests"
    $script:RestHar    = Join-Path $script:RepoRoot ".github/agents/tests/fixtures/har/rest-3endpoints.har"

    function New-OutDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("wrapgen-tests-" + [guid]::NewGuid())
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

Describe "tests-templates directory exists" {
    It "lives at the canonical path" {
        Test-Path -LiteralPath $script:TmplDir | Should -BeTrue
    }
    It "contains a manifest.json" {
        Test-Path -LiteralPath (Join-Path $script:TmplDir "manifest.json") | Should -BeTrue
    }
    It "declares the required .tmpl files" {
        $manifest = Get-Content -Raw (Join-Path $script:TmplDir "manifest.json") | ConvertFrom-Json
        $expected = @(
            "Tests.csproj.tmpl",
            "FixtureLoader.cs.tmpl",
            "ClientTests.cs.tmpl",
            "MockHandler.cs.tmpl",
            "pester/Mcp.Tests.ps1.tmpl",
            "pester/run-pester.ps1.tmpl"
        ) | Sort-Object
        $actual = @($manifest.templates | ForEach-Object { $_.file } | Sort-Object)
        ($actual -join ",") | Should -Be ($expected -join ",")
    }
}

Describe "Manifest body token parity" {
    It "every {{Token}} in a body is declared in the manifest entry" {
        $manifest = Get-Content -Raw (Join-Path $script:TmplDir "manifest.json") | ConvertFrom-Json
        foreach ($entry in $manifest.templates) {
            $path = Join-Path $script:TmplDir $entry.file
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

Describe "Token substitution leaves no markers" {
    It "every template substitutes cleanly with the canonical token map" {
        $tokens = @{
            ProjectName     = "ExampleEx"
            Namespace       = "Example"
            TestProjectName = "ExampleEx.Tests"
            Facts           = "    // (facts injected by generator)"
            ExpectedMethods = '        "GetExampleAsync"'
        }
        $manifest = Get-Content -Raw (Join-Path $script:TmplDir "manifest.json") | ConvertFrom-Json
        foreach ($entry in $manifest.templates) {
            $body = Get-Content -Raw (Join-Path $script:TmplDir $entry.file)
            $out = $body
            foreach ($k in $tokens.Keys) { $out = $out.Replace("{{$k}}", $tokens[$k]) }
            $out | Should -Not -Match "\{\{" -Because "$($entry.file) has unresolved tokens"
        }
    }
}

Describe "Codegen integration: emits test project" {
    BeforeAll {
        $script:Out = New-OutDir
        $script:ExitCode = Invoke-Gen -Har $script:RestHar -Out $script:Out
        $script:TestProjDir = Join-Path $script:Out "tests/ExampleEx.Tests"
    }
    AfterAll {
        if (Test-Path $script:Out) { Remove-Item -Recurse -Force $script:Out -ErrorAction SilentlyContinue }
    }
    It "generator exits 0" { $script:ExitCode | Should -Be 0 }
    It "emits the test project directory" {
        Test-Path $script:TestProjDir | Should -BeTrue
    }
    It "emits the test csproj" {
        Test-Path (Join-Path $script:TestProjDir "ExampleEx.Tests.csproj") | Should -BeTrue
    }
    It "emits FixtureLoader.cs and MockHandler.cs" {
        Test-Path (Join-Path $script:TestProjDir "FixtureLoader.cs") | Should -BeTrue
        Test-Path (Join-Path $script:TestProjDir "MockHandler.cs") | Should -BeTrue
    }
    It "emits at least one ClientTests.<Group>.cs" {
        $files = Get-ChildItem $script:TestProjDir -Filter "ClientTests.*.cs"
        $files.Count | Should -BeGreaterOrEqual 1
    }
    It "emits exactly one [Fact] per detected endpoint" {
        $clientCs = Get-Content (Join-Path $script:Out "src/ExampleEx/ExampleExClient.Generated.cs") -Raw
        $methodCount = ([regex]::Matches($clientCs, "public\s+async\s+Task<.*?>\s+\w+Async\s*\(")).Count
        $methodCount | Should -BeGreaterThan 0
        $factCount = 0
        Get-ChildItem $script:TestProjDir -Filter "ClientTests.*.cs" | ForEach-Object {
            $body = Get-Content $_.FullName -Raw
            $factCount += ([regex]::Matches($body, "\[Fact\]\s*[\r\n]+\s*public\s+async")).Count
        }
        $factCount | Should -Be $methodCount
    }
    It "test csproj references the wrapper project" {
        $csproj = Get-Content (Join-Path $script:TestProjDir "ExampleEx.Tests.csproj") -Raw
        $csproj | Should -Match "ProjectReference\s+Include=`"[^`"]*ExampleEx\.csproj"
    }
    It "test csproj pins NuGet versions for xunit + Moq + Test.Sdk" {
        $csproj = Get-Content (Join-Path $script:TestProjDir "ExampleEx.Tests.csproj") -Raw
        $csproj | Should -Match 'PackageReference\s+Include="Microsoft\.NET\.Test\.Sdk"\s+Version="\d'
        $csproj | Should -Match 'PackageReference\s+Include="xunit"\s+Version="\d'
        $csproj | Should -Match 'PackageReference\s+Include="xunit\.runner\.visualstudio"\s+Version="\d'
        $csproj | Should -Match 'PackageReference\s+Include="Moq"\s+Version="\d'
    }
    It "emits Pester scaffolds under tests/pester/" {
        Test-Path (Join-Path $script:TestProjDir "pester/Mcp.Tests.ps1") | Should -BeTrue
        Test-Path (Join-Path $script:TestProjDir "pester/run-pester.ps1") | Should -BeTrue
    }
    It "Mcp.Tests.ps1 references every generated method name" {
        $clientCs = Get-Content (Join-Path $script:Out "src/ExampleEx/ExampleExClient.Generated.cs") -Raw
        $methods = [regex]::Matches($clientCs, "public\s+async\s+Task<.*?>\s+(\w+Async)\s*\(") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $methods.Count | Should -BeGreaterThan 0
        $pester = Get-Content (Join-Path $script:TestProjDir "pester/Mcp.Tests.ps1") -Raw
        foreach ($m in $methods) {
            $pester | Should -Match ([regex]::Escape($m)) -Because "Mcp.Tests.ps1 must mention method $m"
        }
    }
}

Describe "Determinism (generated test project)" {
    It "two runs produce byte-identical test-project files" {
        $a = New-OutDir; $b = New-OutDir
        try {
            Invoke-Gen -Har $script:RestHar -Out $a | Out-Null
            Invoke-Gen -Har $script:RestHar -Out $b | Out-Null
            $aTests = Join-Path $a "tests/ExampleEx.Tests"
            $bTests = Join-Path $b "tests/ExampleEx.Tests"
            $filesA = Get-ChildItem $aTests -Recurse -File | Sort-Object FullName
            $filesB = Get-ChildItem $bTests -Recurse -File | Sort-Object FullName
            $filesA.Count | Should -Be $filesB.Count
            for ($i = 0; $i -lt $filesA.Count; $i++) {
                (Get-FileHash -Algorithm SHA256 $filesA[$i].FullName).Hash |
                    Should -Be (Get-FileHash -Algorithm SHA256 $filesB[$i].FullName).Hash
            }
        } finally {
            Remove-Item -Recurse -Force $a -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $b -ErrorAction SilentlyContinue
        }
    }
}

Describe "Buildable + runnable test project" {
    BeforeAll {
        $script:DotnetAvailable = $null -ne (Get-Command dotnet -ErrorAction SilentlyContinue)
        $script:Out = New-OutDir
        if ($script:DotnetAvailable) {
            Invoke-Gen -Har $script:RestHar -Out $script:Out | Out-Null
        }
    }
    AfterAll {
        if ($script:Out -and (Test-Path $script:Out)) {
            Remove-Item -Recurse -Force $script:Out -ErrorAction SilentlyContinue
        }
    }
    It "dotnet test on the generated test project succeeds" {
        if (-not $script:DotnetAvailable) {
            Set-ItResult -Skipped -Because "dotnet SDK not available"
            return
        }
        $testProj = Join-Path $script:Out "tests/ExampleEx.Tests"
        Push-Location $testProj
        try {
            $out = & dotnet test --nologo -v minimal 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "dotnet test must succeed. Output:`n$out"
        } finally {
            Pop-Location
        }
    }
}