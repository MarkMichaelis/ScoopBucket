---
name: dev-loop-phase-gate
description: "Verify that each dev loop phase completed correctly before proceeding to the next. Use between phases to enforce quality gates -- ensures tests pass, reviews are addressed, and no phases are skipped."
---

# Dev Loop Phase Gate

Verify that the current dev loop phase completed successfully before the orchestrator
proceeds to the next phase. This skill enforces quality gates deterministically.

## Phase Verification Checklist

### After Phase 3 (TDD)

- [ ] At least one new test was added
- [ ] Each new test was observed to fail (RED) before implementation
- [ ] Each test now passes (GREEN)
- [ ] All pre-existing tests still pass
- [ ] Lint/compile passes without errors
- [ ] Changes committed with `test(scope):` and `feat(scope):` messages

**Verify command:**
```bash
# C# / .NET
dotnet build --no-restore && dotnet test --no-build --verbosity normal

# PowerShell
Invoke-Pester -Path tests/ -Output Detailed

# TypeScript
npx tsc && npx vitest run
```

### After Phase 4 (Refactor)

- [ ] All tests still pass (verified by running, not assumed)
- [ ] No new behavior was added
- [ ] Functions are <= 20 lines
- [ ] No obvious duplication remains
- [ ] Lint/compile passes without errors
- [ ] Changes committed with `refactor(scope):` message

### After Phase 5 (Functional Testing)

- [ ] Functional/integration tests exist for user-facing changes
- [ ] All functional tests pass
- [ ] OR: Phase was correctly skipped (all changes are internal/non-user-facing)
- [ ] Lint/compile passes without errors

### After Phase 5b (Evidence and Verify)

- [ ] `.evidence/<phase-id>/` directory exists with a captured artifact
- [ ] `.evidence/<phase-id>/iteration.txt` records the loop iteration count
- [ ] Either `.evidence/<phase-id>/PASSED` or `.evidence/<phase-id>/ESCALATED` exists
- [ ] If `PASSED`: the artifact was uploaded to the PR (or earmarked for upload
      when the PR is opened) via `Publish-Evidence.ps1`
- [ ] The artifact's `HEAD_SHA` matches the current `git rev-parse HEAD` (no
      stale artifacts)
- [ ] The artifact was produced from an actual runtime invocation, not
      hand-edited text
- [ ] The Task Complete Summary will include an Evidence field

### After Phase 6 (Code Review)

- [ ] Static analysis tools ran and are clean
- [ ] All Critical findings are resolved
- [ ] All Important findings are resolved
- [ ] All tests pass after review fixes
- [ ] Review report produced in structured format

### After Phase 7 (PR + Copilot Review)

- [ ] PR created with `Closes #<issue-number>`
- [ ] CI workflows are green
- [ ] All review threads resolved
- [ ] Latest Copilot review introduced zero new threads
- [ ] Dry run passes (if applicable)

## Failure Routing

If any verification fails:

| Failed Gate | Route To |
|---|---|
| Phase 3 (tests fail) | Stay in Phase 3 |
| Phase 4 (tests break) | Back to Phase 3 |
| Phase 5 (functional tests fail) | Back to Phase 3 |
| Phase 5b (AI-review fails, iter < 3) | Stay in Phase 5b -- fix and re-capture |
| Phase 5b (AI-review fails, iter == 3) | Escalate to human; pause autonomous loop |
| Phase 6 (review issues found) | Back to Phase 3 |
| Phase 7 (CI fails or review issues) | Back to Phase 3 |

**Maximum 3 loop iterations.** After 3 rounds with unresolved Critical issues,
escalate to the user.

## Progress Report Template

```markdown
## Dev Loop -- Iteration <N>

**Branch:** `<branch-name>`
**Loop iteration:** <N> of 3 max

| Phase | Status | Notes |
|---|---|---|
| 3 -- TDD | Done/In Progress/Pending | <details> |
| 4 -- Refactor | Done/In Progress/Pending | <details> |
| 5 -- Functional Testing | Done/Skipped/Pending | <details> |
| 6 -- Code Review | Done/In Progress/Pending | <details> |
| 7 -- PR + Review | Done/In Progress/Pending | <details> |

**Next action:** <what happens next>
```
