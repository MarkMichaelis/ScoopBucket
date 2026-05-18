#Requires -Version 7
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../..')
    $script:TddPath  = Join-Path $script:RepoRoot '.github/instructions/tdd.instructions.md'
    $script:SkillPath = Join-Path $script:RepoRoot '.github/skills/behavior-first-testing/SKILL.md'
}

Describe 'tdd.instructions.md structural shape (Issue #71)' {
    It 'exists' {
        Test-Path $script:TddPath | Should -BeTrue
    }

    It 'is between 30 and 80 lines (slim, delegates to skill)' {
        $lines = (Get-Content -LiteralPath $script:TddPath).Count
        $lines | Should -BeGreaterOrEqual 30
        $lines | Should -BeLessOrEqual 80
    }

    It 'contains the literal phrase "Two-Part Rule"' {
        $content = Get-Content -LiteralPath $script:TddPath -Raw
        $content | Should -Match 'Two-Part Rule'
    }

    It 'links to the canonical behavior-first-testing skill' {
        $content = Get-Content -LiteralPath $script:TddPath -Raw
        $content | Should -Match 'behavior-first-testing/SKILL\.md'
    }

    It 'no longer contains the moved-out F.I.R.S.T. section heading' {
        $content = Get-Content -LiteralPath $script:TddPath -Raw
        # Mentioning F.I.R.S.T. as a delegated topic is fine; the *block* must be gone.
        $content | Should -Not -Match '(?m)^#+\s.*F\.I\.R\.S\.T\.'
    }
}

Describe 'behavior-first-testing skill remains canonical source (Issue #71)' {
    It 'contains the phrase "Red-Green-Refactor"' {
        $content = Get-Content -LiteralPath $script:SkillPath -Raw
        $content | Should -Match 'Red-Green-Refactor'
    }

    It 'contains the F.I.R.S.T. test-quality block (moved from instructions)' {
        $content = Get-Content -LiteralPath $script:SkillPath -Raw
        $content | Should -Match 'F\.I\.R\.S\.T\.'
    }
}
