#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for the optional SDLC integration stage (issue #56).
# Covers:
#   - module API: parseSdlcFlags, discoverSdlcScript, sdlcIntegrationReadmeSection
#   - run-agent.js wiring: flags, transcript, marker file
#   - generate-wrapper.js README section

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:Runner   = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts/run-agent.js'
    $script:Module   = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold/scripts/sdlc-integration.js'
    $script:RestHar  = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/har/e2e-rest.har'
    $script:Stub     = Join-Path $script:RepoRoot '.github/agents/tests/fixtures/sdlc-stub/Pull-SDLC.ai.ps1'
    $script:StubDir  = Split-Path -Parent $script:Stub

    function New-TmpDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("sdlc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $d | Out-Null
        return $d
    }

    function Invoke-Node {
        param([string[]]$NodeArgs, [hashtable]$EnvOverride = @{})
        $stash = @{}
        foreach ($k in $EnvOverride.Keys) {
            $stash[$k] = [System.Environment]::GetEnvironmentVariable($k)
            [System.Environment]::SetEnvironmentVariable($k, $EnvOverride[$k])
        }
        try {
            $out = & node @NodeArgs 2>&1
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out -join "`n") }
        } finally {
            foreach ($k in $stash.Keys) {
                [System.Environment]::SetEnvironmentVariable($k, $stash[$k])
            }
        }
    }

    # Helper: invoke the module via a small Node harness and parse JSON result.
    function Invoke-Module {
        param([string]$JsBody, [hashtable]$EnvOverride = @{})
        $r = Invoke-Node -NodeArgs @('-e', $JsBody) -EnvOverride $EnvOverride
        return $r
    }
}

