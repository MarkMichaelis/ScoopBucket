# ----------------------------------------------------------------------------
# Opt-in idempotency test for the completion registration system.
# Tag 'Idempotency' so it stays out of the default Light run; opt in with:
#   Invoke-Pester -Path bucket\CompletionIdempotency.Tests.ps1 -Tag Idempotency
# ----------------------------------------------------------------------------

Describe 'CliCompletion idempotency' -Tag 'Heavy','Idempotency' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Utils.ps1')
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("CC-idem-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:profilePath = Join-Path $script:sandbox 'Profile.ps1'

        # Use a small deterministic set so the test doesn't depend on
        # whatever happens to be on the developer's PATH.
        $script:names = @('gh','rg','docker','copilot')
    }

    AfterAll {
        if (Test-Path $script:sandbox) {
            Remove-Item -Path $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'two -Force runs produce byte-identical profile content' {
        Register-AllCliCompletions -Force -ProfilePath $script:profilePath -Names $script:names | Out-Null
        $first = [System.IO.File]::ReadAllBytes($script:profilePath)
        Register-AllCliCompletions -Force -ProfilePath $script:profilePath -Names $script:names | Out-Null
        $second = [System.IO.File]::ReadAllBytes($script:profilePath)
        $first.Length | Should -Be $second.Length
        for ($i = 0; $i -lt $first.Length; $i++) {
            $first[$i] | Should -Be $second[$i]
        }
    }

    It 'second run produces at most one :BEGIN block per CLI' {
        $content = Get-Content -Raw -Path $script:profilePath
        foreach ($n in $script:names) {
            $pattern = "# ScoopBucket:CliCompletion:$n`:BEGIN"
            $count = ([regex]::Matches($content, [regex]::Escape($pattern))).Count
            # Could be 0 (no native completion / no PSCompletions def) or
            # exactly 1 — never more.
            $count | Should -BeLessOrEqual 1
        }
    }

    It '-Force:$false preserves a manually-modified block' {
        # Seed with -Force, then mutate the gh block, then re-run without
        # -Force; the mutated block must survive.
        Register-AllCliCompletions -Force -ProfilePath $script:profilePath -Names @('gh') | Out-Null
        $content = Get-Content -Raw -Path $script:profilePath
        if ($content -match '# ScoopBucket:CliCompletion:gh:BEGIN') {
            $mutated = $content -replace 'Get-Command gh','Get-Command gh # USER MUTATION'
            [System.IO.File]::WriteAllText($script:profilePath, $mutated, [System.Text.UTF8Encoding]::new($false))
            Register-AllCliCompletions -ProfilePath $script:profilePath -Names @('gh') | Out-Null
            $after = Get-Content -Raw -Path $script:profilePath
            $after | Should -Match 'USER MUTATION'
        }
        else {
            Set-ItResult -Skipped -Because "'gh' has no native completion available in this environment; mutation case n/a."
        }
    }

    It '-WhatIf does not touch the profile file' {
        $tempProfile = Join-Path $script:sandbox 'WhatIfProfile.ps1'
        Register-AllCliCompletions -Force -WhatIf -ProfilePath $tempProfile -Names @('gh') | Out-Null
        (Test-Path $tempProfile) | Should -Be $false
    }
}
