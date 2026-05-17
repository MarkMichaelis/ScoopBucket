---
name: functional-testing
description: "Generate and maintain functional / integration / E2E tests that validate user-facing behavior. Explore first, test second. Verify before claiming success. Language-aware: C#/xUnit, PowerShell/Pester, TypeScript/Playwright, and generic support."
---

# Functional Testing

Generate, maintain, and refine tests that validate real user-facing behavior -- whether
that's API surfaces, service pipelines, or integration between components.

**Detect the project language** from file extensions and project files. Apply the matching
language-specific guidance below. If the language is not listed, infer conventions from
the project's existing code and community standards.

## Core Responsibilities

1. **Exploration**: Understand the system's public surface before writing tests. Explore the services, interfaces, and their parameters.
2. **Test Generation**: Write well-structured, maintainable functional tests based on what you discovered.
3. **Test Execution & Refinement**: Run the generated tests, diagnose failures, and iterate until all tests pass reliably.
4. **Test Improvements**: When asked to improve existing tests, re-explore the system to identify correct interactions and assertions.
5. **Verification**: Before claiming tests pass, **run them and read the output**. Never say "should pass" or "probably works."

## Test Design Principles

### User-Centric Tests

- **Test what the user experiences** -- interact with the system as a real user would.
- **Avoid implementation details** -- don't assert on internal state, private variables, or internal data structures.
- **Test complete flows** -- cover the full happy path, then error paths and edge cases.

### Reliability

- **No flaky tests** -- use deterministic assertions and proper setup/teardown.
- **Isolate tests** -- each test should set up its own state and not depend on other tests.
- **Retry strategically** -- configure retries for genuinely non-deterministic scenarios only.

### Performance

- **Parallel execution** -- design tests to run independently so they can execute in parallel.
- **Mock external services** -- mock network calls and external APIs when testing behavior, not connectivity.
- **Keep tests fast** -- avoid unnecessary setup or redundant operations.

## Verification Before Completion

**Evidence before claims, always.** Before saying tests pass:

```
1. IDENTIFY: What command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check exit code, count failures
4. VERIFY: Does output confirm the claim?
5. ONLY THEN: Make the claim
```

**Red flags -- STOP if you catch yourself:**
- Using "should", "probably", "seems to"
- Expressing satisfaction before verification ("Great!", "Perfect!", "Done!")
- Trusting previous run results instead of running fresh

---

## Integration Tests vs E2E Tests

