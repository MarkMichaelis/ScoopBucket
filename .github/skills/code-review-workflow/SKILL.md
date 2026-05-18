---
name: code-review-workflow
description: "Review and fix production and test code. Runs static analysis, reviews by severity (Critical/Important/Suggestions), and directly applies fixes. Use a different model than the authoring agent for independent perspective. Language-aware."
---

# Code Review Workflow

You are performing an independent code review. Run on a **different model** from the one
that wrote the code when possible, providing a fresh perspective and catching blind spots.

**Detect the project language** from file extensions and project files. Apply the matching
language-specific guidance below. If the language is not listed, infer conventions from
the project's existing code and community standards.

## Core Principle

**Review early, review often.** Issues caught now are 10x cheaper than issues caught later.

## Mission

1. **Review** -- Thoroughly analyse the latest changes in production code and test code.
2. **Report** -- Produce a structured review with categorised findings by severity.
3. **Fix** -- Apply fixes for all Critical and Important findings directly. Make the code
   changes, run tests, and verify the fixes work. Do not just report -- resolve.
4. **Hand off** -- Present the final review report showing what was found and what was fixed.
   Any remaining Suggestions that were not applied should be listed for the orchestrator.

## When to Review

**Mandatory:**
- After each task in the development loop.
- After completing a major feature.
- Before merge to main.

**Optional but valuable:**
- When stuck (fresh perspective).
- Before refactoring (baseline check).
- After fixing a complex bug.

## Review Scope

### Step 0: Run Static Analysis First

Before any AI review, run **all** available static analysis tools and fix findings:

**C# / .NET:**
```bash
dotnet format
dotnet build --no-restore
```

**PowerShell:**
```powershell
Invoke-ScriptAnalyzer -Path src/ -Recurse -Severity Warning
```

**TypeScript:**
```bash
npm run type-check
npm run lint
```

Fix all static analysis findings before proceeding to the AI review below.

### Get Changed Files

```bash
git diff --name-only origin/main...HEAD
```

### Correctness

- Logic errors, off-by-one mistakes, incorrect conditions.
- Missing error handling or unhandled edge cases.
- Incorrect or loose typing (where the language supports types).
- Edge cases not covered by existing tests.
- **Lint/compile verification** -- run the project's lint and compile tools and report any errors as Critical findings.

### Code Quality

- Functions exceeding 20 lines or doing more than one thing.
- Duplicated logic that should be extracted.
- Poor naming -- variables, functions, or files that don't reveal intent.
- Unused imports, dead code, commented-out blocks.
- Inconsistent patterns across the codebase.
- **YAGNI violations** -- features or abstractions not required by current tests.

### Test Quality

- Tests that don't assert meaningful behavior.
- Missing tests for error paths, boundary conditions, or edge cases.
- Brittle tests coupled to implementation details.
- **Tests that use mocks when real code is feasible** -- mocks should be last resort.
- Test descriptions that don't match what is actually being tested.
- **Test compliance** -- assess behavior-first testing by checking: (a) a test ships with each behavior change in the same commit / PR, (b) tests assert observable behavior rather than mirroring implementation, (c) the production change, when mentally reverted, would cause the test to fail with an *assertion* failure (not a compile/import error), (d) implementations do not hard-code the literal values used in the test (collusion), (e) test names follow `MethodName_Scenario_ExpectedBehavior` convention and use Arrange/Act/Assert. *Limitation:* test-first ordering cannot be verified from a diff alone -- only co-presence, structure, and collusion signals can be assessed.

### Security & Performance

- User input not being validated or sanitised.
- Secrets or API keys hard-coded in source.
- Unnecessary network calls, API calls, or expensive operations.
- Missing error boundaries or graceful degradation.

---

## Language-Specific Review -- C# / .NET

| Check | Detail |
|---|---|
| **Naming conventions** | PascalCase for public members, camelCase for locals/params, `_camelCase` for private fields. |
| **XML docs** | Every public type and member has `/// <summary>` documentation. |
| **Nullable reference types** | `#nullable enable` in new files; no unguarded nullable dereferences. |
| **Async/await** | Async methods use `Async` suffix. No `.Result` or `.Wait()` on tasks. |
| **Dependency injection** | No `new` of services in production code; use constructor injection. |
| **Build** | `dotnet build --no-restore` completes without errors or warnings. |
| **Tests** | `dotnet test --no-build --verbosity normal` passes. |
| **Format** | `dotnet format` fixes formatting; verify with `dotnet format --verify-no-changes`. |

## Language-Specific Review -- PowerShell

