# ----------------------------------------------------------------------------
# Opt-in idempotency test for the completion registration system.
# Tag 'Idempotency' so it stays out of the default Light run; opt in with:
#   Invoke-Pester -Path bucket\CompletionIdempotency.Tests.ps1 -Tag Idempotency
# ----------------------------------------------------------------------------

Describe 'CliCompletion idempotency' -Tag 'Heavy','Idempotency' {

    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force } 
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("CC-idem-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:profilePath = Join-Path $script:sandbox 'Profile.ps1'

        # Native-command fixture: emit deterministic per-CLI source so the
        # test never depends on which CLIs happen to be on PATH or whether
        # PSCompletions is installed.
        function script:New-NativeFixture {
            param([string]$Cli)
            [scriptblock]::Create("Write-Output 'Register-ArgumentCompleter -CommandName $Cli -ScriptBlock { }'")
        }
        $script:names = @('gh','rg','docker','copilot')

        function script:Invoke-FixtureRegistration {
            param([string]$ProfilePath, [string[]]$Names, [switch]$Force)
            foreach ($n in $Names) {
                $splat = @{
                    Cli           = $n
                    NativeCommand = (New-NativeFixture $n)
                    ProfilePath   = $ProfilePath
                    Confirm       = $false
                }
                if ($Force) { $splat['Force'] = $true }
                Register-CliCompletion @splat | Out-Null
            }
        }
    }

    AfterAll {
        if (Test-Path $script:sandbox) {
            Remove-Item -Path $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'two -Force runs produce byte-identical profile content' {
        Invoke-FixtureRegistration -ProfilePath $script:profilePath -Names $script:names -Force
        $first = [System.IO.File]::ReadAllBytes($script:profilePath)
        Invoke-FixtureRegistration -ProfilePath $script:profilePath -Names $script:names -Force
        $second = [System.IO.File]::ReadAllBytes($script:profilePath)
        $first.Length | Should -Be $second.Length
        for ($i = 0; $i -lt $first.Length; $i++) {
            $first[$i] | Should -Be $second[$i]
        }
    }

    It 'second run produces exactly one :BEGIN block per CLI' {
        $content = Get-Content -Raw -Path $script:profilePath
        foreach ($n in $script:names) {
            $pattern = "# ScoopBucket:CliCompletion:$n`:BEGIN"
            $count = ([regex]::Matches($content, [regex]::Escape($pattern))).Count
            $count | Should -Be 1 -Because "every fixture CLI emits one and only one block per profile"
        }
    }

    It '-Force:$false preserves a manually-modified block' {
        Invoke-FixtureRegistration -ProfilePath $script:profilePath -Names @('gh') -Force
        $content = Get-Content -Raw -Path $script:profilePath
        $mutated = $content -replace 'Register-ArgumentCompleter -CommandName gh','Register-ArgumentCompleter -CommandName gh # USER MUTATION'
        [System.IO.File]::WriteAllText($script:profilePath, $mutated, [System.Text.UTF8Encoding]::new($false))
        Invoke-FixtureRegistration -ProfilePath $script:profilePath -Names @('gh')   # no -Force
        $after = Get-Content -Raw -Path $script:profilePath
        $after | Should -Match 'USER MUTATION'
    }

    It '-WhatIf does not touch the profile file' {
        $tempProfile = Join-Path $script:sandbox 'WhatIfProfile.ps1'
        Register-CliCompletion -Cli gh -NativeCommand (New-NativeFixture 'gh') -Force -WhatIf -ProfilePath $tempProfile -Confirm:$false | Out-Null
        (Test-Path $tempProfile) | Should -Be $false
    }
}
