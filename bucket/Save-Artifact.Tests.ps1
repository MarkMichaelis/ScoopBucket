<#
.SYNOPSIS
    Light-suite tests for MarkMichaelis.ScoopBucket\Save-Artifact.

.DESCRIPTION
    Verifies the artifact-rotation contract used by CI diagnostic
    producers (Get-PackageCommands.ps1, Test-Installs.ps1):

      - writes a timestamped file plus stable latest.json
      - keeps at most 5 newest timestamped files per kind directory
      - prunes timestamped files whose LastWriteTime is older than 1 day
      - never prunes latest.json even when backdated
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psd1     = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force -ErrorAction Stop
}

Describe 'Save-Artifact' -Tag 'Light', 'Module' {

    BeforeEach {
        $script:root     = Join-Path $TestDrive ([guid]::NewGuid().Guid)
        $script:kindDir  = Join-Path (Join-Path $script:root 'ScoopBucket') 'unit-test'
    }

    It 'writes a timestamped file and latest.json and returns the timestamped path' {
        $payload = [pscustomobject]@{ a = 1; b = 'two' }
        $path = Save-Artifact -Kind 'unit-test' -Data $payload -Root $script:root

        $path                   | Should -Match 'unit-test-\d{8}-\d{6}'
        Test-Path -LiteralPath $path | Should -BeTrue

        $latest = Join-Path $script:kindDir 'latest.json'
        Test-Path -LiteralPath $latest | Should -BeTrue

        $stampedContent = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        $latestContent  = (Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json)
        $stampedContent.a | Should -Be 1
        $latestContent.b  | Should -Be 'two'
    }

    It 'overwrites latest.json with the most recent payload' {
        $null = Save-Artifact -Kind 'unit-test' -Data @{ which = 'first' }  -Root $script:root
        Start-Sleep -Milliseconds 1100  # ensure distinct second-resolution stamp
        $null = Save-Artifact -Kind 'unit-test' -Data @{ which = 'second' } -Root $script:root

        $latest = Get-Content -LiteralPath (Join-Path $script:kindDir 'latest.json') -Raw | ConvertFrom-Json
        $latest.which | Should -Be 'second'
    }

    It 'keeps at most 5 timestamped files after 6+ writes' {
        for ($i = 1; $i -le 7; $i++) {
            $null = Save-Artifact -Kind 'unit-test' -Data @{ i = $i } -Root $script:root
            Start-Sleep -Milliseconds 1100  # distinct UTC-second stamps
        }

        $stamped = Get-ChildItem -LiteralPath $script:kindDir -Filter 'unit-test-*.json' -File
        $stamped.Count | Should -Be 5

        # latest.json is still there alongside the 5 stamped files.
        Test-Path -LiteralPath (Join-Path $script:kindDir 'latest.json') | Should -BeTrue
    }

    It 'prunes timestamped files older than 1 day even when fewer than 5 exist' {
        $null = Save-Artifact -Kind 'unit-test' -Data @{ keep = $true } -Root $script:root

        # Plant a "fossil" timestamped file 2 days old, then take a second
        # snapshot (which triggers the prune pass).
        $fossil = Join-Path $script:kindDir 'unit-test-19990101-000000.json'
        Set-Content -LiteralPath $fossil -Value '{"fossil":true}' -Encoding UTF8
        $twoDaysAgoUtc = [DateTime]::UtcNow.AddDays(-2)
        (Get-Item -LiteralPath $fossil).LastWriteTimeUtc = $twoDaysAgoUtc

        $null = Save-Artifact -Kind 'unit-test' -Data @{ trigger = 'prune' } -Root $script:root

        Test-Path -LiteralPath $fossil | Should -BeFalse
    }

    It 'never prunes latest.json even when its LastWriteTime is backdated' {
        $null = Save-Artifact -Kind 'unit-test' -Data @{ marker = 'original' } -Root $script:root
        $latest = Join-Path $script:kindDir 'latest.json'
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)

        # Subsequent writes overwrite latest.json with fresh content + mtime;
        # the file itself must still exist.
        $null = Save-Artifact -Kind 'unit-test' -Data @{ marker = 'fresh' } -Root $script:root
        Test-Path -LiteralPath $latest | Should -BeTrue
        (Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json).marker | Should -Be 'fresh'
    }
}