| Check | Detail |
|---|---|
| **Approved verbs** | All exported functions use approved verbs (`Get-Verb`). |
| **CmdletBinding** | Every function has `[CmdletBinding()]`. |
| **Comment-based help** | Every exported function has `<# .SYNOPSIS ... #>`. |
| **Parameter validation** | Parameters use `[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, etc. where appropriate. |
| **Error handling** | `-ErrorAction Stop` on critical calls; `try/catch` with informative error messages. |
| **Module loads** | `Import-Module ... -Force -ErrorAction Stop` succeeds. |
| **Pester tests** | `Invoke-Pester -Path tests/ -Output Detailed` passes. |

## Language-Specific Review -- TypeScript

| Check | Detail |
|---|---|
| **Type safety** | No unnecessary `any`; proper interfaces and generics used. |
| **Compilation** | `npm run type-check` completes without errors. |
| **JSDoc** | Every public function has a JSDoc comment. |
| **ES modules** | Uses `import`/`export`, not `require`/`module.exports`. |
| **Vitest** | `npx vitest run` passes. |
| **Playwright** | `npx playwright test` passes (if E2E tests exist). |

## Language-Specific Review -- Generic (Any Language)

1. **Run the project's lint tool** and report any issues.
2. **Run the project's test suite** and report any failures.
3. **Check naming conventions** match the language's community standards.
4. **Verify documentation comments** exist on public APIs.
5. **Check error handling** follows the language's idiomatic patterns.

---

## Review Output Format

```markdown
## Code Review Summary

**Files reviewed:** <list of files>
**Overall assessment:** PASS | NEEDS CHANGES | CRITICAL ISSUES
**Static analysis:** Clean / <N> findings fixed

### Critical (must fix -- blocks progress)
- [x] `src/path/file.ext:L42` -- Description. **Fixed:** <what was changed>.
- [ ] `src/path/file.ext:L55` -- Description. **Not fixed:** <reason>.

### Important (should fix before proceeding)
- [x] `src/path/file.ext:L18` -- Description. **Fixed:** <what was changed>.

### Suggestions (nice to have)
- [x] `tests/path/file.ext:L7` -- Description. **Applied.**
- [ ] `tests/path/file.ext:L22` -- Description. Not applied (low priority).
- **Deferred:** `src/path/file.ext:L90` -- Description. *Reason: requires design decision.*

### Positive Observations
- Highlight things done well to reinforce good patterns.
```

## Severity Handling

| Severity | Action Required |
|----------|----------------|
| **Critical** | Blocks progress. Must fix immediately before any further work. |
| **Important** | Must fix before proceeding to next task. |
| **Suggestions** | Note for later. Apply if low-effort and high-value. |

## Execution Guidelines

1. **Run static analysis tools first** -- fix all formatting, linting, and compiler warnings before starting the AI review.
2. **Read the changed files** -- Examine all recently changed or newly created files.
3. **Understand the context** -- Read related files to understand how the changes fit into the broader codebase.
4. **Run the test suite** -- Verify all tests pass before reviewing. Report test failures as Critical.
5. **Perform the review** -- Apply each review category systematically.
6. **Fix Critical and Important findings directly** -- Make the code changes yourself. Run tests after each fix to verify correctness.
7. **Apply low-effort Suggestions** -- Fix suggestions that are quick wins. **Low-effort** means: changes that can be made in under 5 minutes with no design decisions -- renaming, adding missing null checks, fixing typos, adding missing XML docs, extracting a method of <= 10 lines. Anything requiring design choices or touching > 3 files is NOT low-effort.
8. **Run the full test suite after all fixes** -- All tests must pass.
9. **Run static analysis again** -- Verify everything is still clean after fixes.
10. **Produce the final report** -- Output the structured review showing what was found, what was fixed, and any remaining suggestions.

## Red Flags

**Never:**
- Skip review because "it's simple".
- Ignore Critical issues.
- Proceed with unfixed Important issues.
- Argue with valid technical feedback without evidence.

**If reviewer is wrong:**
- Push back with technical reasoning.
- Show code/tests that prove it works.
- Request clarification.

## Review Checklist

- [ ] Static analysis tools run and findings fixed.
- [ ] All changed files examined.
- [ ] Lint/compile runs without errors.
- [ ] Tests run and results noted.
- [ ] Correctness issues identified and fixed.
- [ ] Code quality issues identified and fixed.
- [ ] Test quality issues identified and fixed.
- [ ] Security concerns flagged and fixed.
- [ ] YAGNI compliance verified.
- [ ] All tests pass after fixes.
- [ ] Static analysis re-run and clean after fixes.
- [ ] Review report produced in structured format with fix status.
