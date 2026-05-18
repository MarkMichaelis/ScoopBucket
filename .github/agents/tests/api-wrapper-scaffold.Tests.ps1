#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Structural tests for the api-wrapper-scaffold skill (issue #34).
#
# These tests do not exercise the skill's runtime behavior (it is invoked
# by humans / Copilot, not a script). They verify the skill definition file
# and template-folder layout stay internally consistent so a consumer
# always finds the assets the skill claims exist.

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:SkillPath = Join-Path $script:RepoRoot '.github/skills/api-wrapper-scaffold/SKILL.md'
    $script:AgentPath = Join-Path $script:RepoRoot '.github/agents/api-wrapper-scaffold.agent.md'
    $script:TemplateRoot = Join-Path $script:RepoRoot 'templates/api-wrapper-scaffold'
    $script:CopilotInstructionsPath = Join-Path $script:RepoRoot '.github/copilot-instructions.md'
    $script:SkillText = Get-Content -LiteralPath $script:SkillPath -Raw
}

Describe 'api-wrapper-scaffold SKILL.md' {

    It 'exists at the canonical path' {
        Test-Path -LiteralPath $script:SkillPath | Should -BeTrue
    }

    It 'has YAML frontmatter with name and description' {
        $script:SkillText | Should -Match '(?m)^---\s*$'
        $script:SkillText | Should -Match '(?m)^name:\s*\S+'
        $script:SkillText | Should -Match '(?m)^description:\s*"'
    }

    It 'declares the 11 ordered phases' {
        1..11 | ForEach-Object {
            $script:SkillText | Should -Match "Phase $_ --"
        }
    }

    It 'enumerates every supported auth classification' {
        $expected = @(
            'cookie',
            'cookie\+csrf',
            'bearer',
            'sso-google',
            'sso-microsoft',
            'sso-facebook',
            'oauth2-pkce'
        )
        foreach ($auth in $expected) {
            $script:SkillText | Should -Match $auth
        }
    }

    It 'requires user confirmation before any filesystem mutation' {
        $script:SkillText | Should -Match '(?i)Hard Gate'
        $script:SkillText | Should -Match '(?i)Confirmed (the target URL|a project name)'
    }

    It 'references the evidence-capture skill (Phase 5b)' {
        $script:SkillText | Should -Match 'evidence-capture'
        $script:SkillText | Should -Match 'Phase 5b'
    }
}

Describe 'templates/api-wrapper-scaffold/' {

    It 'has the documented subdirectory layout' {
        foreach ($d in 'scripts', 'csharp', 'powershell', 'config') {
            Test-Path -LiteralPath (Join-Path $script:TemplateRoot $d) -PathType Container | Should -BeTrue
        }
    }

    It 'has a README documenting tokens and layout' {
        $readmePath = Join-Path $script:TemplateRoot 'README.md'
        Test-Path -LiteralPath $readmePath | Should -BeTrue
        $readme = Get-Content -LiteralPath $readmePath -Raw
        # Every token the README documents must appear in the skill's
        # Phase 6 / Phase 9 description, since the skill is the canonical
        # consumer of the templates.
        $tokenMatches = [regex]::Matches($readme, '\{\{(\w+)\}\}')
        $tokenMatches.Count | Should -BeGreaterThan 0
        foreach ($m in $tokenMatches) {
            $token = $m.Groups[1].Value
            # ProjectSalt and NowIso are runtime-only and may legitimately
            # only appear in the README, so skip those.
            if ($token -in @('ProjectSalt', 'NowIso')) { continue }
            $script:SkillText | Should -Match $token
        }
    }

    It 'README references the skill path, not the (removed) agent path' {
        $readmePath = Join-Path $script:TemplateRoot 'README.md'
        $readme = Get-Content -LiteralPath $readmePath -Raw
        $readme | Should -Match '\.github/skills/api-wrapper-scaffold/SKILL\.md'
        $readme | Should -Not -Match 'api-wrapper-scaffold\.agent\.md'
    }
}

Describe 'api-wrapper-scaffold agent stub + skill registration (issues #70, #83)' {

    # Issue #70 originally migrated this scaffold from an @-agent to a pure
    # skill (the agent file was deleted). Issue #83 reversed the file
    # deletion to preserve `@api-wrapper-scaffold` discoverability while
    # keeping the canonical instructions in the skill. The current
    # invariants are therefore:
    #   - a thin delegating agent stub DOES ship at the canonical path,
    #   - that stub delegates to the skill (it does not duplicate it),
    #   - both the skill (in the Skills table) and the agent stub
    #     (in the Agents table) appear in copilot-instructions.md.

    It 'ships a delegating agent stub at the canonical path' {
        Test-Path -LiteralPath $script:AgentPath | Should -BeTrue
        $agent = Get-Content -LiteralPath $script:AgentPath -Raw
        # The stub must delegate to the skill rather than duplicating it.
        $agent | Should -Match 'skills/api-wrapper-scaffold/SKILL\.md'
    }

    It 'lists the skill in the Skills table of copilot-instructions.md' {
        $instructions = Get-Content -LiteralPath $script:CopilotInstructionsPath -Raw
        $skillsSection = [regex]::Match(
            $instructions,
            '(?s)###\s+Skills\b.*?(?=\n###\s)'
        ).Value
        $skillsSection | Should -Not -BeNullOrEmpty
        $skillsSection | Should -Match '`api-wrapper-scaffold`'
    }

    It 'lists the agent stub in the Agents table of copilot-instructions.md' {
        $instructions = Get-Content -LiteralPath $script:CopilotInstructionsPath -Raw
        $agentsSection = [regex]::Match(
            $instructions,
            '(?s)###\s+Agents\b.*?(?=\n###\s|\z)'
        ).Value
        $agentsSection | Should -Not -BeNullOrEmpty
        $agentsSection | Should -Match 'api-wrapper-scaffold\.agent\.md'
    }
}
