# ----------------------------------------------------------------------------
# AIAgents bundle script tests (Pester v5).
#
# Two Describe blocks:
#   1. Install orchestration (Heavy,Bundle): verifies each agent gets a
#      `scoop install`, Playwright chromium is requested, and PoshMcp is
#      installed via `dotnet tool`. All package-manager calls are stubbed.
#   2. MCP config generation (Light,Bundle): redirects $env:USERPROFILE and
#      $env:APPDATA into a temp sandbox, stubs every install-side-effect, and
#      verifies the script writes the 5 expected MCP config files with the
#      expected mcpServers entries. Idempotency: dot-source twice and assert
#      no duplicate entries.
# ----------------------------------------------------------------------------

Describe 'AIAgents install orchestration' -Tag 'Heavy','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'AIAgents.ps1'

        # Sandbox config-file writes so the test never touches the real user
        # profile, even though this Describe is focused on install calls.
        $script:origUserProfile = $env:USERPROFILE
        $script:origAppData     = $env:APPDATA
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("AIAgents-orch-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        $env:USERPROFILE = $sandbox
        $env:APPDATA     = Join-Path $sandbox 'AppData'
        New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null

        $script:chocoCalls = @()
        $script:scoopCalls = @()
        $script:npxCalls   = @()
        $script:dotnetCalls = @()
        $script:ghCalls    = @()

        function choco     { $script:chocoCalls  += ,@($args); $global:LASTEXITCODE = 0 }
        function scoop     { $script:scoopCalls  += ,@($args); $global:LASTEXITCODE = 0 }
        function npx       { $script:npxCalls    += ,@($args); $global:LASTEXITCODE = 0 }
        function npx.cmd   { $script:npxCalls    += ,@($args); $global:LASTEXITCODE = 0 }
        function dotnet    { $script:dotnetCalls += ,@($args); $global:LASTEXITCODE = 0; '' }
        function gh        { $script:ghCalls     += ,@($args); $global:LASTEXITCODE = 0; 'fake-token' }
        # Install-BucketApp is defined in Utils.ps1 (which we strip below).
        # Stub it to route to the production fallback path so existing
        # `MarkMichaelis/<App>` scoop-call assertions still hold.
        function Install-BucketApp { param($Name) scoop install "MarkMichaelis/$Name" }

        # Bundle scripts dot-source Utils.ps1 which defines competing
        # `choco`/`scoop` wrappers; strip that line so our stubs win.
        $script:InvokeBundle = {
            $src = Get-Content -Raw -Path $script:sut
            $src = $src -replace '(?m)^\s*\.\s+"\$PSScriptRoot\\Utils\.ps1".*$',''
            . ([scriptblock]::Create($src)) @args
        }
        & $script:InvokeBundle
    }

    AfterAll {
        $env:USERPROFILE = $script:origUserProfile
        $env:APPDATA     = $script:origAppData
        if (Test-Path $script:sandbox) {
            Remove-Item -Path $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'invokes scoop install for each AI agent' {
        $names = $script:scoopCalls | ForEach-Object { $_[-1] }
        $expected = @(
            'MarkMichaelis/Claude','MarkMichaelis/ChatGPT','MarkMichaelis/Gemini',
            'MarkMichaelis/MicrosoftCopilot','MarkMichaelis/ClaudeCode',
            'MarkMichaelis/Codex','MarkMichaelis/GeminiCli','MarkMichaelis/GitHubCopilotCli'
        )
        foreach ($e in $expected) { $names | Should -Contain $e }
        $script:scoopCalls.Count | Should -BeGreaterOrEqual 8
    }

    It 'invokes npx to install Playwright chromium' {
        $matched = $script:npxCalls | Where-Object {
            ($_ -contains 'playwright') -and ($_ -contains 'chromium')
        }
        @($matched).Count | Should -BeGreaterOrEqual 1
    }

    It 'invokes dotnet tool install -g poshmcp' {
        $matched = $script:dotnetCalls | Where-Object {
            ($_ -contains 'tool') -and ($_ -contains 'install') -and ($_ -contains 'poshmcp')
        }
        @($matched).Count | Should -BeGreaterOrEqual 1
    }

    It 'is idempotent on re-run' {
        $script:scoopCalls  = @()
        $script:npxCalls    = @()
        $script:dotnetCalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:scoopCalls.Count  | Should -BeGreaterOrEqual 8
        $script:npxCalls.Count    | Should -BeGreaterOrEqual 1
        $script:dotnetCalls.Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'AIAgents MCP config generation' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'AIAgents.ps1'

        # Redirect HOME-equivalents so the script writes only into a temp dir.
        $script:origUserProfile = $env:USERPROFILE
        $script:origAppData     = $env:APPDATA
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("AIAgents-mcp-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        $env:USERPROFILE = $sandbox
        $env:APPDATA     = Join-Path $sandbox 'AppData'
        New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.codex') -Force | Out-Null

        # No-op every install side effect; let MCP-config helpers run for real.
        function choco   { $global:LASTEXITCODE = 0 }
        function scoop   { $global:LASTEXITCODE = 0 }
        function npx     { $global:LASTEXITCODE = 0 }
        function npx.cmd { $global:LASTEXITCODE = 0 }
        function dotnet  { $global:LASTEXITCODE = 0; '' }
        function gh      { $global:LASTEXITCODE = 0; 'fake-token' }
        function Install-BucketApp { param($Name) }

        $script:configPaths = @{
            ClaudeDesktop = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
            ClaudeCode    = Join-Path $env:USERPROFILE '.claude.json'
            Gemini        = Join-Path $env:USERPROFILE '.gemini\settings.json'
            Copilot       = Join-Path $env:USERPROFILE '.copilot\mcp-config.json'
            Codex         = Join-Path $env:USERPROFILE '.codex\config.toml'
        }

        $script:InvokeBundle = {
            $src = Get-Content -Raw -Path $script:sut
            $src = $src -replace '(?m)^\s*\.\s+"\$PSScriptRoot\\Utils\.ps1".*$',''
            . ([scriptblock]::Create($src)) @args
        }
        & $script:InvokeBundle
    }

    AfterAll {
        $env:USERPROFILE = $script:origUserProfile
        $env:APPDATA     = $script:origAppData
        if (Test-Path $script:sandbox) {
            Remove-Item -Path $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes all 5 expected MCP config files' {
        foreach ($p in $script:configPaths.Values) {
            Test-Path $p | Should -Be $true -Because "expected config file $p"
        }
    }

    It 'writes valid JSON with the 4 base mcpServers entries in <name>' -ForEach @(
        @{ name = 'ClaudeDesktop' }
        @{ name = 'ClaudeCode' }
        @{ name = 'Gemini' }
        @{ name = 'Copilot' }
    ) {
        $path = $script:configPaths[$name]
        $json = Get-Content -Raw -Path $path | ConvertFrom-Json
        $json.mcpServers | Should -Not -BeNullOrEmpty
        $json.mcpServers.context7        | Should -Not -BeNullOrEmpty
        $json.mcpServers.context7.command | Should -Be 'npx'
        $json.mcpServers.playwright      | Should -Not -BeNullOrEmpty
        $json.mcpServers.filesystem      | Should -Not -BeNullOrEmpty
        $json.mcpServers.github          | Should -Not -BeNullOrEmpty
    }

    It 'writes a Codex TOML config containing each MCP server section' {
        $path = $script:configPaths.Codex
        $content = Get-Content -Raw -Path $path
        $content | Should -Match '\[mcp_servers\.context7\]'
        $content | Should -Match '\[mcp_servers\.playwright\]'
        $content | Should -Match '\[mcp_servers\.filesystem\]'
        $content | Should -Match '\[mcp_servers\.github\]'
    }

    It 'is idempotent: re-running does not duplicate mcpServers entries' {
        { & $script:InvokeBundle } | Should -Not -Throw

        foreach ($name in 'ClaudeDesktop','ClaudeCode','Gemini','Copilot') {
            $path = $script:configPaths[$name]
            $json = Get-Content -Raw -Path $path | ConvertFrom-Json
            # Each named entry must appear exactly once.
            foreach ($expected in 'context7','playwright','filesystem','github') {
                @($json.mcpServers.PSObject.Properties.Name |
                    Where-Object { $_ -eq $expected }).Count |
                        Should -Be 1 -Because "$expected should appear exactly once in $path"
            }
        }

        $codex = Get-Content -Raw -Path $script:configPaths.Codex
        foreach ($expected in 'context7','playwright','filesystem','github') {
            $pattern = "\[mcp_servers\.$expected\]"
            ([regex]::Matches($codex, $pattern)).Count |
                Should -Be 1 -Because "[mcp_servers.$expected] should appear exactly once in codex config.toml"
        }
    }

    It '-Reset prunes deprecated shell entry but preserves user-added entries' {
        # Pre-seed each JSON config with a deprecated 'shell' entry plus a
        # user-added 'usercustom' entry that must survive.
        foreach ($name in 'ClaudeDesktop','ClaudeCode','Gemini','Copilot') {
            $path = $script:configPaths[$name]
            $json = Get-Content -Raw -Path $path | ConvertFrom-Json
            $json.mcpServers | Add-Member -NotePropertyName shell `
                -NotePropertyValue ([pscustomobject]@{ command = 'npx'; args = @('-y','mcp-server-commands') }) -Force
            $json.mcpServers | Add-Member -NotePropertyName usercustom `
                -NotePropertyValue ([pscustomobject]@{ command = 'echo'; args = @('hi') }) -Force
            $json | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding UTF8
        }
        $codexPath = $script:configPaths.Codex
        Add-Content -Path $codexPath -Value "`r`n[mcp_servers.shell]`r`ncommand = `"npx`"`r`nargs = [`"-y`", `"mcp-server-commands`"]`r`n"
        Add-Content -Path $codexPath -Value "`r`n[mcp_servers.usercustom]`r`ncommand = `"echo`"`r`nargs = [`"hi`"]`r`n"

        & $script:InvokeBundle -Reset

        foreach ($name in 'ClaudeDesktop','ClaudeCode','Gemini','Copilot') {
            $path = $script:configPaths[$name]
            $json = Get-Content -Raw -Path $path | ConvertFrom-Json
            $json.mcpServers.PSObject.Properties.Name | Should -Not -Contain 'shell' -Because "shell should be pruned from $path"
            $json.mcpServers.PSObject.Properties.Name | Should -Contain 'usercustom' -Because "user-added entries must survive in $path"
        }
        $codex = Get-Content -Raw -Path $codexPath
        $codex | Should -Not -Match '\[mcp_servers\.shell\]'
        $codex | Should     -Match '\[mcp_servers\.usercustom\]'
    }
}
