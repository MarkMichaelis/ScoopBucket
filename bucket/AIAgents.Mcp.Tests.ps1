#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for AIAgents.Mcp.ps1 helpers (issue #242).

.DESCRIPTION
    Each test asserts observable behavior (file contents, return
    values, env-scope writes) using a temp-directory fixture so the
    real user environment is never touched. Calls into
    [Environment]::SetEnvironmentVariable are routed through the
    Set-PersistedGitHubToken / Clear-PersistedGitHubToken helpers,
    which Pester mocks intercept.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'AIAgents.Mcp.ps1')

    function New-TempDir {
        $p = Join-Path ([System.IO.Path]::GetTempPath()) "scoopbucket-mcp-tests-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        return $p
    }

    $script:TempRoots = New-Object System.Collections.Generic.List[string]
}

AfterAll {
    foreach ($p in $script:TempRoots) {
        if ($p -and (Test-Path $p)) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'AIAgents.Mcp helpers' -Tag 'Light','Bundle' {

    Context 'Get-McpProfileSentinelBlock' {
        It 'emits the canonical start and end markers' {
            $block = Get-McpProfileSentinelBlock
            $block | Should -Match '# >>> ScoopBucket: GitHub PAT for MCP servers >>>'
            $block | Should -Match '# <<< ScoopBucket: GitHub PAT for MCP servers <<<'
        }

        It 'guards the gh call with `-not $env:GITHUB_PERSONAL_ACCESS_TOKEN`' {
            $block = Get-McpProfileSentinelBlock
            $block | Should -Match 'if \(-not \$env:GITHUB_PERSONAL_ACCESS_TOKEN'
        }

        It 'defines the Update-GitHubTokenFromGh helper' {
            $block = Get-McpProfileSentinelBlock
            $block | Should -Match 'function Update-GitHubTokenFromGh'
        }
    }

    Context 'Get-McpProfileTargets' {
        It 'returns AllUsersAllHosts only when -IsElevated' {
            $targets = @(Get-McpProfileTargets -IsElevated)
            @($targets).Count | Should -Be 1
            $targets[0] | Should -Be $PROFILE.AllUsersAllHosts
        }

        It 'returns CurrentUserAllHosts plus a WindowsPowerShell\profile.ps1 path when not elevated' {
            $targets = @(Get-McpProfileTargets)
            @($targets).Count | Should -Be 2
            $targets[0] | Should -Be $PROFILE.CurrentUserAllHosts
            $targets[1] | Should -Match 'Documents\\WindowsPowerShell\\profile\.ps1$'
        }
    }

    Context 'Add-McpProfileSentinel / Remove-McpProfileSentinel' {
        BeforeEach {
            $script:TmpDir = New-TempDir
            $script:TempRoots.Add($script:TmpDir)
            $script:ProfilePath = Join-Path $script:TmpDir 'profile.ps1'
        }

        It 'creates the profile file with the sentinel block when it does not exist' {
            $written = Add-McpProfileSentinel -Path $script:ProfilePath
            $written | Should -BeTrue
            (Test-Path $script:ProfilePath) | Should -BeTrue
            $content = Get-Content -Path $script:ProfilePath -Raw
            $content | Should -Match '# >>> ScoopBucket: GitHub PAT for MCP servers >>>'
            $content | Should -Match '# <<< ScoopBucket: GitHub PAT for MCP servers <<<'
        }

        It 'is idempotent: a second call does not duplicate the block' {
            Add-McpProfileSentinel -Path $script:ProfilePath | Out-Null
            $second = Add-McpProfileSentinel -Path $script:ProfilePath
            $second | Should -BeFalse
            $content = Get-Content -Path $script:ProfilePath -Raw
            ([regex]::Matches($content, [regex]::Escape('# >>> ScoopBucket: GitHub PAT for MCP servers >>>'))).Count | Should -Be 1
        }

        It 'preserves any pre-existing profile content' {
            Set-Content -Path $script:ProfilePath -Value "Set-Alias ll Get-ChildItem`r`n" -Encoding UTF8 -NoNewline
            Add-McpProfileSentinel -Path $script:ProfilePath | Out-Null
            $content = Get-Content -Path $script:ProfilePath -Raw
            $content | Should -Match 'Set-Alias ll Get-ChildItem'
            $content | Should -Match '# >>> ScoopBucket: GitHub PAT for MCP servers >>>'
        }

        It 'Remove strips the sentinel block while preserving surrounding content' {
            Set-Content -Path $script:ProfilePath -Value "Set-Alias ll Get-ChildItem`r`n" -Encoding UTF8 -NoNewline
            Add-McpProfileSentinel -Path $script:ProfilePath | Out-Null
            $removed = Remove-McpProfileSentinel -Path $script:ProfilePath
            $removed | Should -BeTrue
            (Test-Path $script:ProfilePath) | Should -BeTrue
            $content = Get-Content -Path $script:ProfilePath -Raw
            $content | Should -Match 'Set-Alias ll Get-ChildItem'
            $content | Should -Not -Match '# >>> ScoopBucket'
        }

        It 'Remove on a file with only the sentinel deletes the file' {
            Add-McpProfileSentinel -Path $script:ProfilePath | Out-Null
            Remove-McpProfileSentinel -Path $script:ProfilePath | Out-Null
            (Test-Path $script:ProfilePath) | Should -BeFalse
        }

        It 'Remove is a no-op when the file does not exist' {
            $missing = Join-Path $script:TmpDir 'absent.ps1'
            $result = Remove-McpProfileSentinel -Path $missing
            $result | Should -BeFalse
        }

        It 'Remove is a no-op when the sentinel marker is absent' {
            Set-Content -Path $script:ProfilePath -Value "Set-Alias ll Get-ChildItem`r`n" -Encoding UTF8 -NoNewline
            $result = Remove-McpProfileSentinel -Path $script:ProfilePath
            $result | Should -BeFalse
            $content = Get-Content -Path $script:ProfilePath -Raw
            $content | Should -Match 'Set-Alias ll Get-ChildItem'
        }
    }

    Context 'Set/Clear-PersistedGitHubToken (mocked SetEnvironmentVariable)' {
        BeforeEach {
            $script:CapturedSet = New-Object System.Collections.Generic.List[hashtable]
            Mock -CommandName 'Set-PersistedGitHubToken' -MockWith {
                param($Token, $IsElevated)
                $scope = if ($IsElevated) { 'Machine' } else { 'User' }
                $script:CapturedSet.Add(@{ Token = $Token; Scope = $scope; Cleared = $false })
            }
            Mock -CommandName 'Clear-PersistedGitHubToken' -MockWith {
                param($IsElevated)
                $scope = if ($IsElevated) { 'Machine' } else { 'User' }
                $script:CapturedSet.Add(@{ Token = $null; Scope = $scope; Cleared = $true })
            }
        }

        It 'Set writes at User scope by default' {
            Set-PersistedGitHubToken -Token 'gho_abc'
            $script:CapturedSet[0].Scope | Should -Be 'User'
            $script:CapturedSet[0].Token | Should -Be 'gho_abc'
        }

        It 'Set writes at Machine scope when -IsElevated' {
            Set-PersistedGitHubToken -Token 'gho_xyz' -IsElevated
            $script:CapturedSet[0].Scope | Should -Be 'Machine'
        }

        It 'Clear targets User scope by default' {
            Clear-PersistedGitHubToken
            $script:CapturedSet[0].Cleared | Should -BeTrue
            $script:CapturedSet[0].Scope   | Should -Be 'User'
        }

        It 'Clear targets Machine scope when -IsElevated' {
            Clear-PersistedGitHubToken -IsElevated
            $script:CapturedSet[0].Scope | Should -Be 'Machine'
        }
    }

    Context 'Get-NpmGlobalRoot' {
        It 'uses npm.cmd (not npm.ps1) so args are not mangled by the .ps1 shim (#249)' {
            # Repro for #249: on Windows where `npm` resolves to npm.ps1
            # (Scoop nodejs install), `& npm prefix -g` is dispatched
            # through the .ps1 shim as `npm pm -g` and fails with
            # "Unknown command: pm". Verify by placing an npm.cmd stub on
            # a temp PATH that echoes a known path, and asserting we
            # actually invoked it (not the broken default npm).
            $stubDir = New-TempDir
            $script:TempRoots.Add($stubDir)
            $expected = (Join-Path $stubDir 'global-root').Replace('\','/')
            New-Item -ItemType Directory -Path (Join-Path $stubDir 'global-root') | Out-Null

            # The .cmd stub: if invoked correctly with `prefix -g`, echo $expected.
            # If the .ps1 shim were invoked instead, it would never reach this.
            $stubCmd = Join-Path $stubDir 'npm.cmd'
            @"
@echo off
if "%1"=="prefix" if "%2"=="-g" (echo $($expected -replace '/','\') & exit /b 0)
echo unexpected: %*
exit /b 1
"@ | Set-Content -Path $stubCmd -Encoding ASCII

            $savedPath = $env:PATH
            try {
                $env:PATH = "$stubDir;$env:PATH"
                $result = Get-NpmGlobalRoot
                $result | Should -Be ($expected -replace '/','\')
            } finally {
                $env:PATH = $savedPath
            }
        }
    }

    Context 'Resolve-NpmBin' {
        BeforeEach {
            $script:TmpRoot = New-TempDir
            $script:TempRoots.Add($script:TmpRoot)
            $script:NodeModules = Join-Path $script:TmpRoot 'node_modules'
            New-Item -ItemType Directory -Path $script:NodeModules -Force | Out-Null
        }

        It 'resolves a string-form bin to a .cmd shim under the global root' {
            $pkgDir = Join-Path $script:NodeModules '@upstash\context7-mcp'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Set-Content -Path (Join-Path $pkgDir 'package.json') -Value '{"name":"@upstash/context7-mcp","bin":"./dist/index.js"}' -Encoding UTF8
            Set-Content -Path (Join-Path $script:TmpRoot 'context7-mcp.cmd') -Value '@echo off' -Encoding UTF8

            $bin = Resolve-NpmBin -PackageName '@upstash/context7-mcp' -NpmGlobalRoot $script:TmpRoot
            $bin | Should -Not -BeNullOrEmpty
            $bin | Should -Match 'context7-mcp\.cmd$'
        }

        It 'resolves an object-form bin to the first key.cmd' {
            $pkgDir = Join-Path $script:NodeModules '@modelcontextprotocol\server-github'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            $manifest = '{"name":"@modelcontextprotocol/server-github","bin":{"mcp-server-github":"./dist/index.js"}}'
            Set-Content -Path (Join-Path $pkgDir 'package.json') -Value $manifest -Encoding UTF8
            Set-Content -Path (Join-Path $script:TmpRoot 'mcp-server-github.cmd') -Value '@echo off' -Encoding UTF8

            $bin = Resolve-NpmBin -PackageName '@modelcontextprotocol/server-github' -NpmGlobalRoot $script:TmpRoot
            $bin | Should -Match 'mcp-server-github\.cmd$'
        }

        It 'returns $null when the package is not installed' {
            Resolve-NpmBin -PackageName 'no-such-pkg' -NpmGlobalRoot $script:TmpRoot | Should -Be $null
        }

        It 'returns $null when the bin shim file is missing' {
            $pkgDir = Join-Path $script:NodeModules 'some-pkg'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Set-Content -Path (Join-Path $pkgDir 'package.json') -Value '{"name":"some-pkg","bin":"./x.js"}' -Encoding UTF8
            # NOTE: no some-pkg.cmd shim created.
            Resolve-NpmBin -PackageName 'some-pkg' -NpmGlobalRoot $script:TmpRoot | Should -Be $null
        }
    }

    Context 'Resolve-McpServerCommand' {
        BeforeEach {
            $script:TmpRoot = New-TempDir
            $script:TempRoots.Add($script:TmpRoot)
            $script:NodeModules = Join-Path $script:TmpRoot 'node_modules'
            New-Item -ItemType Directory -Path $script:NodeModules -Force | Out-Null
        }

        It 'returns the resolved bin command with empty args when globally installed' {
            $pkgDir = Join-Path $script:NodeModules '@upstash\context7-mcp'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Set-Content -Path (Join-Path $pkgDir 'package.json') -Value '{"bin":"./i.js"}' -Encoding UTF8
            Set-Content -Path (Join-Path $script:TmpRoot 'context7-mcp.cmd') -Value '@echo off' -Encoding UTF8

            $r = Resolve-McpServerCommand -PackageName '@upstash/context7-mcp' -NpmGlobalRoot $script:TmpRoot
            $r.Command   | Should -Match 'context7-mcp\.cmd$'
            $r.Arguments | Should -Be @()
        }

        It 'falls back to npx -y <pkg> when bin resolution fails' {
            $r = Resolve-McpServerCommand -PackageName '@nope/missing' -NpmGlobalRoot $script:TmpRoot
            $r.Command   | Should -Be 'npx'
            $r.Arguments | Should -Be @('-y', '@nope/missing')
        }

        It 'appends ExtraArguments to the npx fallback args' {
            $r = Resolve-McpServerCommand -PackageName '@x/y' -NpmGlobalRoot $script:TmpRoot -ExtraArguments @('--root', 'C:\foo')
            $r.Command   | Should -Be 'npx'
            $r.Arguments | Should -Be @('-y', '@x/y', '--root', 'C:\foo')
        }

        It 'preserves ExtraArguments on the resolved-bin path' {
            $pkgDir = Join-Path $script:NodeModules '@modelcontextprotocol\server-filesystem'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Set-Content -Path (Join-Path $pkgDir 'package.json') -Value '{"bin":{"mcp-server-filesystem":"./i.js"}}' -Encoding UTF8
            Set-Content -Path (Join-Path $script:TmpRoot 'mcp-server-filesystem.cmd') -Value '@echo off' -Encoding UTF8

            $r = Resolve-McpServerCommand -PackageName '@modelcontextprotocol/server-filesystem' -NpmGlobalRoot $script:TmpRoot -ExtraArguments @('C:\Users\me')
            $r.Command   | Should -Match 'mcp-server-filesystem\.cmd$'
            $r.Arguments | Should -Be @('C:\Users\me')
        }
    }

    Context 'Add-McpServerToJsonConfig: env emission' {
        BeforeEach {
            $script:TmpDir = New-TempDir
            $script:TempRoots.Add($script:TmpDir)
            $script:JsonPath = Join-Path $script:TmpDir 'config.json'
        }

        It 'omits the env block when Server has no Env key' {
            $server = @{ Name = 'github'; Command = 'npx'; Arguments = @('-y','@modelcontextprotocol/server-github') }
            Add-McpServerToJsonConfig -Path $script:JsonPath -AgentLabel 'Test' -Server $server
            $cfg = Get-Content -Path $script:JsonPath -Raw | ConvertFrom-Json
            $cfg.mcpServers.github.command | Should -Be 'npx'
            $cfg.mcpServers.github.PSObject.Properties['env'] | Should -Be $null
        }

        It 'overwrites a pre-existing env block when re-run without Env (migration)' {
            $initial = @{
                mcpServers = @{
                    github = @{
                        command = 'npx'
                        args    = @('-y', '@modelcontextprotocol/server-github')
                        env     = @{ GITHUB_PERSONAL_ACCESS_TOKEN = 'leaked' }
                    }
                }
            }
            $initial | ConvertTo-Json -Depth 10 | Set-Content -Path $script:JsonPath -Encoding UTF8

            $server = @{ Name = 'github'; Command = 'npx'; Arguments = @('-y','@modelcontextprotocol/server-github') }
            Add-McpServerToJsonConfig -Path $script:JsonPath -AgentLabel 'Test' -Server $server

            $cfg = Get-Content -Path $script:JsonPath -Raw | ConvertFrom-Json
            $cfg.mcpServers.github.PSObject.Properties['env'] | Should -Be $null
            (Get-Content -Path $script:JsonPath -Raw) | Should -Not -Match 'leaked'
        }

        It 'still emits env when Server has a populated Env hashtable (other servers, sanity check)' {
            $server = @{
                Name = 'with-env'; Command = 'foo'; Arguments = @()
                Env  = @{ TOKEN = 'abc' }
            }
            Add-McpServerToJsonConfig -Path $script:JsonPath -AgentLabel 'Test' -Server $server
            $cfg = Get-Content -Path $script:JsonPath -Raw | ConvertFrom-Json
            $cfg.mcpServers.'with-env'.env.TOKEN | Should -Be 'abc'
        }
    }

    Context 'Add-McpServerToCodex: env emission' {
        BeforeEach {
            $script:TmpDir = New-TempDir
            $script:TempRoots.Add($script:TmpDir)
            $script:CodexPath = Join-Path $script:TmpDir 'config.toml'
        }

        It 'omits [mcp_servers.<name>.env] when Server has no Env key' {
            $server = @{ Name = 'github'; Command = 'npx'; Arguments = @('-y','@modelcontextprotocol/server-github') }
            Add-McpServerToCodex -Server $server -Path $script:CodexPath
            $content = Get-Content -Path $script:CodexPath -Raw
            $content | Should -Match '\[mcp_servers\.github\]'
            $content | Should -Not -Match '\[mcp_servers\.github\.env\]'
        }

        It 'strips an existing [mcp_servers.github.env] block on rewrite' {
            Set-Content -Path $script:CodexPath -Value @"
[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]

[mcp_servers.github.env]
GITHUB_PERSONAL_ACCESS_TOKEN = "leaked"
"@ -Encoding UTF8

            $server = @{ Name = 'github'; Command = 'npx'; Arguments = @('-y','@modelcontextprotocol/server-github') }
            Add-McpServerToCodex -Server $server -Path $script:CodexPath
            $content = Get-Content -Path $script:CodexPath -Raw
            $content | Should -Not -Match 'leaked'
            $content | Should -Not -Match '\[mcp_servers\.github\.env\]'
        }
    }
}
