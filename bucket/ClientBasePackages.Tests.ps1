# ----------------------------------------------------------------------------
# ClientBasePackages bundle script tests (Pester v5).
#
# Stubs `choco` and `scoop`; verifies each package the script enumerates is
# routed to the right manager with the right arguments.
# ----------------------------------------------------------------------------

Describe 'ClientBasePackages bundle' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'ClientBasePackages.ps1'
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

    It 'invokes choco install for each chocolatey base package' {
        $script:chocoCalls.Count | Should -Be 3
        $names = $script:chocoCalls | ForEach-Object { $_[-1] }
        $names | Should -Contain 'foxitreader'
        $names | Should -Contain 'exiftool'
        $names | Should -Contain 'dbxcli'
        ($script:chocoCalls[0] -join ' ') | Should -Match '^install -y '
    }

    It 'invokes scoop install for the AIAgents bundle manifest' {
        $script:scoopCalls.Count | Should -Be 1
        ($script:scoopCalls[0] -join ' ') | Should -Be 'install MarkMichaelis/AIAgents'
    }

    It 'is idempotent on re-run' {
        $script:chocoCalls = @()
        $script:scoopCalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:chocoCalls.Count | Should -Be 3
        $script:scoopCalls.Count | Should -Be 1
    }
}
