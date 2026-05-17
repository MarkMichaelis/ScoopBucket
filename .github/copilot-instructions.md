# Copilot Workspace Instructions

> **Warning: Generic instructions -- no project-specific content. Upstream-only edits.**
> These instruction files are shared across multiple projects. Never add
> project names, architecture details, domain concepts, specific dependencies,
> or hardcoded paths. All changes must be made in the
> [IntelliSDLC.ai](https://github.com/IntelliTect-Dev/IntelliSDLC.ai)
> repo and pulled into consuming projects -- never edited locally and pushed back.
> Project-specific context belongs in the consuming project's own
> `.github/instructions/project.instructions.md` (and optionally
> `CLAUDE.project.md`). See `README.md` for details.

## Init Protocol for Consuming Projects

When an AI agent runs first-time setup (e.g., `/init`) in a project that
consumes IntelliSDLC.ai, follow this protocol:

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
  glossary here.
- `CLAUDE.project.md` -- copy from `CLAUDE.project.md.template` if missing.
  Auto-imported by Claude Code via the `@CLAUDE.project.md` line at the
  bottom of `CLAUDE.md`.

If a `*.template` file is present but the corresponding consumer-owned file
is not, copy the template (drop the `.template` suffix) and fill in the
sections. `Pull-SDLC.ai.ps1` does this automatically on first sync.

## Project Overview

This is a **C#/.NET** project. Discover the project's purpose, architecture, and full
technology stack from the solution/project files, `README.md`, and NuGet package references.

Key baseline technologies: C# / .NET 9+, xUnit, Moq.

## Language Detection

Detect the project's primary language from its files and apply the matching guidance below.
When multiple languages coexist, apply each language's rules to the files of that language.

| Indicator files | Language | Conventions |
|---|---|---|
| `.cs`, `.csproj`, `.sln` | C# / .NET | `.github/instructions/csharp.instructions.md` |
| `.ps1`, `.psm1`, `.psd1` | PowerShell | `.github/instructions/powershell.instructions.md` |
| `.ts`, `.js`, `package.json` | TypeScript / JS | `.github/instructions/typescript.instructions.md` |
| `.py`, `pyproject.toml` | Python | Infer from project |
| `.go`, `go.mod` | Go | Infer from project |
| `.rs`, `Cargo.toml` | Rust | Infer from project |
| `.java`, `pom.xml` | Java | Infer from project |

If the language is not listed, infer conventions from the project's existing code,
README, and build files.

## Development Philosophy

1. **Behavior-first testing** -- Ship a test with every behavior change; default to test-first. The test must fail for a behavioral reason (assertion failure, not compile error) when the change is reverted. Spikes may defer test-first but must be deleted or retro-fitted with behavior-first tests before merge.
2. **Systematic over ad-hoc** -- Process over guessing. Follow structured workflows.
3. **Complexity reduction** -- Simplicity as primary goal. YAGNI ruthlessly.
4. **Evidence over claims** -- Verify before declaring success.
5. **Functional Testing** -- Validate user-facing behavior with integration or E2E tests.
6. **Continuous Refactoring** -- Eliminate duplication after every green step.

## Code Style -- Generic (All Languages)

- Keep functions / methods small (<= 20 lines) and single-purpose.
- Prefer immutable variables where the language supports them.
- Every public function must have a documentation comment.
- Follow the language's established naming, formatting, and module conventions.
- Use the project's existing linter / formatter. Run it after every change.
- After **every step** (RED, GREEN, REFACTOR, or any code change), run the project's
  compile/lint command and verify there are no errors. Fix any errors before proceeding.

## Testing Conventions -- Generic

- **Unit tests** mirror the source tree.
- **Test files live in a `tests/` directory** (or the language's conventional location).
- Use the project's established test framework. If none exists, choose the community
  standard for the language.
- Functional / integration tests are organized by feature or user flow.

> Language-specific testing conventions are in the corresponding
> `*.instructions.md` files referenced in the Language Detection table above.

## Product Specification

If the project maintains a living product specification (e.g., `product-spec.md`):

- **Update the spec with every feature** -- document new behavior in the spec.
- **When a requirement changes, update the spec** -- it always describes the current state.
- **Replace superseded acceptance criteria** -- rewrite to match new behavior.
- Sections: Overview, Features (with acceptance criteria), API Surface, Data Model,
  Known Limitations.
- Use Conventional Commits: `docs(spec): add <feature> specification`.

## Tool Preferences

- **Prefer Git CLI over GitKraken MCP tools.** Use standard `git` commands for common
  operations.
- **GitKraken MCP tools are acceptable** when they provide functionality not easily
  available via the Git CLI.
- **Playwright MCP output directory: `.playwright-mcp/` at the repo root.** When a
  coding agent uses the Playwright MCP server (browser automation, console logs,
  page snapshots), all output -- `console-*.log`, `page-*.yml`, traces, screenshots
  -- must be written to `.playwright-mcp/` at the repo root. Do not let the MCP
  server create a different directory (e.g. `.playwright/`, `playwright-output/`,
  or a per-session temp dir under the user profile). Pin the path explicitly when
  invoking Playwright tools that accept an output directory. Consuming projects
  must add `.playwright-mcp/` to their `.gitignore` -- the directory is a
  per-session scratch area for the agent, not a build artifact, and must never be
  committed.

## Branching Strategy

- **Never commit directly to `main`.** Always create a feature branch first.
- Branch naming: `<type>/<issue#>-<short-description>`
  Examples: `feat/42-user-auth`, `fix/57-validation-error`.
- **Git worktrees must be placed in `.worktrees/`** of the repo root.
- **Clean up feature branches and worktrees after the PR closes.**
  - **Recommended:** use `Cleanup-Worktree.ps1`:
    ```powershell
    ../../Cleanup-Worktree.ps1                           # From worktree (auto-detect)
    ./Cleanup-Worktree.ps1 -Branch <branch-name>         # From repo root
    ./Cleanup-Worktree.ps1 -Sweep                        # Also prune stale refs
    ```
  - Manual fallback: unlock worktree, remove it, prune, checkout main, pull, delete branch.

## Concurrent Session Safety

- **All commits must come from a worktree** -- pre-commit hook blocks repo-root commits.
- **One worktree per issue** -- prevents two sessions from colliding.
- **Lock worktrees after creation** (`git worktree lock`).
- **Unlock before removal** (`git worktree unlock`).
- **`--no-verify` escape hatch** -- only for exceptional circumstances.

## Plan Tracking

Every feature must be tracked as a **GitHub issue** through the full lifecycle:

- **Brainstorm (Phase 0) is owned by the `@plan` agent.** `@dev-loop`
  delegates the design dialogue to `@plan`, which creates the GitHub issue.
  If a design issue already exists, Phase 0 is skipped.
- **Update the issue with the implementation plan (Phase 2).**
- **Link the PR to the issue** with `Closes #<issue-number>`.

## Autopilot Usage

- **When autopilot mode is used to implement a plan, always use the Dev Loop
  agent (`@dev-loop`).** Never skip the full quality cycle for plan work.

## PR & Issue Body Formatting

When writing PR descriptions, issue bodies, or review comments through the CLI
(`gh pr create`, `gh pr edit`, `gh issue create`), **always use `--body-file`**
instead of inline `--body "..."`. Two problems occur with inline bodies:

1. **Collapsed newlines** -- the shell strips line breaks from multiline strings.
2. **CP437 mojibake** -- on Windows, the `gh` CLI garbles Unicode through the OEM codepage.

### Never Read-Modify-Write PR Bodies on Windows

**Never** capture `gh pr view --json body --jq '.body'` into a PowerShell variable
and re-interpolate it. PowerShell destroys newlines. Always construct the complete
body from scratch and write it to a file.

### Required Workflow

```powershell
# Build the COMPLETE body from scratch (never read-modify-write)
$body = @"
## Summary

<description of changes>

Closes #<issue-number>
"@

# Write body to a temp file with explicit UTF-8 (no BOM)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$PWD/pr-body.tmp", $body, $utf8NoBom)

# Pass via --body-file
gh pr create --title "feat: ..." --body-file pr-body.tmp

# Clean up
Remove-Item pr-body.tmp
```

**ASCII replacements** for common Unicode characters:

| Instead of | Use |
|---|---|
| em dash | ` -- ` |
| en dash | `-` |
| arrow | `->` |
| smart quotes | `'` or `"` |
| `<=` `>=` symbols | `<=` `>=` |

## Commit Messages

Follow Conventional Commits: `type(scope): description`

Types: `feat`, `fix`, `test`, `refactor`, `docs`, `chore`.

## Skills & Agents

### Skills (`.github/skills/`)

Reusable process definitions invoked on demand. Skills enforce methodology and discipline.

| Skill | Purpose |
|---|---|
| `behavior-first-testing` | Red -> Green -> Refactor cycle with anti-collusion guardrails and a spike clause |
| `refactor-workflow` | Eliminate duplication after each green step -- YAGNI, simplicity first |
| `functional-testing` | Generate & maintain functional / E2E tests -- explore first, verify before completion |
| `evidence-capture` | Produce a runtime artifact for every change + AI review loop verifying it visibly matches the issue intent (max 3 iterations, then escalate) |
| `code-review-workflow` | Independent review by severity + direct fixes. Use different model for fresh perspective |
| `systematic-debugging` | 4-phase root cause investigation -- no fixes without understanding |
| `dev-loop-phase-gate` | Verify phase completion before proceeding -- quality gate enforcement |
| `security-review` | Scan code for vulnerabilities, exposed secrets, and insecure dependencies (vendored from [github/awesome-copilot](https://github.com/github/awesome-copilot)) |
| `api-wrapper-scaffold` | Generate a complete .NET API-wrapper project from a target website -- Playwright HAR capture, scrub, codegen for typed client + PowerShell module + MCP server + tests |

### Agents (`.github/agents/`)

Orchestrators and interactive workflows with specific tooling and model requirements.

| Agent | Purpose |
|---|---|
| `dev-loop.agent.md` | Orchestrator: Brainstorm+Issue -> Worktree -> Plan -> [TDD -> Refactor -> Functional Test -> Evidence+Verify -> Code Review+Fix -> PR+Copilot Review+Dry Run]* -> Merge -> Cleanup |
| `plan.agent.md` | Design and planning -- Socratic questioning, approach trade-offs, GitHub issue creation |
| `code-review.agent.md` | Code review agent running on `gpt-4.1` for independent perspective |
| `instructions.agent.md` | Maintain instruction files and tooling config across platforms |
| `prd.agent.md` | Generate Product Requirements Documents with user stories and acceptance criteria |
| `api-wrapper-scaffold.agent.md` | Thin agent stub that invokes the `api-wrapper-scaffold` skill for HAR-driven .NET wrapper generation |

### Development Workflow

Use `@dev-loop` to drive the full quality cycle. It coordinates skills in order.
Phases 3-7 use an expanding loop -- each phase is a quality gate, failure routes
back to Phase 3 (TDD).

```
Brainstorm+Issue -> Worktree -> Plan -> [TDD -> Refactor -> Functional Test -> Evidence+Verify -> Code Review+Fix -> PR+Copilot Review+Dry Run]* -> Merge -> Cleanup
```

#### CI Failure Restart Loop

After pushing to a PR branch, if CI fails: investigate, fix locally, push again.
A PR must **never** be merged while CI is red.

#### Merge Step

Once the expanding loop exits cleanly (CI green, all review threads resolved,
latest Copilot review introduced zero new threads, dry run passes if applicable),
merge the PR before running Cleanup. **This repo only allows rebase merges:**

```powershell
gh pr merge <pr-number> --rebase --delete-branch
```

Never merge while CI is red. Never merge with unresolved review threads. If any
post-merge check fails, route back to Phase 3 (TDD) on a new branch.

Use `@plan` when exploring a new idea before committing to implementation.
Use `@systematic-debugging` (or the `systematic-debugging` skill) for bugs.
Use `@instructions` for changes to instruction files or platform config.

#### `bg:` Background Task Shorthand

When a user message is prefixed with `bg:` (case-insensitive), launch a background
Dev Loop agent for that work and return control immediately.

#### Agent Output Linking

In all agent summaries, **always use full GitHub links** for PR numbers, issue numbers,
and branch names -- never plain-text references like `#131`.

| Reference type | Format |
|---|---|
| Pull request | `[#131](https://github.com/<owner>/<repo>/pull/131)` |
| Issue | `[#60](https://github.com/<owner>/<repo>/issues/60)` |
| Branch | `` [`feat/126-name`](https://github.com/<owner>/<repo>/tree/feat/126-name) `` |

##### Task Complete Summary Format

Every `task_complete` summary must include the following fields whenever the
underlying data exists. Omit a field only when it does not apply to the work
just performed (e.g., a Q&A turn with no PR).

| Field | Required format |
|---|---|
| **PR** | Full link: `[#NNN](https://github.com/<owner>/<repo>/pull/NNN)` |
| **Issue** | Full link: `[#NNN](https://github.com/<owner>/<repo>/issues/NNN)` |
| **Branch** | Linked code span: `` [`<branch-name>`](https://github.com/<owner>/<repo>/tree/<branch-name>) `` |
| **Command to test** | Exact shell command(s) the user can run locally to verify, fenced as a code block |
| **Evidence** | Link to the PR comment containing the captured runtime artifact, or to the CI-artifact URL for files larger than 25 MB. Required when Phase 5b ran (i.e. whenever the change has observable effects). |

Place these near the top of the summary so they are immediately scannable.
The command-to-test field is the project's actual verification command (e.g.,
`dotnet test`, `npm test`, `Invoke-Pester -Path .\...`). When multiple commands
are needed, list them in the order they should be run.

The Evidence field links to the artifact produced by the evidence-capture skill
(Phase 5b). See `.github/skills/evidence-capture/SKILL.md` for the artifact
formats and `Publish-Evidence.ps1` for the upload helper.

Example:

```markdown
- **Issue**: [#42](https://github.com/owner/repo/issues/42)
- **PR**: [#57](https://github.com/owner/repo/pull/57) (merged)
- **Branch**: [`feat/42-user-auth`](https://github.com/owner/repo/tree/feat/42-user-auth)
- **Test**: `dotnet test --no-build`
- **Evidence**: [PR comment](https://github.com/owner/repo/pull/57#issuecomment-1234567)
```

##### PR Summary Formatting

When listing multiple PRs, use a **numbered list format** (not a table):

```
N. [`#NNN`](pr-url) . `branch-name` . `CI-result` . Result text
```