> **Integration tests** verify component interactions within the application
> (C#: `tests/integration/`, TypeScript: `tests/integration/`). **E2E tests** verify
> complete user flows through the UI (TypeScript/Playwright only: `tests/e2e/`).
> Use integration tests for service-to-service validation; use E2E tests only when
> testing browser-based UI flows.

## Language-Specific Guidance -- C# / .NET (xUnit Integration Tests)

### Test Organization

- Place functional/integration tests in `tests/integration/` or `tests/functional/` organized by feature.
- File naming: `<Feature>Tests.cs` (e.g., `UserRegistrationTests.cs`, `PaymentProcessingTests.cs`).
- Group related scenarios with nested classes or separate test classes.
- Keep test files focused -- one feature or user flow per file.

### Exploration First

Before writing tests:
1. Check the project structure for public interfaces and services.
2. Read each service's XML documentation and method signatures.
3. Explore dependency injection configuration.
4. Identify test fixtures (data files in `tests/fixtures/`).

### Test File Template -- C#

```csharp
using Xunit;
using Moq;
using FluentAssertions;

namespace MyProject.Tests.Integration;

[Trait("Category", "Integration")]
public class OrderProcessingFlowTests : IClassFixture<TestFixtureSetup>
{
    private readonly TestFixtureSetup _fixture;

    public OrderProcessingFlowTests(TestFixtureSetup fixture)
    {
        _fixture = fixture;
    }

    [Fact]
    public async Task ProcessOrder_WithValidInput_CompletesSuccessfully()
    {
        // Arrange
        var input = new OrderRequest { CustomerId = "C001", Items = new[] { "SKU-100" } };

        // Act
        var result = await _fixture.OrderService.ProcessAsync(input);

        // Assert
        result.Should().NotBeNull();
        result.Status.Should().Be(OrderStatus.Completed);
        result.OrderId.Should().NotBeNullOrEmpty();
    }

    [Fact]
    public async Task ProcessOrder_WithEmptyItems_ReturnsValidationError()
    {
        // Arrange
        var input = new OrderRequest { CustomerId = "C001", Items = Array.Empty<string>() };

        // Act
        var act = () => _fixture.OrderService.ProcessAsync(input);

        // Assert
        await act.Should().ThrowAsync<ValidationException>()
            .WithMessage("*at least one item*");
    }
}
```

### Running Tests -- C#

```bash
dotnet build --no-restore
dotnet test --no-build --verbosity normal --filter "Category=Integration"
dotnet test --no-build --verbosity normal --filter "FullyQualifiedName~OrderProcessingFlowTests"
```

> **Important:** The `--filter "Category=Integration"` flag matches tests whose class (or
> method) is decorated with `[Trait("Category", "Integration")]`. Always add the trait to
> your test class.

---

## Language-Specific Guidance -- PowerShell (Pester Integration Tests)

### Test Organization

- Place functional/integration tests in `tests/integration/` organized by feature.
- File naming: `<Feature>.Tests.ps1`.
- Group related scenarios with `Describe` and `Context` blocks.
- Keep test files focused -- one feature or user flow per file.

### Running Tests -- PowerShell

```powershell
Invoke-Pester -Path tests/integration/ -Output Detailed
Invoke-Pester -Path tests/integration/<Feature>.Tests.ps1 -Output Detailed
```

### Test File Template -- PowerShell

```powershell
Describe 'Feature: <FeatureName>' {
    BeforeAll {
        # Setup: import module, create test fixtures
    }

    It 'should <expected behavior> when <condition>' {
        # Arrange
        # Act
        # Assert
    }

    AfterAll {
        # Cleanup
    }
}
```

---

## Language-Specific Guidance -- TypeScript (Playwright E2E Tests)

### Test Organization

- Place E2E tests in `tests/e2e/` organized by feature or user flow.
- File naming: `<feature>.spec.ts`.
- Group related scenarios with `test.describe()`.
- Keep test files focused -- one feature or user flow per file.

### Locator Priority (Web)

Prefer locators in this order (most to least reliable):

1. `getByRole()` -- accessible role with name
2. `getByLabel()` -- form labels
3. `getByPlaceholder()` -- input placeholders
4. `getByText()` -- visible text content
5. `getByTestId()` -- `data-testid` attributes (last resort)

Avoid raw CSS selectors, XPath, or IDs unless absolutely necessary.

### Running Tests -- TypeScript

```bash
npx tsc
npx playwright test
npx playwright test tests/e2e/<feature>.spec.ts
npx playwright test --ui
npx playwright show-report
```

---

## Language-Specific Guidance -- Generic (Any Language)

If the project uses a language not listed above:

1. **Detect the test framework** from project files.
2. **Organize by feature** -- one test file per feature or user flow.
3. **Explore the system's public surface** before writing any test code.
4. **Run lint/compile** after writing or modifying any test file.
5. **Follow the project's existing test naming conventions.**

---

## Systematic Debugging for Test Failures

When a test fails, follow this process **before proposing any fix**:

1. **Read the error message carefully** -- it often contains the answer.
2. **Reproduce consistently** -- run the test again to confirm it fails reliably.
3. **Check the system state** -- inspect what the system actually produced vs. what was expected.
4. **Trace the cause** -- is it a setup issue, a timing issue, a wrong assertion, or a real application bug?
5. **Fix one thing at a time** -- don't change multiple things and hope something works.

## When to Skip Functional Testing

Skip functional testing when **ALL** changed files are:

- Unit test helpers (e.g., `tests/unit/**/TestHelpers.cs`, mock builders)
- Internal/private utilities not exposed via any public API
- Configuration changes that don't affect runtime behavior (e.g., `.editorconfig`, CI YAML formatting)
- Documentation-only changes (e.g., `README.md`, `docs/`, comment-only edits)

**When in doubt, write the test.** If even one changed file touches a public API, service
boundary, or user-facing behavior, functional tests are required.

## Checklist (per test)

- [ ] Feature / user flow clearly defined.
- [ ] System explored before writing test code.
- [ ] Test is isolated and doesn't depend on other tests.
- [ ] Test passes reliably on repeated runs (verified by running, not assumed).
- [ ] Failure messages are clear and actionable.
- [ ] Lint/compile passes without errors.
- [ ] Commit with message: `test(integration): add <feature> functional test` or `test(e2e): add <feature> functional test`.

## When You Are Done

After completing functional tests, the **dev-loop orchestrator** (not this skill) invokes
the refactor skill to check for duplication across test files (shared fixtures, helpers,
page objects). This skill should **NOT** invoke refactoring directly.
