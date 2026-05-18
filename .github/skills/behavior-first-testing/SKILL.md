---
name: behavior-first-testing
description: "Drive feature development with behavior-first tests via the Red -> Green -> Refactor cycle. Every behavior change ships with a test that fails for a behavioral reason when reverted. Spike clause permits deferred test-first for exploration if retro-fitted before merge. Language-aware: C#/xUnit, PowerShell/Pester, TypeScript/Vitest, and generic support."
---

# Behavior-First Testing Workflow

Guide every feature through behavior-first testing, normally via the classic
Red-Green-Refactor cycle: write a failing test, make it pass with the smallest
honest implementation, then refactor.

**Detect the project language** from file extensions and project files. Apply the matching
language-specific guidance below. If the language is not listed, infer the test framework
and conventions from the project's existing code and community standards.

## The Two-Part Rule

Every behavior change must satisfy **both** of these:

1. **A test ships with the change.** No production behavior change without a
   corresponding test in the same commit (or earlier in the same PR).
2. **The test must fail for a behavioral reason when the change is reverted.**
   That means an assertion failure -- not a compile error, not an import
   error, not a missing-symbol error.

Wrote code without satisfying both? Two recovery paths:

- **Default**: delete the production code, write the failing test first,
  re-implement with the smallest honest implementation.
- **Spike (see "When test-first does not apply" below)**: retro-fit
  behavior-first tests that satisfy the two-part rule before merge.

Sunk-cost feelings about already-written code are not a reason to weaken
the rule.

## When to Use

**Always (default test-first):**
- New features
- Bug fixes (write a failing test that reproduces the bug first)
- Refactoring (ensure tests cover the behavior before changing code)
- Behavior changes

**When test-first does not apply (spike clause):**

Test-first may be deferred for **exploratory spikes** -- short investigations
whose goal is to discover the right shape of an API or algorithm. Before the
spike merges:

- Either **delete** the spike and re-implement test-first, **or**
- **Retro-fit** behavior-first tests that satisfy the two-part rule above.

Spike code never reaches `main` untested. Mark spikes visibly while in
progress (draft PR, branch name, or commit message) so reviewers do not
mistake them for finished work. If a spike outgrows its question, stop and
re-plan -- do not let undeclared spike work accumulate.

This is the *only* sanctioned exception. "I'll test after", "too simple
to test", and "already manually tested" are not spikes -- they are
rationalizations. See the table below.

## Red-Green-Refactor Cycle

### 1. RED -- Write a Failing Test

- **Before writing any production code**, create or update a unit test.
- Place tests in the project's test directory mirroring the source tree.
- Each test must:
  - Have a clear, descriptive name describing the expected behavior.
  - Assert **one logical behavior** per test case.
    > One logical behavior may require multiple assertions when they collectively verify a single outcome. For example, testing that a method returns a correctly populated object may assert multiple properties -- this is one behavior (correct object creation). However, testing that a method returns the right object AND logs the right message is two behaviors and should be two tests.
  - Group related behaviors together (e.g., nested classes in xUnit, `Describe`/`Context` blocks in Pester, `describe` in Vitest).
  - **Prefer real implementations over mocks.** Use mocks only when the real dependency is impractical in tests: network calls, file system operations with side effects, or time-dependent behavior. When mocking, verify the interaction contract, not implementation details.

| Quality | Good | Bad |
|---------|------|-----|
| **Minimal** | Tests one thing. "and" in name? Split it. | `It 'validates email and domain and whitespace'` |
| **Clear** | Name describes behavior | `It 'test1'` |
| **Shows intent** | Demonstrates desired API | Obscures what code should do |

### Verify RED -- Watch It Fail (MANDATORY)

Run the project's lint/compile step, then run the test to **confirm it fails**.

Confirm:
- Test **fails** (not errors due to typos or syntax)
- Failure message is expected
- Fails because the **feature is missing**, not because of setup issues

**Test passes immediately?** You're testing existing behavior. Fix the test.
**Test errors instead of failing?** Fix the error, re-run until it fails correctly.

### 2. GREEN -- Smallest Honest Implementation

- Write the smallest code that **genuinely implements** the behavior under test.
- Do **not** hard-code test inputs (e.g., `if input == "foo" return "bar"`)
  just to make the assertion pass. Such code does not implement the behavior;
  it colludes with the test. If the implementation only works for the literal
  values in the test, either add a second test that forces a real
  implementation, or write the real implementation now.
- **Stay in scope** -- implement only what the current test (and honest
  generalization of that behavior) requires.
- Do **not** add unrelated features, optimizations, or abstractions yet.

Don't add features, refactor other code, or "improve" beyond the test.

### Verify GREEN -- Watch It Pass (MANDATORY)

