---
description: 'C# / .NET coding conventions and best practices'
applyTo: '**/*.cs,**/*.csproj'
---

# C# / .NET Conventions

> Applied automatically to `.cs` and `.csproj` files.

## General

- All new source files must be `.cs`. Use file-scoped namespaces.
- Follow **Microsoft C# coding conventions**: PascalCase for public members, camelCase
  for local variables and parameters, `_camelCase` for private fields.
- Use **XML documentation comments** (`/// <summary>`) for every public type and member.
- Prefer `readonly`, `const`, and immutable collections where possible.
- Use **nullable reference types** (`#nullable enable`) in all new files.
- Prefer **expression-bodied members** for single-line methods and properties.
- Use **pattern matching**, **switch expressions**, and **collection expressions** where
  they improve readability.
- Prefer **dependency injection** over static classes or service locators.
- All async methods must use the `Async` suffix and return `Task` or `Task<T>`.
- After every step, run `dotnet build` and `dotnet test` to verify there are no errors:
  ```bash
  dotnet build --no-restore
  dotnet test --no-build --verbosity normal
  ```
- Use `dotnet format` to ensure consistent formatting.

## Exceptions

- **DO** use `nameof` for the `paramName` argument in `ArgumentException`,
  `ArgumentNullException`, etc. Use `nameof(value)` in property setters.
- **DO** use `ArgumentException.ThrowIfNull()` (.NET 7+) to validate non-null parameters.
- **DO** use `throw;` (not `throw ex;`) inside catch blocks to preserve the call stack.
- **DO** use exception filters to avoid rethrowing from within a catch block.
- **DO** specify the inner exception when wrapping exceptions.
- **DO** favor `try/finally` over `try/catch` for cleanup code.
- **DO NOT** over-catch -- let exceptions propagate unless you clearly know how to
  handle them programmatically.
- **DO NOT** create new exception types unless they would be handled differently
  than existing CLR exceptions.
- **DO NOT** use exceptions for normal, expected conditions.
- **DO NOT** throw exceptions from implicit conversions or operator overloads.
- **DO NOT** have public members that return exceptions as return values or `out`
  parameters.

## Dispose & Finalization

- **DO** call `GC.SuppressFinalize()` from `Dispose()`.
- **DO** ensure `Dispose()` is idempotent (safe to call multiple times).
- **DO** invoke the base class `Dispose()` when overriding.
- **DO** implement `IDisposable` on types that own disposable fields or properties,
  and dispose of them.
- **DO** implement finalizer methods only on objects with unmanaged resources that
  lack their own finalizers.
- **DO NOT** throw exceptions from finalizer methods.

## Properties & Fields

- **DO** declare all instance fields as private; expose them via properties.
- **DO** favor automatically implemented properties over fields.
- **DO** create read-only automatically implemented properties (rather than
  read-only properties with a backing field) when the value should not change.
- **DO** preserve the original property value if the property setter throws an exception.
- **DO** implement non-nullable reference type auto-properties as read-only.
- **DO** assign non-nullable reference type properties before instantiation completes.
- **DO NOT** provide set-only properties or properties where the setter has broader
  accessibility than the getter.

## Structs

- **DO NOT** define a struct unless it logically represents a single value,
  consumes <= 16 bytes, is immutable, and is infrequently boxed.
- **DO** use `record struct` (C# 10.0+).
- **DO** use the `readonly` modifier on struct definitions.
- **DO** ensure the default value (all zeros) of a struct is valid.
- **DO NOT** rely on default constructors or member initialization at declaration
  to run on a value type.

## Records

- **DO** use `record class` for clarity rather than the abbreviated `record` syntax.
- **DO** use records when you want equality based on data rather than identity.
- **DO** define all reference type positional parameters as nullable if not providing
  a custom property implementation that checks for null.

## Enums & Flags

- **DO NOT** use the enum type name as part of enum value names.
- **DO** provide a `None = 0` value for all enums.
- **DO** use `[Flags]` and powers of 2 for flag enums.
- **DO NOT** include sentinel values (e.g., `Maximum`).

## Collections & LINQ

- **DO** use `Any()` rather than `Count() > 0` when checking for items.
- **DO** use a collection's `Count` property instead of `Enumerable.Count()` method.
- **DO NOT** call `OrderBy()` after a prior `OrderBy()` -- use `ThenBy()` for
  secondary sorting.
- **DO NOT** represent an empty collection with `null` -- return an empty collection.

## Threading & Synchronization

- **DO** declare a separate, read-only `object` for synchronization targets -- never
  lock on `this` or public objects.
- **DO** ensure code holding multiple locks always acquires them in the same order.
- **DO** cancel unfinished tasks rather than allowing them to run during application
  shutdown.
- **DO** encapsulate mutable static data with synchronization logic.
- **DO** use `Task`-based APIs in favor of `Thread` and `ThreadPool`.
- **DO** use `TaskCreationOptions.LongRunning` sparingly.

## ToString

- **DO** override `ToString()` whenever useful diagnostic strings can be returned.
- **DO** provide `ToString(string format)` or implement `IFormattable` if the return
  value requires formatting or is culture-sensitive.
- **DO NOT** return an empty string or `null` from `ToString()`.
- **DO NOT** throw exceptions or cause observable side effects from `ToString()`.

## Miscellaneous

- **DO** use `Environment.NewLine` rather than `\n` for cross-platform compatibility.
- **DO** use uppercase literal suffixes (e.g., `1.618033988749895M`).
- **DO** favor composite formatting over `+` concatenation when localization is possible.
- **DO NOT** provide an implicit conversion operator if the conversion is lossy.

## Testing (xUnit)

| Layer | Tool | Location |
|---|---|---|
| Unit tests | xUnit + Moq | `tests/unit/**/*Tests.cs` |
| Integration tests | xUnit | `tests/integration/**/*Tests.cs` |
| Functional tests | xUnit | `tests/functional/**/*Tests.cs` |

- Unit test files mirror the source tree (e.g., `src/<ProjectName>/Services/FooService.cs`
  -> `tests/unit/Services/FooServiceTests.cs`).
- Use **Arrange / Act / Assert** pattern in every test method.
- Use **descriptive test method names**: `MethodName_Scenario_ExpectedBehavior`.
- Mock external dependencies with Moq. Use real code paths wherever possible.
- Use **test fixtures** (saved data files in `tests/fixtures/`) for deterministic testing.
- Use `IClassFixture<T>` or `ICollectionFixture<T>` for expensive shared setup.
- Prefer `FluentAssertions` for readable assertions where available.
