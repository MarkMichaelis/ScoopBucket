---
name: refactor-workflow
description: "Identify and eliminate code duplication, improve design, and apply best practices after every green step. Simplicity is the primary goal -- never add behavior during refactoring. Language-aware."
---

# Refactor Workflow

After every green TDD step or new functional test, scan the codebase for duplication,
code smells, and design improvements. Apply changes while keeping every test green.

**Detect the project language** from file extensions and project files. Apply the matching
language-specific guidance below. If the language is not listed, infer conventions from
the project's existing code and community standards.

## Philosophy

- **Complexity reduction** -- Simplicity as the primary goal
- **YAGNI** -- only extract when duplication is real (>= 2 occurrences), never speculative
- **DRY** -- eliminate real duplication, not imagined similarity
- **Evidence over claims** -- run tests and verify after every change, never assume

## Core Principles

### Remove Duplication

- **Extract common code** into reusable utility functions, helpers, or shared modules.
- **Consolidate repeated patterns** -- if you see the same logic in two or more places, extract it.
- **DRY test setup** -- move shared test fixtures, mocks, and helpers into shared test helper files.
- **Avoid premature abstraction** -- only extract when duplication is real (>= 2 occurrences), never speculative.

### Improve Readability

- **Intention-revealing names** -- rename variables, functions, and files so their purpose is obvious.
- **Small, single-purpose functions** -- break down any function exceeding 20 lines.
- **Consistent patterns** -- ensure similar operations use the same structure throughout the codebase.
- **Remove dead code** -- delete unused imports, variables, functions, and commented-out code.

### Apply SOLID Principles

- **Single Responsibility** -- each module and function should have one reason to change.
- **Open/Closed** -- extend behavior through composition, not modification of existing code.
- **Dependency Inversion** -- depend on abstractions, not concrete implementations.
- **Interface Segregation** -- keep module exports focused; don't force consumers to depend on things they don't use.

### Design Excellence

- **Appropriate patterns** -- apply patterns (Factory, Strategy, Observer, etc.) only when they simplify the code. Never add a pattern "just in case."
- **Reduce cyclomatic complexity** -- flatten nested conditionals with guard clauses or early returns.
- **Consistent error handling** -- standardize how errors are caught, logged, and propagated.
- **Type safety** -- tighten types where the language supports it; avoid `any`, `object`, `dynamic` when a precise type is possible.

---

Utility extraction paths follow each language's conventions. The paths below are defaults -- use the project's existing structure if it differs.

## Language-Specific Guidance -- C# / .NET

### Refactoring Scope

**Production Code (`src/`)**
- Extract shared utilities -> `src/<ProjectName>/Helpers/` or `src/<ProjectName>/Extensions/`
- Consolidate service patterns behind interfaces (e.g., `IFooService`, `IBarProcessor`)
- Ensure every public type and member has XML documentation comments (`/// <summary>`)
- Prefer `readonly`, `const`, and immutable collections
- Use nullable reference types (`#nullable enable`)
- Simplify with pattern matching, switch expressions, and collection expressions

**Unit Tests (`tests/unit/`)**
- Extract shared test builders -> `tests/helpers/` or shared test base classes
- Extract test data factories -> `tests/helpers/TestDataFactory.cs`
- Consolidate repeated `Arrange` patterns
- Remove test duplication across files

**Integration Tests (`tests/integration/`)**
- Extract shared setup into `IClassFixture<T>` or `ICollectionFixture<T>`
- Consolidate common service configuration and DI patterns

### Running Tests -- C#

```bash
dotnet build --no-restore
dotnet test --no-build --verbosity normal
dotnet format
dotnet format --verify-no-changes
```

---

## Language-Specific Guidance -- PowerShell

### Refactoring Scope

