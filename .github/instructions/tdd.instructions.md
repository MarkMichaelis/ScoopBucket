---
description: 'Behavior-first testing -- core principles applied to all files'
applyTo: '**/*'
---

# Behavior-First Testing

> **Always-on rule.** Every behavior change in this repository must ship with
> a test that proves the behavior changed. This file states the rule.
> The detailed workflow lives in the canonical skill -- see the link below.

## The Two-Part Rule

Every behavior change must satisfy **both** of these:

1. **A test ships with the change.** No production behavior change without a
   corresponding test in the same commit (or earlier in the same PR).
2. **The test must fail for a behavioral reason when the change is reverted.**
   That means an assertion failure -- not a compile error, not an import error,
   not a missing-symbol error. If reverting the production code only breaks
   compilation, the test is collusion, not verification.

The rule is stronger than mere "tests exist" because it constrains the
*quality* of the test, not just its presence.

## Compliance

Code reviews should verify that:

- A test ships with every behavior change.
- Each test fails for a behavioral reason when the change is reverted
  (not just a compile/import error).
- Tests assert observable behavior, not implementation structure.
- Implementations do not hard-code test inputs.
- Spike code has been deleted or retro-fitted with behavior-first tests
  before merge.
- All tests pass before merging.

## Canonical detailed source

For the full Red-Green-Refactor cycle, the spike clause, the anti-collusion
guardrails, the F.I.R.S.T. test-quality heuristic, and language-specific
guidance (C#/xUnit, PowerShell/Pester, TypeScript/Vitest, plus a generic
fallback), see the canonical skill:

[`.github/skills/behavior-first-testing/SKILL.md`](../skills/behavior-first-testing/SKILL.md)

Invoke the `behavior-first-testing` skill whenever you start a new
behavior change.
