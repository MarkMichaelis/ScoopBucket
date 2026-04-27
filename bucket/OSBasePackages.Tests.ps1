# ----------------------------------------------------------------------------
# OSBasePackages bundle script tests (Pester v5).
#
# Bundle scripts call many `choco install` lines; we stub `choco` rather than
# performing a real install. The stub records every invocation in a $script:
# array and the assertions verify cardinality and content.
# ----------------------------------------------------------------------------

$ExpectedPackages = @(
    '7zip','notepad2','Everything','es','GoogleChrome','SysInternals',
    'WinDirStat','fzf','procexp','powershell-core','ussf','bat','ripgrep'
)

Describe 'OSBasePackages bundle' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'OSBasePackages.ps1'
        $script:chocoCalls = @()

        function choco { $script:chocoCalls += ,@($args) }

        # The bundle script dot-sources Utils.ps1, which defines its own
        # `choco`/`scoop` wrappers that would shadow our stubs and call the
        # real binaries. Strip that one line before executing the body so
        # our stubs intercept every call.
        $script:InvokeBundle = {
            $src = Get-Content -Raw -Path $script:sut
            $src = $src -replace '(?m)^\s*\.\s+"\$PSScriptRoot\\Utils\.ps1".*$',''
            . ([scriptblock]::Create($src))
        }
        & $script:InvokeBundle
    }

    It 'invokes choco install for each base package' {
        $script:chocoCalls.Count | Should -Be 13
        # Each call should be `install -y <name>`
        $names = $script:chocoCalls | ForEach-Object { $_[-1] }
        $names | Should -Contain '7zip'
        $names | Should -Contain 'ripgrep'
        ($script:chocoCalls[0] -join ' ') | Should -Match '^install -y '
    }

    It 'is idempotent on re-run' {
        $script:chocoCalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:chocoCalls.Count | Should -Be 13
    }
}