Run lint/compile, then re-run the test.

Confirm:
- Test **passes**
- **All other tests** still pass
- Output is pristine (no errors, warnings)

**Test fails?** Fix code, not the test.
**Other tests fail?** Fix them now -- never leave the suite red.

### 3. REFACTOR -- Clean Up

After green and **only after green**:
- Remove duplication
- Improve names
- Extract helpers
- Reduce nesting

Run the **full test suite** to ensure nothing is broken. Keep all tests green.
**Do not add behavior during refactoring.**

### 4. Repeat

Next failing test for next behavior.

---

## Language-Specific Guidance -- C# / .NET (xUnit)

### Test Location & Naming

- Place tests in `tests/unit/` mirroring the source tree.
- Example: `src/<ProjectName>/Services/FooService.cs` ->
  `tests/unit/Services/FooServiceTests.cs`.
- File naming: `<ClassName>Tests.cs`.
- Method naming: `MethodName_Scenario_ExpectedBehavior`.

### RED -- Run & Verify Failure

```bash
dotnet build --no-restore
dotnet test --no-build --verbosity normal --filter "FullyQualifiedName~<TestClassName>"
```

### GREEN -- Run & Verify Pass

```bash
dotnet build --no-restore
dotnet test --no-build --verbosity normal --filter "FullyQualifiedName~<TestClassName>"
```

### REFACTOR -- Full Suite

```bash
dotnet build --no-restore
dotnet test --no-build --verbosity normal
dotnet format --verify-no-changes
```

### Test File Template -- C#

```csharp
using Xunit;
using Moq;
using FluentAssertions;

namespace MyProject.Tests.Unit.Services;

public class CalculatorServiceTests
{
    [Fact]
    public void Add_WithTwoPositiveNumbers_ReturnsSum()
    {
        // Arrange
        var calculator = new CalculatorService();

        // Act
        var result = calculator.Add(2, 3);

        // Assert
        result.Should().Be(5);
    }

    [Fact]
    public void Divide_ByZero_ThrowsDivideByZeroException()
    {
        // Arrange
        var calculator = new CalculatorService();

        // Act
        var act = () => calculator.Divide(10, 0);

        // Assert
        act.Should().Throw<DivideByZeroException>();
    }
}
```

> **Namespace convention:** Test namespace mirrors source namespace with `.Tests.Unit` inserted:
> `MyProject.Services.CalculatorService` -> `MyProject.Tests.Unit.Services.CalculatorServiceTests`.

### Rules -- C#

| Rule | Detail |
|---|---|
| **Mock sparingly** | Prefer real implementations over mocks. Use Moq only when the real dependency is impractical: network calls, file system operations with side effects, or time-dependent behavior. Verify interaction contracts, not implementation details. |
| **Isolation** | Each `[Fact]` or `[Theory]` must be independent. Use constructor or `IClassFixture<T>` for shared setup. |
| **Compile after every step** | Run `dotnet build --no-restore` after RED, GREEN, and REFACTOR. Fix errors before proceeding. |
| **Format check** | Run `dotnet format --verify-no-changes` to ensure consistent style. |
| **Test fixtures** | Use saved data files in `tests/fixtures/` for deterministic tests when appropriate. |

### Async Testing -- C#

For async methods, use `async Task` test methods (not `async void`). Use `await` directly -- do not use `.Result` or `.Wait()` which can deadlock. Test cancellation by passing `CancellationToken` with a short timeout.

---

## Language-Specific Guidance -- PowerShell (Pester)

### Test Location & Naming

- Place tests in `tests/unit/` mirroring the source tree.
- File naming: `<FunctionName>.Tests.ps1`.

### RED -- Run & Verify Failure

```powershell
Invoke-ScriptAnalyzer -Path src/ -Recurse -Severity Warning
Invoke-Pester -Path tests/unit/<TestFile>.Tests.ps1 -Output Detailed
```

### GREEN -- Run & Verify Pass

```powershell
Invoke-ScriptAnalyzer -Path src/ -Recurse -Severity Warning
Invoke-Pester -Path tests/unit/<TestFile>.Tests.ps1 -Output Detailed
```

### REFACTOR -- Full Suite

```powershell
Invoke-ScriptAnalyzer -Path src/ -Recurse -Severity Warning
Invoke-Pester -Path tests/ -Output Detailed
```

### Rules -- PowerShell

