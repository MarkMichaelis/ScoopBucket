# Update-Package -All — Implementation Plan

Tracks #259. See the issue for design rationale.

## Task 1 — Test scaffolding (RED)

Append a new `Describe 'Update-Package -All (machine-wide)'` block to
`bucket/UpdatePackage.Tests.ps1` with these `It`s, all initially RED because
neither the private engine sweeps nor the dispatcher route exist yet:

1. `-All -DryRun` invokes Invoke-AllEnginesUpdate (mocked) and skips Get-BundlePackages.
2. `-Name foo -All` errors with parameter-set ambiguity (no execution).
3. Each Update-All*Packages engine: prints the bulk command under -WhatIf and returns Updated/(WhatIf).
4. Each engine: Get-Command returns null → returns Skipped, no invocation.
5. Each engine: exit 0 → Updated; exit non-zero → Failed (engine continues; verified at orchestrator level).
6. Orchestrator runs all five engines in scoop→winget→choco→npmGlobal→dotnetTool order.
7. Orchestrator: one engine failing does not prevent others from running.
8. dotnet `--all` fallback: output containing "Unrecognized option" triggers per-tool enumeration path.
9. Hint line printed at end of -All run.

## Task 2 — Engine sweeps (GREEN)

Create five private files, each ~40 lines, all following the
`Update-WingetPackage` template:

- `Private/Update-AllWingetPackages.ps1`
- `Private/Update-AllScoopPackages.ps1`
- `Private/Update-AllChocoPackages.ps1`
- `Private/Update-AllNpmGlobalPackages.ps1`
- `Private/Update-AllDotnetToolPackages.ps1`

Signature: `param([switch]$WhatIf)` → returns `@{ State; Reason; Engine }`.

## Task 3 — Orchestrator (GREEN)

`Private/Invoke-AllEnginesUpdate.ps1` — runs the five sweeps in order,
collects results, prints glyph summary table (reuse the existing glyph
scheme), prints the completer hint at the end.

## Task 4 — Dispatcher (GREEN)

Refactor `Public/Update-Package.ps1`:

- Add `[CmdletBinding(DefaultParameterSetName='ByName', SupportsShouldProcess, ConfirmImpact='Medium')]`.
- `-Name` → `ParameterSetName='ByName'`.
- New `[Parameter(ParameterSetName='MachineWide', Mandatory)][switch]$All`.
- Branch at top of function: if `$All` → call `Invoke-AllEnginesUpdate -DryRun:$DryRun` and return.

## Task 5 — Refactor + lint pass

- Function ≤ 20 lines where possible (engine sweeps will hit this naturally; orchestrator may need 30-40).
- No duplication between the five engine sweeps that screams for extraction — they each have distinct probe and parse logic, so DRY-via-helper is YAGNI for five callsites.

## Task 6 — Phase 5b evidence

- `Update-Package -All -DryRun` transcript saved to `.evidence/phase-5b-<ts>/dry-run.md`.
- One real low-blast-radius run: scoop only, by invoking `Update-AllScoopPackages` directly.

## Commit map

- `test(update): add failing Update-Package -All tests` (RED)
- `feat(update): add per-engine bulk update sweeps` (GREEN engines)
- `feat(update): add Invoke-AllEnginesUpdate orchestrator` (GREEN orchestrator)
- `feat(update): add -All switch to Update-Package` (GREEN dispatcher)
- `refactor(update): <if any>` (Phase 4)
- `docs(spec): add Update-Package -All to spec` (Phase 7 step 2)
