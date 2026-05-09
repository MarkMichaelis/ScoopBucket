# ----------------------------------------------------------------------------
# DeveloperBasePackages bundle script tests (Pester v5).
#
# Stubs `choco`, `scoop`, and `winget`; verifies routing of each developer
# tool to the right install engine. Globals (-g) for scoop installs that
# need to land system-wide; per-user for MarkMichaelis/Aspire (which uses
# `dotnet tool install --global` internally).
# ----------------------------------------------------------------------------

Describe 'DeveloperBasePackages bundle' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'DeveloperBasePackages.ps1'
        $script:chocoCalls  = @()
        $script:scoopCalls  = @()
        $script:wingetCalls = @()

        function choco  { $script:chocoCalls  += ,@($args) }
        function scoop  { $script:scoopCalls  += ,@($args) }
        function winget { $script:wingetCalls += ,@($args) }

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

    It 'invokes scoop install for each developer package' {
        # 2 globals (dotnet, VisualStudio2026Enterprise) + 1 per-user
        # (MarkMichaelis/Aspire) = 3 scoop calls. Aspire is installed without
        # -g because it shells out to `dotnet tool install --global` which
        # already places the CLI on the user's PATH.
        $script:scoopCalls.Count | Should -Be 3
        $names = $script:scoopCalls | ForEach-Object { $_[-1] }
        $names | Should -Contain 'dotnet'
        $names | Should -Contain 'VisualStudio2026Enterprise'
        $names | Should -Contain 'MarkMichaelis/Aspire'

        $globalCalls = $script:scoopCalls | Where-Object { $_ -contains '-g' }
        @($globalCalls).Count | Should -Be 2
        foreach ($call in $script:scoopCalls) {
            $call[0] | Should -Be 'install'
        }
    }

    It 'invokes winget install --scope machine for each winget package' {
        $script:wingetCalls.Count | Should -Be 4
        $invokedIds = $script:wingetCalls | ForEach-Object {
            $idIdx = [array]::IndexOf($_, '--id')
            if ($idIdx -ge 0) { $_[$idIdx + 1] }
        }
        $invokedIds | Should -Contain 'Microsoft.VisualStudioCode'
        $invokedIds | Should -Contain 'GitHub.Copilot'
        $invokedIds | Should -Contain 'Python.Python.3.14'
        $invokedIds | Should -Contain 'ScooterSoftware.BeyondCompare.4'
        foreach ($call in $script:wingetCalls) {
            $call[0] | Should -Be 'install'
            $call    | Should -Contain '--scope'
            $call    | Should -Contain 'machine'
        }
    }

    It 'is idempotent on re-run' {
        $script:chocoCalls  = @()
        $script:scoopCalls  = @()
        $script:wingetCalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:chocoCalls.Count  | Should -Be 1
        $script:scoopCalls.Count  | Should -Be 3
        $script:wingetCalls.Count | Should -Be 4
    }
}