| Rule | Detail |
|---|---|
| **Mock sparingly** | Prefer real implementations. Use Pester `Mock` only when the real dependency is impractical: network calls, external APIs, file system side effects, or time-dependent behavior. Verify interaction contracts, not implementation details. |
| **Isolation** | Each `It` block must be independent. Use `BeforeEach` for per-test setup. |
| **Lint after every step** | Run `Invoke-ScriptAnalyzer` after RED, GREEN, and REFACTOR. Fix warnings before proceeding. |
| **Module reload** | Always `Import-Module ... -Force` before running tests to pick up changes. If the module import fails (e.g., module not found), check that the module path is correct and the module has been built. Run `dotnet build` or the appropriate build command before importing. |

---

## Language-Specific Guidance -- TypeScript (Vitest)

### Test Location & Naming

- Place tests in `tests/unit/` mirroring the source tree.
- Example: `src/services/auth.ts` -> `tests/unit/services/auth.test.ts`.
- File naming: `<module>.test.ts`.

### RED -- Run & Verify Failure

```bash
npx tsc
npx vitest run --reporter=verbose <path-to-test-file>
```

### GREEN -- Run & Verify Pass

```bash
npx tsc
npx vitest run --reporter=verbose <path-to-test-file>
```

### REFACTOR -- Full Suite

```bash
npx tsc
npx vitest run
```

### Rules -- TypeScript

| Rule | Detail |
|---|---|
| **Real code over mocks** | Prefer real implementations. Use `vi.mock()` or `vi.fn()` only when the real dependency is impractical: network calls, browser APIs, third-party SDKs, or time-dependent behavior. Verify interaction contracts, not implementation details. |
| **TypeScript first** | All new source and test files must be `.ts`. Never hand-write `.js` files. |
| **Compile after every step** | Run `npx tsc` after every RED, GREEN, and REFACTOR step. |

### Async Testing -- TypeScript

For async functions, use `async/await` in test bodies. Mock async dependencies with `vi.fn().mockResolvedValue()` or `vi.fn().mockRejectedValue()`. Test error paths with `await expect(fn()).rejects.toThrow()`.

---

## Language-Specific Guidance -- Generic (Any Language)

If the project uses a language not listed above:

1. **Detect the test framework** from project files (e.g., `pytest.ini`, `go.mod`, `Cargo.toml`, `pom.xml`).
2. **Mirror the source tree** for test file placement.
3. **Run the lint/compile step** after every RED, GREEN, and REFACTOR step using the project's established tooling.
4. **Run the test suite** using the project's established test runner.
5. **Follow the project's existing test naming conventions.**

---

## Rules (All Languages)

| Rule | Detail |
|---|---|
| **No production behavior change without a test** | Every new function, class, or module must ship with a test. The test must fail for a behavioral reason (assertion failure) when the production change is reverted. |
| **One behavior per cycle** | Do not batch multiple behaviors into a single RED->GREEN pass. |
| **Smallest honest implementation** | Write the smallest code that genuinely implements the behavior. Do not hard-code test inputs. |
| **Smallest step possible** | Prefer many small cycles over a few large ones. |
| **Tests are first-class code** | Apply the same quality standards (naming, no duplication, documentation) to test files. |
| **Real code over mocks** | Prefer real implementations over mocks. Use mocks only when the real dependency is impractical: network calls, external APIs, file system side effects, or time-dependent behavior. Verify interaction contracts, not implementation details. |
| **Preserve isolation** | Each test must be independent -- no shared mutable state between tests. |
| **Lint/compile after every step** | Run the project's lint and/or compile command after every RED, GREEN, and REFACTOR step. Fix errors before proceeding. |

## Test Quality (F.I.R.S.T.)

Behavior-first tests should be:

- **Fast** -- Tests should run quickly so the feedback loop stays tight.
- **Independent** -- Tests must not depend on each other or share mutable state.
- **Repeatable** -- Same inputs produce the same result every time, in any environment.
- **Self-validating** -- Pass/fail is unambiguous; no manual inspection of output required.
- **Timely** -- Written before (or alongside) the production change, per the two-part rule.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Too simple to test" | Simple code breaks. Test takes 30 seconds. |
| "I'll test after" | Tests passing immediately prove nothing. Not a spike -- spikes are explicitly scoped exploration that retro-fit tests before merge. |
| "Tests after achieve same goals" | Tests-after = "what does this do?" Tests-first = "what should this do?" |
| "Already manually tested" | Ad-hoc != systematic. No record, can't re-run. |
| "Deleting X hours is wasteful" | Sunk cost fallacy. Keeping unverified code is technical debt. |
| "Keep as reference, write tests first" | You'll adapt it. That's testing after. Delete means delete -- unless this is an explicit spike that will be retro-fitted with behavior-first tests before merge. |
| "Need to explore first" | Fine -- declare it a spike. Spike code must be deleted or retro-fitted with behavior-first tests before merge. |
| "Test hard = design unclear" | Listen to test. Hard to test = hard to use. |
| "TDD will slow me down" | TDD is faster than debugging. |

