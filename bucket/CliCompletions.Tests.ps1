# ----------------------------------------------------------------------------
# Pester v5 tests for the CliCompletions bundle entry point (Completions.ps1)
# and the bundle manifest. Uses a sandbox profile path to avoid touching
# $PSHOME\Profile.ps1.
# ----------------------------------------------------------------------------

Describe 'CliCompletions bundle' -Tag 'Light','Bundle' {

    BeforeAll {
        $script:repoBucket = $PSScriptRoot
        $script:manifest   = Join-Path $script:repoBucket 'CliCompletions.json'
        $script:script     = Join-Path $script:repoBucket 'Completions.ps1'
        $script:sandbox    = Join-Path ([System.IO.Path]::GetTempPath()) ("CliCompletions-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:profilePath = Join-Path $script:sandbox 'Profile.ps1'
    }

    AfterAll {
        if (Test-Path $script:sandbox) {
            Remove-Item -Path $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Manifest' {
        It 'is valid JSON' {
            { Get-Content -Raw -Path $script:manifest | ConvertFrom-Json } | Should -Not -Throw
        }
        It 'follows the semver patch convention (X.YY.ZZZ)' {
            $json = Get-Content -Raw -Path $script:manifest | ConvertFrom-Json
            $json.version | Should -Match '^\d+\.\d{2}\.\d{3}$'
        }
        It 'exposes the register-all-cli-completions shim' {
            $json = Get-Content -Raw -Path $script:manifest | ConvertFrom-Json
            $names = @($json.bin | ForEach-Object { if ($_ -is [array]) { $_[1] } else { $_ } })
            $names | Should -Contain 'register-all-cli-completions'
        }
        It 'wires Completions.ps1 with -Force in the installer' {
            $json = Get-Content -Raw -Path $script:manifest | ConvertFrom-Json
            $json.installer.script | Should -Match '-Force'
        }
    }

    Context 'Completions.ps1 against a sandbox profile' {
        It 'creates a profile and registers a curated CLI when present in -Names' {
            & $script:script -Force -ProfilePath $script:profilePath -Names @('gh')
            Test-Path $script:profilePath | Should -Be $true
        }
        It 'is idempotent: running twice with -Force produces identical bytes' {
            $names = @('gh','rg','docker')
            & $script:script -Force -ProfilePath $script:profilePath -Names $names
            $first = [System.IO.File]::ReadAllBytes($script:profilePath)
            & $script:script -Force -ProfilePath $script:profilePath -Names $names
            $second = [System.IO.File]::ReadAllBytes($script:profilePath)
            (Compare-Object $first $second) | Should -BeNullOrEmpty
        }
        It 'preserves existing blocks when run without -Force' {
            # Run once with -Force to seed.
            & $script:script -Force -ProfilePath $script:profilePath -Names @('gh')
            $seeded = Get-Content -Raw -Path $script:profilePath
            # Run again without -Force; profile must be unchanged.
            & $script:script -ProfilePath $script:profilePath -Names @('gh')
            $after = Get-Content -Raw -Path $script:profilePath
            $after | Should -Be $seeded
        }
        It '-WhatIf does not touch the profile file' {
            # Reset the sandbox profile.
            if (Test-Path $script:profilePath) { Remove-Item $script:profilePath -Force }
            & $script:script -Force -WhatIf -ProfilePath $script:profilePath -Names @('gh')
            (Test-Path $script:profilePath) | Should -Be $false
        }
    }
}
