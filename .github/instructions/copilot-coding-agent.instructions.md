---
description: 'Guidelines for the GitHub Copilot coding agent running autonomously in the cloud'
applyTo: '**/*'
---

# GitHub Copilot Coding Agent — Repository Guide

> These instructions are for the GitHub Copilot coding agent running autonomously in the cloud.
> Read this file alongside `CLAUDE.md` and `.github/copilot-instructions.md` for full project context.

## 1. Environment

- **Runner**: Ubuntu Linux (GitHub Actions `ubuntu-latest`)
- **Shell**: bash
- **.NET**: 10.x (pre-installed via `copilot-setup-steps.yml`)
- **Node.js**: 20.x (pre-installed via `copilot-setup-steps.yml`)
- **Dependencies**: `dotnet restore` and `npm ci` are run during setup — do not re-run them unless necessary

## 2. Key References

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Repository orientation: structure, branching, workflow, essential commands |
| `.github/copilot-instructions.md` | Full coding conventions, style rules, testing practices |

## 3. Build & Verify Commands

Run these commands after **every** code change, in order:

```bash
# Discover solution file
SLN=$(find . -maxdepth 1 -name '*.sln' -o -name '*.slnx' | head -1)

# Format (must produce no changes)
dotnet format "$SLN"

# Build
dotnet build "$SLN" --no-restore

# Test
dotnet test "$SLN" --no-build --verbosity normal
```

Fix all format violations and test failures before committing. Never commit with failing tests or format errors.

## 4. Workflow

1. **Read the issue** — understand the acceptance criteria and implementation checklist fully before writing any code.
2. **TDD** — write a failing test first (Red), then implement the smallest honest code to pass it (Green) without hard-coding test inputs, then refactor (Refactor). See `.github/instructions/tdd.instructions.md`. Exploratory work may use the spike clause (defer test-first, then delete or retro-fit with behavior-first tests before merge).
3. **Implement** — make changes in `src/` and `tests/` only (see Scope Boundaries below).
4. **Format** — run `dotnet format` and fix any violations.
5. **Commit** — use [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): description`.
6. **PR** — open a pull request with `Closes #<issue-number>` in the description so the issue is auto-closed on merge.

## 5. Testing Expectations

- **Framework**: xUnit + Moq + FluentAssertions
- **Location**: `tests/unit/` (mirror `src/` structure)
- **Pattern**: Arrange / Act / Assert in every test method
- **Naming**: `MethodName_Scenario_ExpectedBehavior`
- **Isolation**: mock external dependencies with Moq; use real code paths for unit logic
- **Fixtures**: deterministic test data lives in `tests/fixtures/` or a `Fixtures/` subdirectory

## 6. Quality Bar

All of the following must be true before opening a PR:

- All tests pass (`dotnet test --no-build --verbosity normal`)
- No format violations (`dotnet format --verify-no-changes`)
- XML documentation comments (`/// <summary>`) on every public type and member
- Methods <= 20 lines; single-purpose functions
- Nullable reference types enabled (`#nullable enable`) in all new files
- No new warnings introduced
- PR body uses ASCII-only text (no em dashes, smart quotes, arrows -- see `copilot-instructions.md`)

## 7. Scope Boundaries

| Directory | Action |
|-----------|--------|
| `src/` | ✅ Production source code — primary work area |
| `tests/` | ✅ Tests — always update alongside production code |
| `.github/workflows/` | ❌ Do not modify CI/CD workflows |
| `node_modules/` | ❌ Do not modify; managed by package manager |

## 8. What NOT to Do

- **Don't modify `.github/workflows/`** — CI/CD workflows are managed separately and changes can break the pipeline
- **Don't add NuGet packages** without explicit justification in the issue; prefer existing dependencies
- **Don't skip tests** — every new behavior must have a corresponding test; never commit with failing tests
- **Don't commit secrets** — no API keys, credentials, or tokens in source code
- **Don't run `dotnet restore`** during development unless package references change — dependencies are pre-installed in the runner environment
- **Don't use `throw ex;`** inside catch blocks — use `throw;` to preserve the call stack