## Anti-collusion checklist

Run this checklist on every behavior change before considering the cycle
complete. Any "no" answer is a defect to fix, not a tradeoff to accept.

- [ ] **Behavioral failure on revert.** With the production change reverted,
      does the test fail with an *assertion* failure (not a compile error,
      not an import error, not a missing-symbol error)?
- [ ] **No hard-coded test inputs.** Does the implementation generalize, or
      does it only return the literal values used in the test? If only the
      literals work, add a second test or generalize the implementation now.
- [ ] **Behavior, not structure.** Does the test assert observable
      outcomes -- return values, side effects on real collaborators,
      externally visible state -- rather than internal call sequences or
      private structure?
- [ ] **Independent of implementation choice.** Would the test still be
      valid if a reasonable alternative implementation were substituted?
      If the test only passes for one specific implementation shape, it is
      mirroring the code instead of verifying behavior.
- [ ] **Spike retro-fit complete.** If any code in this change started as
      a spike, has it been either deleted or retro-fitted with tests that
      satisfy every other box on this list?

## Red Flags -- STOP and Recover

If you catch yourself doing any of these, stop. Either restart with
behavior-first testing, or -- if the work is genuinely exploratory --
declare it a spike and plan how it will be retro-fitted before merge:

- Writing code before the test (without a declared spike)
- Writing the test after implementation and never observing it fail
- Test passes immediately (without writing production code)
- Can't explain why the test failed
- Tests added "later" without a spike retro-fit plan
- Rationalizing "just this once"
- "I already manually tested it"
- "Keep as reference" or "adapt existing code" without a spike retro-fit plan
- Implementation only returns the literal values from the test (collusion)

## Debugging Integration

Bug found? Write a failing test reproducing it. Follow the cycle. The test
proves the fix and prevents regression.

**Never fix bugs without a test.**

## Verification Checklist

Before marking any cycle complete:

- [ ] Every new function/method has a test
- [ ] Watched each test fail before implementing (or, for spike retro-fit:
      verified the test fails with the production change reverted)
- [ ] Each test failed for a **behavioral** reason (assertion failure),
      not a compile/import/typo error
- [ ] Smallest honest implementation -- no hard-coded test inputs
- [ ] Tests assert observable behavior, not implementation structure
- [ ] All tests pass
- [ ] Output pristine (no errors, warnings)
- [ ] Tests use real code (mocks only if unavoidable)
- [ ] Edge cases and errors covered
- [ ] Lint/compile passes without errors
- [ ] Any spike code in this change has been deleted or retro-fitted

Can't check all boxes? You skipped behavior-first testing. Recover -- either
restart test-first, or treat the work as a spike and retro-fit before merge.

## When Stuck

| Problem | Solution |
|---------|----------|
| Don't know how to test | Write the wished-for API. Write the assertion first. Consider whether the code under test is designed for testability. If a class has too many dependencies or hidden side effects, the difficulty may indicate a design problem. Try: (1) Extract an interface for the dependency. (2) Use constructor injection. (3) Break the method into smaller, independently testable pieces. Ask the user. |
| Test too complicated | Design too complicated. Simplify the interface. |
| Must mock everything | Code too coupled. Use dependency injection. |
| Test setup is huge | Extract helpers. Still complex? Simplify the design. |

## Execution Guidelines

1. **Analyse requirements** -- Break down the feature into testable behaviors.
2. **Write the simplest failing test** -- Start with the most basic scenario. NEVER write multiple tests at once.
3. **Verify the test fails** -- Run the test and confirm it fails for a behavioral reason (assertion failure), not a compile/import error.
4. **Smallest honest implementation** -- Add just enough real code to make the test pass. Do not hard-code test inputs.
5. **Run all tests** -- Ensure new code doesn't break existing functionality.
6. **Refactor** -- Clean up while keeping all tests green.
7. **Repeat** -- Move to the next behavior.

For exploratory work where the right shape of the API or algorithm is not yet
clear, declare a **spike** (draft PR, branch name, or commit message marker).
Spike code must be deleted or retro-fitted with behavior-first tests that
satisfy the two-part rule before merge.

## Checklist (per cycle)

- [ ] Test written and fails for a behavioral reason (RED).
- [ ] Smallest honest implementation written and test passes (GREEN).
- [ ] Code refactored with all tests still passing (REFACTOR).
- [ ] Anti-collusion checklist passes.
- [ ] Commit with message: `test(scope): add test for <behavior>` then `feat(scope): implement <behavior>` then `refactor(scope): <what changed>`.

## When You Are Done

After completing a behavior-first cycle, invoke the **refactor** skill to do
a broader duplication scan, then the **functional-testing** skill if the
change is user-facing.
