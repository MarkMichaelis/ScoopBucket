#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Structural tests for the dev-loop / plan agent boundary (issue #73).
# Asserts that dev-loop.agent.md Phase 0 delegates the design dialogue to the
# Plan agent rather than duplicating the Socratic-question recipe, and that
# plan.agent.md still contains that recipe.

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:DevLoop    = Join-Path $script:RepoRoot '.github/agents/dev-loop.agent.md'
    $script:PlanAgent  = Join-Path $script:RepoRoot '.github/agents/plan.agent.md'

    # Extract the body of the '### Phase 0' section: lines after the header
    # up to (but not including) the next '### ' header.
    function Get-Phase0Section {
        param([string]$Path)
        $lines = Get-Content -LiteralPath $Path
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^###\s+Phase\s+0\b') { $start = $i; break }
        }
        if ($start -lt 0) { return $null }
        $end = $lines.Count
        for ($j = $start + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^###\s') { $end = $j; break }
        }
        return ,($lines[$start..($end - 1)])
    }
}

Describe 'dev-loop.agent.md Phase 0 delegates to Plan agent' {
    BeforeAll {
        $script:Phase0 = Get-Phase0Section -Path $script:DevLoop
    }

    It 'has a Phase 0 section' {
        $script:Phase0 | Should -Not -BeNullOrEmpty
    }

    It 'Phase 0 section is shorter than 50 lines (delegate, not recipe)' {
        $script:Phase0.Count | Should -BeLessThan 50
    }

    It 'Phase 0 section references the Plan agent (plan.agent.md or @plan)' {
        $body = $script:Phase0 -join "`n"
        ($body -match 'plan\.agent\.md' -or $body -match '@plan') | Should -BeTrue
    }

    It 'Phase 0 section mentions the skip-if-issue-exists short-circuit' {
        $body = $script:Phase0 -join "`n"
        $body | Should -Match '(?i)(skip|already exists|existing issue)'
    }
}

Describe 'plan.agent.md preserves the core Socratic-question recipe' {
    BeforeAll {
        $script:PlanText = Get-Content -LiteralPath $script:PlanAgent -Raw
    }

    It 'mentions asking questions one at a time' {
        $script:PlanText | Should -Match '(?i)one\s+(question\s+)?(at\s+a\s+time|per\s+message)'
    }

    It 'mentions proposing 2-3 approaches with trade-offs' {
        $script:PlanText | Should -Match '(?i)2-3\s+(different\s+)?approaches'
        $script:PlanText | Should -Match '(?i)trade-?offs'
    }

    It 'mentions creating a GitHub issue as the primary output' {
        $script:PlanText | Should -Match '(?i)GitHub\s+issue'
    }

    It 'mentions multiple choice question preference' {
        $script:PlanText | Should -Match '(?i)multiple\s+choice'
    }
}
