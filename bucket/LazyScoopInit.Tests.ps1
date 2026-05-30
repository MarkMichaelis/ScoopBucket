<#
.SYNOPSIS
    Guard the idempotency contract of Initialize-ScoopEnvironment:
      - Module load dot-sources it once (eager-light: core / buckets /
        manifest only; ~320 ms).
      - On success the guard flips to $true; a second call is a no-op.
      - On failure (a scoop lib missing or throwing), the guard does
        NOT flip, so a retry after the underlying scoop install is
        repaired will run the dot-source again.

    Initialize-ScoopEnvironment is module-private; tests invoke it via
    the module's session-state scriptblock (`$mod.Invoke({...})`).
#>

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    function script:Get-Mod { Get-Module MarkMichaelis.ScoopBucket }
    function script:Get-GuardState {
        $mod = script:Get-Mod
        if (-not $mod) { return $null }
        $mod.Invoke({ $script:ScoopEnvironmentInitialized })
    }
    function script:Set-GuardState {
        param([bool]$Value)
        $mod = script:Get-Mod
        $mod.Invoke({ param($v) $script:ScoopEnvironmentInitialized = $v }, $Value)
    }
    function script:Invoke-Init {
        $mod = script:Get-Mod
        $mod.Invoke({ Initialize-ScoopEnvironment })
    }
    function script:Invoke-InitDotSourced {
        # Mirror the .psm1 invocation pattern: `. Initialize-ScoopEnvironment`
        # so the inner `. $p` calls land in module scope.
        $mod = script:Get-Mod
        $mod.Invoke({ . Initialize-ScoopEnvironment })
    }
}

Describe 'Initialize-ScoopEnvironment idempotent guard' -Tag 'Light','Module' {
    BeforeEach {
        Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction Ignore
    }

    It 'flips the guard to $true on the eager module-load init' {
        Import-Module $script:psd1 -Force
        # The .psm1 calls `. Initialize-ScoopEnvironment` at load time,
        # so the guard should already be $true.
        script:Get-GuardState | Should -BeTrue
    }

    It 'no-ops on a second call (idempotent fast path)' {
        Import-Module $script:psd1 -Force
        { script:Invoke-Init } | Should -Not -Throw
        script:Get-GuardState | Should -BeTrue
    }

    It 'leaves the guard $false on failure and recovers on retry' {
        Import-Module $script:psd1 -Force
        # Force a re-init scenario by clearing the guard.
        script:Set-GuardState $false

        # Stage a fake $env:SCOOP root whose lib\manifest.ps1 throws on
        # dot-source. Resolve-ScoopRoot prefers $env:SCOOP when its
        # apps\scoop\current path exists.
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "lazyinit-$([guid]::NewGuid().ToString('N'))"
        $libDir   = Join-Path $tempRoot 'apps\scoop\current\lib'
        New-Item -ItemType Directory -Force -Path $libDir | Out-Null
        Set-Content -LiteralPath (Join-Path $libDir 'core.ps1')    -Value '# empty stub' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $libDir 'buckets.ps1') -Value '# empty stub' -Encoding utf8
        $brokenManifest = Join-Path $libDir 'manifest.ps1'
        Set-Content -LiteralPath $brokenManifest -Value 'throw "lazyinit-test-injection"' -Encoding utf8

        $savedScoop = $env:SCOOP
        try {
            $env:SCOOP = $tempRoot
            { script:Invoke-Init } | Should -Throw
            script:Get-GuardState | Should -BeFalse

            # Repair: replace the broken lib with a no-op; retry should succeed.
            Set-Content -LiteralPath $brokenManifest -Value '# repaired stub' -Encoding utf8
            { script:Invoke-Init } | Should -Not -Throw
            script:Get-GuardState | Should -BeTrue
        } finally {
            $env:SCOOP = $savedScoop
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Ignore
        }
    }
}