Describe 'sdlc-integration module exists' {
    It 'file is present' { Test-Path -LiteralPath $script:Module | Should -BeTrue }
    It 'parses without syntax errors' {
        & node --check $script:Module 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'parseSdlcFlags' {
    It '--sdlc-yes alone -> mode=yes' {
        $js = "const m=require(process.argv[1]);console.log(JSON.stringify(m.parseSdlcFlags({'sdlc-yes':true},true)));"
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        $r.Exit | Should -Be 0
        ($r.Output | ConvertFrom-Json).mode | Should -Be 'yes'
    }
    It '--no-sdlc alone -> mode=no' {
        $js = "const m=require(process.argv[1]);console.log(JSON.stringify(m.parseSdlcFlags({'no-sdlc':true},true)));"
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        ($r.Output | ConvertFrom-Json).mode | Should -Be 'no'
    }
    It 'both flags -> error' {
        $js = "const m=require(process.argv[1]);console.log(JSON.stringify(m.parseSdlcFlags({'sdlc-yes':true,'no-sdlc':true},true)));"
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        $parsed = $r.Output | ConvertFrom-Json
        $parsed.error | Should -Not -BeNullOrEmpty
        $parsed.error | Should -Match 'mutually exclusive'
    }
    It 'neither + TTY -> mode=prompt' {
        $js = "const m=require(process.argv[1]);console.log(JSON.stringify(m.parseSdlcFlags({},true)));"
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        ($r.Output | ConvertFrom-Json).mode | Should -Be 'prompt'
    }
    It 'neither + !TTY -> mode=no with reason "non-interactive default"' {
        $js = "const m=require(process.argv[1]);console.log(JSON.stringify(m.parseSdlcFlags({},false)));"
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        $parsed = $r.Output | ConvertFrom-Json
        $parsed.mode | Should -Be 'no'
        $parsed.reason | Should -Match 'non-interactive'
    }
}

Describe 'discoverSdlcScript' {
    It 'explicit argScript wins (even if file missing)' {
        $js = @"
const m=require(process.argv[1]);
const r=m.discoverSdlcScript({argScript:'C:/nope/Pull-SDLC.ai.ps1',env:{},scaffoldRepoRoot:'C:/'});
console.log(JSON.stringify(r));
"@
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        $parsed = $r.Output | ConvertFrom-Json
        $parsed.source | Should -Be 'arg'
        $parsed.exists | Should -Be $false
    }
    It 'env var fallback resolves to file inside dir' {
        $stubDirJs = $script:StubDir -replace '\\','/'
        $js = @"
const m=require(process.argv[1]);
const r=m.discoverSdlcScript({argScript:null,env:{IntelliSDLC_AI_PATH:'$stubDirJs'},scaffoldRepoRoot:'C:/nope'});
console.log(JSON.stringify(r));
"@
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        $parsed = $r.Output | ConvertFrom-Json
        $parsed.source | Should -Be 'env'
        $parsed.exists | Should -Be $true
        $parsed.path | Should -Match 'Pull-SDLC\.ai\.ps1$'
    }
    It 'returns null when nothing found' {
        $js = @"
const m=require(process.argv[1]);
const r=m.discoverSdlcScript({argScript:null,env:{},scaffoldRepoRoot:'C:/definitely-not-a-thing-xyzzy'});
console.log(JSON.stringify(r));
"@
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        $r.Output.Trim() | Should -Be 'null'
    }
}

Describe 'sdlcIntegrationReadmeSection' {
    It 'returns a markdown block with the SDLC Integration heading and one-liner' {
        $js = "const m=require(process.argv[1]);process.stdout.write(m.sdlcIntegrationReadmeSection());"
        $r = Invoke-Node -NodeArgs @('-e', $js, $script:Module)
        $r.Exit | Should -Be 0
        $r.Output | Should -Match '## SDLC Integration'
        $r.Output | Should -Match 'Pull-SDLC\.ai\.ps1'
        $r.Output | Should -Match 'IntelliSDLC\.ai'
        $r.Output | Should -Match 'project\.instructions\.md'
    }
}

Describe 'run-agent.js -- mutually exclusive flags' {
    It '--sdlc-yes + --no-sdlc -> exit 2 with clear error' {
        $out = New-TmpDir
        try {
            $r = & node $script:Runner --har $script:RestHar --out $out --project P --namespace P --sdlc-yes --no-sdlc 2>&1
            $LASTEXITCODE | Should -Be 2
            ($r -join "`n") | Should -Match 'mutually exclusive'
        } finally { Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue }
    }
}

Describe 'run-agent.js -- --no-sdlc (explicit opt-out)' {
    BeforeAll {
        $script:OutNo = New-TmpDir
        $script:NoOutput = & node $script:Runner --har $script:RestHar --out $script:OutNo --project P --namespace P --base-url https://app.example.com --no-sdlc 2>&1
        $script:NoExit = $LASTEXITCODE
        $script:NoJoined = ($script:NoOutput -join "`n")
    }
    AfterAll {
        if ($script:OutNo -and (Test-Path $script:OutNo)) {
            Remove-Item -Recurse -Force $script:OutNo -ErrorAction SilentlyContinue
        }
    }
    It 'exits 0' { $script:NoExit | Should -Be 0 }
    It 'prints sdlc-integration stage banner' {
        $script:NoJoined | Should -Match '==> Stage:\s*sdlc-integration'
    }
    It 'does NOT create the stub marker (script not invoked)' {
        Test-Path (Join-Path $script:OutNo '.sdlc-pulled.marker') | Should -BeFalse
    }
    It 'transcript records "skipped: --no-sdlc"' {
        $log = Get-Content (Join-Path $script:OutNo '.run-agent/transcript.log') -Raw
        $log | Should -Match 'sdlc-integration:\s*skipped:\s*--no-sdlc'
    }
    It 'generated README contains "## SDLC Integration"' {
        $readme = Get-Content (Join-Path $script:OutNo 'README.md') -Raw
        $readme | Should -Match '## SDLC Integration'
        $readme | Should -Match 'Pull-SDLC\.ai\.ps1'
    }
}

Describe 'run-agent.js -- --sdlc-yes with env-var-discovered stub script' {
    BeforeAll {
        $script:OutYes = New-TmpDir
        $stash = [System.Environment]::GetEnvironmentVariable('IntelliSDLC_AI_PATH')
        try {
            [System.Environment]::SetEnvironmentVariable('IntelliSDLC_AI_PATH', $script:StubDir)
            $script:YesOutput = & node $script:Runner --har $script:RestHar --out $script:OutYes --project P --namespace P --base-url https://app.example.com --sdlc-yes 2>&1
            $script:YesExit = $LASTEXITCODE
        } finally {
            [System.Environment]::SetEnvironmentVariable('IntelliSDLC_AI_PATH', $stash)
        }
        $script:YesJoined = ($script:YesOutput -join "`n")
    }
    AfterAll {
        if ($script:OutYes -and (Test-Path $script:OutYes)) {
            Remove-Item -Recurse -Force $script:OutYes -ErrorAction SilentlyContinue
        }
    }
    It 'exits 0' { $script:YesExit | Should -Be 0 -Because $script:YesJoined }
    It 'stub script ran with cwd=outDir (marker file present)' {
        Test-Path (Join-Path $script:OutYes '.sdlc-pulled.marker') | Should -BeTrue
    }
    It 'transcript records "completed"' {
        $log = Get-Content (Join-Path $script:OutYes '.run-agent/transcript.log') -Raw
        $log | Should -Match 'sdlc-integration:\s*completed'
    }
}

Describe 'run-agent.js -- --sdlc-yes but no script found' {
    It 'prints manual-run instructions, exits 0, transcript "skipped: not found"' {
        $out = New-TmpDir
        $stash = [System.Environment]::GetEnvironmentVariable('IntelliSDLC_AI_PATH')
        try {
            [System.Environment]::SetEnvironmentVariable('IntelliSDLC_AI_PATH', '')
            $missing = Join-Path ([IO.Path]::GetTempPath()) ("nope-" + [guid]::NewGuid() + "/Pull-SDLC.ai.ps1")
            $r = & node $script:Runner --har $script:RestHar --out $out --project P --namespace P --base-url https://app.example.com --sdlc-yes --sdlc-script $missing 2>&1
            $LASTEXITCODE | Should -Be 0
            $joined = ($r -join "`n")
            $joined | Should -Match 'git clone https://github\.com/IntelliTect-Samples/IntelliSDLC\.ai'
            $log = Get-Content (Join-Path $out '.run-agent/transcript.log') -Raw
            $log | Should -Match 'sdlc-integration:\s*skipped:\s*not found'
        } finally {
            [System.Environment]::SetEnvironmentVariable('IntelliSDLC_AI_PATH', $stash)
            Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
        }
    }
}

Describe 'run-agent.js -- non-interactive default (no flag)' {
    It 'is a no-op: prints manual instructions, transcript "skipped: non-interactive default"' {
        $out = New-TmpDir
        try {
            # Force non-TTY stdin so we exercise the unattended-default path
            # regardless of how Pester itself was invoked. Pipe $null into node.
            $r = $null | & node $script:Runner --har $script:RestHar --out $out --project P --namespace P --base-url https://app.example.com 2>&1
            $LASTEXITCODE | Should -Be 0
            $joined = ($r -join "`n")
            $joined | Should -Match 'git clone https://github\.com/IntelliTect-Samples/IntelliSDLC\.ai'
            Test-Path (Join-Path $out '.sdlc-pulled.marker') | Should -BeFalse
            $log = Get-Content (Join-Path $out '.run-agent/transcript.log') -Raw
            $log | Should -Match 'sdlc-integration:\s*skipped:\s*non-interactive default'
        } finally { Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue }
    }
}


