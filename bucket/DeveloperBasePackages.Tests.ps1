# ----------------------------------------------------------------------------
# DeveloperBasePackages bundle script tests (Pester v5).
#
# Stubs `choco` and `scoop`; verifies the scoop installs use the global (-g)
# flag (the script intentionally installs developer tooling system-wide).
# ----------------------------------------------------------------------------

Describe 'DeveloperBasePackages bundle' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'DeveloperBasePackages.ps1'
        $script:chocoCalls = @()
        $script:scoopCalls = @()

        function choco { $script:chocoCalls += ,@($args) }
        function scoop { $script:scoopCalls += ,@($args) }

        $script:InvokeBundle = {
            $src = Get-Content -Raw -Path $script:sut
            $src = $src -replace '(?m)^\s*\.\s+"\$PSScriptRoot\\Utils\.ps1".*$',''
            . ([scriptblock]::Create($src))
        }
        & $script:InvokeBundle
    }

    It 'invokes choco install for nodejs' {
        $script:chocoCalls.Count | Should -Be 1
        ($script:chocoCalls[0] -join ' ') | Should -Be 'install -y nodejs'
    }

    It 'invokes scoop install -g for each developer package' {
        $script:scoopCalls.Count | Should -Be 3
        $names = $script:scoopCalls | ForEach-Object { $_[-1] }
        $names | Should -Contain 'gh'
        $names | Should -Contain 'dotnet'
        $names | Should -Contain 'VisualStudio2022Enterprise'

        foreach ($call in $script:scoopCalls) {
            $call | Should -Contain '-g'
            $call[0] | Should -Be 'install'
        }
    }

    It 'is idempotent on re-run' {
        $script:chocoCalls = @()
        $script:scoopCalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:chocoCalls.Count | Should -Be 1
        $script:scoopCalls.Count | Should -Be 3
    }
}
