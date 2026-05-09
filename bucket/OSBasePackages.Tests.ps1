# ----------------------------------------------------------------------------
# OSBasePackages bundle script tests (Pester v5).
#
# The bundle invokes `winget install --id <Id> --scope machine` once per
# entry in $OSPackages. We stub `winget` and assert cardinality and that
# every $OSPackages WinGetID gets installed with --scope machine.
# ----------------------------------------------------------------------------

Describe 'OSBasePackages bundle' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'OSBasePackages.ps1'
        $script:wingetCalls = @()

        # PowerShell function lookup is case-insensitive, so this stub catches
        # both `winget` and the bundle's `Winget` capitalization.
        function winget { $script:wingetCalls += ,@($args) }

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

        # Re-parse the bundle just to read $OSPackages so the expected count /
        # ID set comes from the same source the bundle iterates.
        $script:expectedIds = & {
            $src = Get-Content -Raw -Path $script:sut
            $src = $src -replace '(?m)^\s*\.\s+"\$PSScriptRoot\\Utils\.ps1".*$',''
            $src = $src -replace '(?ms)\$OSPackages\.VAlues.*$',''
            . ([scriptblock]::Create($src))
            $OSPackages.Values | ForEach-Object { $_.WinGetID }
        }
    }

    It 'invokes winget install for each $OSPackages entry' {
        $script:wingetCalls.Count | Should -Be $script:expectedIds.Count
        foreach ($call in $script:wingetCalls) {
            $call[0] | Should -Be 'install'
            $call    | Should -Contain '--id'
            $call    | Should -Contain '--scope'
            $call    | Should -Contain 'machine'
        }
        # Every WinGetID from $OSPackages should appear in the recorded calls.
        $invokedIds = $script:wingetCalls | ForEach-Object {
            $idIdx = [array]::IndexOf($_, '--id')
            if ($idIdx -ge 0) { $_[$idIdx + 1] }
        }
        foreach ($id in $script:expectedIds) {
            $invokedIds | Should -Contain $id
        }
    }

    It 'is idempotent on re-run' {
        $script:wingetCalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:wingetCalls.Count | Should -Be $script:expectedIds.Count
    }
}
