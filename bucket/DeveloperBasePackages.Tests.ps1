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
        # 3 globals (gh, dotnet, VisualStudio2022Enterprise) + 1 per-user
        # (MarkMichaelis/Aspire) = 4 scoop calls. Aspire is installed without
        # -g because it shells out to `dotnet tool install --global` which
        # already places the CLI on the user's PATH.
        $script:scoopCalls.Count | Should -Be 4
        $names = $script:scoopCalls | ForEach-Object { $_[-1] }
        $names | Should -Contain 'gh'
        $names | Should -Contain 'dotnet'
        $names | Should -Contain 'VisualStudio2022Enterprise'
        $names | Should -Contain 'MarkMichaelis/Aspire'

        $globalCalls = $script:scoopCalls | Where-Object { $_ -contains '-g' }
        @($globalCalls).Count | Should -Be 3
        foreach ($call in $script:scoopCalls) {
            $call[0] | Should -Be 'install'
        }
    }

    It 'is idempotent on re-run' {
        $script:chocoCalls = @()
        $script:scoopCalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:chocoCalls.Count | Should -Be 1
        $script:scoopCalls.Count | Should -Be 4
    }
}
