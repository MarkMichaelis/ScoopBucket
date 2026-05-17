---
name: systematic-debugging
description: "Use when encountering any bug, test failure, or unexpected behavior. Enforces root cause investigation before proposing fixes -- no guessing, no random patches. Language-aware."
---

# Systematic Debugging

Follow a rigorous 4-phase process to find and fix bugs. Random fixes waste time
and create new bugs.

**Detect the project language** from file extensions and project files. Apply the matching
language-specific guidance below. If the language is not listed, infer conventions from
the project's existing code and community standards.

## The Iron Law

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

If you haven't completed Phase 1, you cannot propose fixes.

## When to Use

Use for ANY technical issue:
- Test failures
- Bugs in production
- Unexpected behavior
- Performance problems
- Build failures
- Integration issues

**Use this ESPECIALLY when:**
- Under time pressure (emergencies make guessing tempting)
- "Just one quick fix" seems obvious
- You've already tried multiple fixes
- Previous fix didn't work
- You don't fully understand the issue

## The Four Phases

### Phase 1: Root Cause Investigation

**BEFORE attempting ANY fix:**

1. **Read Error Messages Carefully**
   - Don't skip past errors or warnings
   - They often contain the exact solution
   - Read stack traces completely
   - Note line numbers, file paths, error codes

2. **Reproduce Consistently**
   - Can you trigger it reliably?
   - What are the exact steps?
   - Does it happen every time?
   - If not reproducible -> gather more data, don't guess

3. **Check Recent Changes**
   - What changed that could cause this?
   - `git diff`, recent commits
   - New dependencies, config changes
   - Environmental differences

4. **Trace Data Flow**
   - Where does the bad value originate?
   - What called this with the bad value?
   - Keep tracing up until you find the source
   - Fix at source, not at symptom

5. **Gather Evidence in Multi-Component Systems**
   - For EACH component boundary: log what enters and exits
   - Run once to gather evidence showing WHERE it breaks
   - THEN analyze evidence to identify the failing component
   - THEN investigate that specific component

### Phase 2: Pattern Analysis

1. **Find Working Examples** -- locate similar working code in the same codebase
2. **Compare Against References** -- read the reference implementation COMPLETELY
3. **Identify Differences** -- list every difference, however small
4. **Understand Dependencies** -- what other components, settings, or environment does this need?

### Phase 3: Hypothesis and Testing

1. **Form Single Hypothesis** -- "I think X is the root cause because Y"
2. **Test Minimally** -- make the SMALLEST possible change to test the hypothesis
3. **Verify Before Continuing** -- did it work? Yes -> Phase 4. No -> form NEW hypothesis.
4. **When You Don't Know** -- say "I don't understand X". Don't pretend.

### Phase 4: Implementation

1. **Create Failing Test Case** -- simplest possible reproduction
2. **Implement Single Fix** -- ONE change at a time
3. **Verify Fix** -- test passes? No other tests broken? Run full suite.
4. **If Fix Doesn't Work** -- STOP. Count: how many fixes have you tried?
   - If < 3: Return to Phase 1
   - **If 3 fixes failed: STOP and question the architecture (step 5)**
5. **If 3 Fixes Failed** -- escalate to architectural discussion with the user.
   Do NOT attempt Fix #4. Document findings in the GitHub issue and pause.

---

## Language-Specific Debugging -- C# / .NET

| Technique | Command |
|---|---|
| **Build errors** | `dotnet build --no-restore` -- read full output |
| **Test failures** | `dotnet test --no-build --verbosity normal` |
| **Verbose test** | `dotnet test --no-build --verbosity detailed --filter "FullyQualifiedName~<TestName>"` |
| **Format check** | `dotnet format --verify-no-changes` |

## Language-Specific Debugging -- PowerShell

| Technique | Command |
|---|---|
| **Verbose output** | Run with `-Verbose` |
| **Error details** | Inspect `$Error[0]`, `$Error[0].Exception`, `$Error[0].ScriptStackTrace` |
| **Module reload** | Always `Import-Module ... -Force` after changes |
| **Pester output** | `Invoke-Pester -Output Diagnostic` |

## Language-Specific Debugging -- TypeScript

| Technique | Command |
|---|---|
| **Type errors** | `npx tsc --noEmit` |
| **Vitest debug** | `npx vitest run --reporter=verbose <file>` |
| **Playwright trace** | `npx playwright test --trace on` |

---

## Red Flags -- STOP and Follow Process

If you catch yourself thinking:
- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "Add multiple changes, run tests"
- "It's probably X, let me fix that"
- "One more fix attempt" (when already tried 3)

**ALL of these mean: STOP. Return to Phase 1.**

## Quick Reference

| Phase | Key Activities | Success Criteria |
|-------|---------------|------------------|
| **1. Root Cause** | Read errors, reproduce, check changes, gather evidence | Understand WHAT and WHY |
| **2. Pattern** | Find working examples, compare | Identify differences |
| **3. Hypothesis** | Form theory, test minimally | Confirmed or new hypothesis |
| **4. Implementation** | Create test, fix, verify | Bug resolved, tests pass |