**Production Code (`src/`)**
- Extract shared utilities -> `src/*/Private/` (internal helpers)
- Ensure every exported function has `[CmdletBinding()]` and comment-based help
- Simplify parameter validation with `[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, etc.
- Use approved verbs (`Get-Verb`)

**Unit Tests (`tests/unit/`)**
- Extract shared mocks -> `tests/helpers/Mocks.ps1`
- Extract test data factories -> `tests/helpers/TestData.ps1`
- Consolidate repeated `BeforeAll`/`BeforeEach` patterns
- Remove test duplication across files

### Running Tests -- PowerShell

```powershell
Invoke-ScriptAnalyzer -Path src/ -Recurse -Severity Warning
Invoke-Pester -Path tests/ -Output Detailed
```

---

## Language-Specific Guidance -- TypeScript

### Refactoring Scope

**Production Code (`src/`)**
- Extract shared utilities -> `src/utils/`
- Extract shared types/interfaces -> `src/types/`
- Replace `any` with proper interfaces or generics
- Simplify module structure and exports

**Unit Tests (`tests/unit/`)**
- Extract shared mocks -> `tests/helpers/mocks.ts`
- Extract test data factories -> `tests/helpers/factories.ts`
- Consolidate repeated `beforeEach` patterns into shared fixtures

**E2E Tests (`tests/e2e/`)**
- Extract Page Object Models -> `tests/e2e/pages/`
- Extract shared test helpers -> `tests/e2e/helpers/`

### Running Tests -- TypeScript

```bash
npx tsc
npx vitest run
npx playwright test
```

---

## Language-Specific Guidance -- Generic (Any Language)

1. **Run the project's lint/compile step** before and after every refactoring.
2. **Run the full test suite** after every change.
3. **Follow the project's existing conventions** for file organization, naming, and code structure.
4. **Extract shared code** into the project's conventional utility/helper locations.
5. **Check for existing config** -- look for `.editorconfig`, linter config, or formatter config in the repo root.
6. **Infer from existing code** -- observe indentation, naming, and module structure patterns already in use.
7. **Run existing lint/format scripts** -- check `package.json`, `Makefile`, or CI config for lint and format commands.
8. **Fall back to community standards** -- if no project conventions exist, apply the language community's standard style guide (e.g., PEP 8 for Python, gofmt for Go, rustfmt for Rust).

---

## Execution Guidelines

1. **Ensure all tests are green** -- never start refactoring with a failing suite. Run the full test suite first and verify the output.
2. **Scan for duplication** -- search the codebase for repeated code patterns, similar functions, and copy-pasted blocks.
3. **Small incremental changes** -- refactor in tiny steps, running tests after each change.
4. **One improvement at a time** -- focus on a single refactoring technique per step.
5. **Lint/compile after every change** -- run the project's lint and compile tools after each refactoring step.
6. **Run the full test suite** -- after every change, run all tests to confirm nothing broke.
7. **Verify before claiming** -- after refactoring, run the full suite and present the evidence. Never say "should still pass."
8. **Commit each refactoring** -- use `refactor(scope): <what changed>` commit messages.

## Refactoring Checklist

- [ ] All tests green before starting.
- [ ] Duplication identified and extracted.
- [ ] Names clearly express intent.
- [ ] Functions are <= 20 lines and single-purpose.
- [ ] Dead code removed.
- [ ] Types tightened where applicable.
- [ ] Code smells addressed (long parameter lists, feature envy, shotgun surgery).
- [ ] All tests still green after refactoring (verified by running them, not assumed).
- [ ] Code coverage maintained or improved (if the project has coverage tracking configured; skip this check if no coverage tooling exists).
- [ ] Changes committed with `refactor(scope): <description>`.

### Cross-Level Test Refactoring

When refactoring touches both unit tests and integration/functional tests, ensure changes are consistent across test levels. Extract shared test utilities to `tests/helpers/` (or the project's equivalent) rather than duplicating across test directories.

## Anti-Patterns to Avoid

- **Over-abstracting** -- don't create abstractions for code that is only used once. YAGNI.
- **Refactoring while red** -- never refactor when tests are failing; go green first.
- **Changing behavior** -- refactoring must not alter observable functionality; if it does, you need a new test first.
- **Big-bang refactoring** -- never rewrite large sections at once; always work in small, verifiable steps.
- **Ignoring tests** -- if a refactoring breaks a test, the refactoring is wrong, not the test.
- **"While I'm here" improvements** -- stay focused on the planned refactoring. Don't add features or fix unrelated issues.
