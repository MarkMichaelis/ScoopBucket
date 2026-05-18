# CLAUDE.md

This file provides orientation for AI assistants working in this repository.

> **⚠️ Generic instructions — no project-specific content. Upstream-only edits.**
> These instruction files are shared across multiple projects. Never add
> project names, architecture details, domain concepts, specific dependencies,
> or hardcoded paths. All changes must be made in the
> [IntelliSDLC.ai](https://github.com/IntelliTect-Dev/IntelliSDLC.ai)
> repo and pulled into consuming projects — never edited locally and pushed back.
> Project-specific context belongs in the consuming project's own
> `CLAUDE.project.md` and `.github/instructions/project.instructions.md`.
> See `README.md` for details.

## Init Protocol for Consuming Projects

When an AI agent runs first-time setup (e.g., Claude Code's `/init`) in a project
that consumes IntelliSDLC.ai, follow this protocol:

**DO NOT modify any upstream-managed file:**

- `CLAUDE.md`
- `.github/copilot-instructions.md`
- `.github/agents/*`
- `.github/instructions/*` (except `project.instructions.md`)
- `.github/skills/*`

These are pulled from IntelliSDLC.ai and any local edits will be lost
on the next sync. The Validate Instructions workflow may also flag leaks.

**DO create or extend the consumer-owned files:**

- `.github/instructions/project.instructions.md` -- copy from
  `project.instructions.md.template` if missing. Document project name,
  architecture, tech stack, build commands, key conventions, and domain
  glossary here. Read by all coding agents.
- `CLAUDE.project.md` -- copy from `CLAUDE.project.md.template` if missing.
  Auto-imported by Claude Code via the `@CLAUDE.project.md` line at the
  bottom of this file. Use for Claude-specific orientation overrides.

If a `*.template` file is present but the corresponding consumer-owned file
is not, copy the template (drop the `.template` suffix) and fill in the
sections. `Pull-SDLC.ai.ps1` does this automatically on first sync.

## GitHub Repository

Determine the repository owner and name from the git remote:

```bash
git remote get-url origin
```

When calling GitHub MCP tools, use the `owner` and `repo` values parsed from the
remote URL. Do **not** infer these values from the local directory name.

## ⛔ Before ANY Commit

**STOP and verify these before every `git commit`:**

1. **You are inside a worktree** (NOT the repo root). Run `git rev-parse --git-dir` — the
   path must differ from `git rev-parse --git-common-dir`. If they are the same, you are in
   the repo root: create a worktree immediately.
2. **You are NOT on `main`.** Run `git branch --show-current` — if it says `main`, stop
   and create a worktree/feature branch first.
3. **A GitHub issue exists** for the work you are committing. If not, create one first.
4. **You plan to open a PR** linking to that issue. Never merge to `main` directly.

A pre-commit hook (`.githooks/pre-commit`) enforces rules 1 and 2 automatically. Activate it:

```powershell
git config core.hooksPath .githooks
```

## Key References

- **Development conventions**: [`.github/copilot-instructions.md`](./.github/copilot-instructions.md) -- code style, testing conventions, branching strategy, commit format, and workflow.
- **Skills**: [`.github/skills/`](./.github/skills/) -- reusable process definitions (behavior-first testing, refactoring, code review, debugging, functional testing, phase gates).
- **Agents**: [`.github/agents/`](./.github/agents/) -- orchestrators and interactive workflows (dev loop, planning, code review, instructions, PRD).
- **Language conventions**: [`.github/instructions/`](./.github/instructions/) -- C#, PowerShell, TypeScript, behavior-first testing principles.

## Repository Structure

Discover the project layout by examining the root directory. A typical C#/.NET project follows:

```
<RepoRoot>/
├── src/                           # Production source code
│   ├── <ProjectName>/             # Core library or application project(s)
│   └── <ProjectName>.*/           # Additional projects (API, CLI, Web, etc.)
├── tests/
│   └── unit/                      # xUnit unit tests mirroring src structure
├── docs/                          # Additional documentation
├── *.sln or *.slnx                # Solution file
└── .github/
    ├── copilot-instructions.md    # Primary dev conventions (read this first)
    ├── agents/                    # Agent prompt files (.agent.md)
    ├── skills/                    # Reusable process skills (SKILL.md)
    ├── instructions/              # Language/practice-specific instructions
    └── workflows/                 # GitHub Actions (CI setup steps)
```

## Technology Stack

| Layer | Technology |
|---|---|
| Language | C# / .NET 9+ |
| Testing | xUnit, Moq, FluentAssertions |

> Discover the full technology stack from solution/project files, `README.md`, and
> NuGet package references. Do not assume specific runtime hosts or external APIs.

## Shell Preference

Use **PowerShell** as the default shell for all commands. If PowerShell is not available, fall back to bash.

> **Encoding warning:** On Windows, the `gh` CLI garbles Unicode and collapses
> newlines when body text is passed inline. Never read an existing PR body with
> `--jq` and re-interpolate — PowerShell destroys newlines. Always construct the
> full body from scratch and use `--body-file`. See the **PR & Issue Body
> Formatting** section in `copilot-instructions.md`.

## Essential Commands

```powershell
# Build
dotnet build --no-restore

# Test
dotnet test --no-build --verbosity normal

# Format
dotnet format
```

Always run `dotnet build` and `dotnet test` after every code change. Fix all errors before proceeding.

## Development Workflow

Follow the full dev loop for any feature:

```
Sync Instructions → Brainstorm+Issue → Worktree → Plan → [TDD → Refactor → Functional Test → Code Review+Fix → PR+Copilot Review+Dry Run]* → Merge → Cleanup
```

Use `@dev-loop` to orchestrate the full cycle. Phases 3-7 use an expanding loop -- each
phase is a quality gate, and any failure routes back to Phase 3 (TDD). The loop exits
only when Copilot review passes with zero issues and the dry run succeeds.
See `.github/copilot-instructions.md` -> **Skills & Agents** for the complete reference.

- **Sync instructions first:** Before starting any dev loop, check whether the shared
  IntelliSDLC.ai have been updated upstream. Pull and merge the latest, then
  reload instructions so the current session uses the most recent rules.

- **Plan tracking:** Brainstorm (Phase 0) is delegated to the `@plan` agent,
  which produces the GitHub issue that captures the design. Update that issue
  with the implementation checklist in Phase 2. Link the PR with
  `Closes #<issue-number>` so merging auto-closes the issue.
- **Issue-before-implementation:** When using plan mode before a dev loop, create
  the GitHub issue at the end of planning (before implementation starts). The dev
  loop then references the existing issue instead of creating a new one.
- **Autopilot mode:** When autopilot is used to implement a plan, always use the
  Dev Loop agent (`@dev-loop`). Never skip the full quality cycle for plan work.

## Task Complete Summaries

When calling `task_complete`, include the following fields whenever the data
exists (omit any that don't apply, e.g., a Q&A turn with no PR):

- **Issue** -- `[#NNN](https://github.com/<owner>/<repo>/issues/NNN)`
- **PR** -- `[#NNN](https://github.com/<owner>/<repo>/pull/NNN)`
- **Branch** -- `` [`<branch>`](https://github.com/<owner>/<repo>/tree/<branch>) ``
- **Test** -- exact local verification command (e.g., `dotnet test --no-build`,
  `Invoke-Pester -Path .\...`)

See the **Task Complete Summary Format** subsection of
`.github/copilot-instructions.md` for the canonical specification.

## Branching & Commits

- Never commit to `main` directly — always use a feature branch in a **worktree**.
- Create worktrees in `.worktrees/`: `git worktree add .worktrees/<issue#>-<name> -b <branch> main`.
- Branch naming: `<type>/<issue#>-<short-description>` (e.g., `feat/42-user-auth`)
- Commit format: `type(scope): description` (Conventional Commits)
- Merge to `main` only via pull request after the dev loop passes. **This repo
  only allows rebase merges** -- use `gh pr merge <pr-number> --rebase --delete-branch`.
  Never merge while CI is red.
- **All commits must come from a worktree** — the pre-commit hook blocks commits from the repo root.
  See the "Concurrent Session Safety" section in `.github/copilot-instructions.md` for details.
- **After a PR closes**, clean up the worktree and local branch. The recommended
  workflow is to run the `Cleanup-Worktree.ps1` script at the repo root, which
  performs all steps below automatically (auto-detects the branch when invoked
  from inside the worktree):

  ```powershell
  ./Cleanup-Worktree.ps1                           # targeted (auto-detect)
  ./Cleanup-Worktree.ps1 -Branch <name> -Force     # PR closed unmerged
  ./Cleanup-Worktree.ps1 -Sweep                    # + prune stale branches/refs
  ```

  Manual fallback (in order):
  1. Ensure your shell is **not** inside the worktree (e.g., `cd` back to the repo root).
  2. Unlock if needed, then remove the worktree: `git worktree unlock .worktrees/<issue#>-<name> || true; git worktree remove .worktrees/<issue#>-<name>`.
  3. Switch to `main` and pull latest: `git checkout main && git pull`.
  4. If the branch was merged, delete it safely: `git branch -d <branch-name>`.
     - If the PR was closed **without** merging and you still want to delete the branch,
       you must force‑delete it: `git branch -D <branch-name>` (this discards any unmerged work).

## Project-Specific Extensions

Project-specific orientation lives in `CLAUDE.project.md` (created by the consuming project from `CLAUDE.project.md.template`). The line below auto-imports it when present; Claude Code silently ignores the import if the file is absent.

@CLAUDE.project.md
