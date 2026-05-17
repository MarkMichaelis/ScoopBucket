#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for issue #92 -- the api-wrapper-scaffold skill must always
# prompt for both mobile-app discovery and the IntelliSDLC.ai pull, and the
# SDLC prompt must be anchored to a `git init` step performed by the agent.

BeforeAll {
    $script:RepoRoot  = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\') | Select-Object -ExpandProperty Path
    $script:SkillPath = Join-Path $script:RepoRoot '.github/skills/api-wrapper-scaffold/SKILL.md'
    $script:SkillText = Get-Content -LiteralPath $script:SkillPath -Raw
}

Describe 'api-wrapper-scaffold SKILL.md mandatory prompts (issue #92)' {

    Context 'Hard Gate' {
        It 'requires confirmation of mobile-app inclusion before mutating the filesystem' {
            # The Hard Gate must explicitly call out the mobile-app decision so
            # the agent cannot silently skip Phase 1.5.
            $script:SkillText | Should -Match '(?i)mobile app .*(y(es)?|n(o)?)'
        }

        It 'requires confirmation of IntelliSDLC.ai seeding before mutating the filesystem' {
            $script:SkillText | Should -Match '(?i)IntelliSDLC\.ai .*(seed|pull|instructions)'
        }
    }

    Context 'Phase 1.5 -- Mobile App Discovery' {
        It 'is marked as a required prompt, not optional' {
            # The header is the load-bearing signal that the agent must always ask.
            $script:SkillText | Should -Match 'Phase 1\.5 -- Mobile App Discovery \(required prompt\)'
        }

        It 'is no longer described as opt-in / optional in its first paragraph' {
            # Grab the Phase 1.5 section up to the next "### Phase" header.
            if ($script:SkillText -match '(?s)### Phase 1\.5[^\n]*\n(.*?)(?=\n### Phase )') {
                $section = $Matches[1]
                $section | Should -Not -Match '(?i)\bopt-in\b'
                $section | Should -Not -Match '(?i)This phase is \*\*optional\*\*'
            } else {
                throw "Phase 1.5 section not found in SKILL.md"
            }
        }

        It 'instructs the agent to ask the user explicitly' {
            $script:SkillText | Should -Match '(?i)ask the user'
            $script:SkillText | Should -Match '\[y/N\]'
        }
    }

    Context 'Git init + SDLC pull' {
        It 'documents an explicit git init step performed by the agent' {
            # The new phase must mention initializing the git repo.
            $script:SkillText | Should -Match '(?i)git init'
        }

        It 'requires the agent to prompt before pulling IntelliSDLC.ai' {
            # Y/n prompt wording with default-yes.
            $script:SkillText | Should -Match '\[Y/n\]'
        }

        It 'names the canonical sdlc.ai remote' {
            $script:SkillText | Should -Match '(?i)remote (called |named )?[`'']?sdlc\.ai[`'']?'
        }

        It 'sequences git init before the SDLC pull' {
            # The "git init" reference must appear in the file before the
            # Pull-SDLC.ai.ps1 invocation.
            $initIdx = $script:SkillText.IndexOf('git init')
            $pullIdx = $script:SkillText.IndexOf('Pull-SDLC.ai.ps1')
            $initIdx | Should -BeGreaterThan -1
            $pullIdx | Should -BeGreaterThan -1
            $initIdx | Should -BeLessThan $pullIdx
        }
    }

    Context 'Backwards compatibility' {
        It 'still lists Phases 1 through 11' {
            1..11 | ForEach-Object {
                $script:SkillText | Should -Match "Phase $_ --"
            }
        }
    }
}
