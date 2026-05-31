# Plan: Rename Update-Package `-All` to `-AllInstalled` (#261)

## Tasks

### T1 — RED: add failing tests for new surface
File: `bucket/UpdatePackage.Tests.ps1` — append a new `Describe` block:
- `Update-Package -AllInstalled` invokes `Invoke-AllEnginesUpdate` once.
- `Update-Package -All` (alias) invokes `Invoke-AllEnginesUpdate` once.
- `Update-Package -Name foo -AllInstalled` throws (param-set conflict).
- `Get-Help Update-Package -Parameter AllInstalled` description mentions all five engines verbatim: `winget`, `scoop`, `choco` or `chocolatey`, `npm`, `dotnet`.
- `Get-Help Update-Package -Full` description contains `not installed by this bucket`.

Watch fail (parameter `-AllInstalled` doesn't exist yet).

### T2 — GREEN: rename parameter + alias + rewrite help
File: `module/MarkMichaelis.ScoopBucket/Public/Update-Package.ps1`
- Change `[switch]$All` → `[Alias('All')][switch]$AllInstalled` in MachineWide set.
- Update the `if ($All)` branch to `if ($AllInstalled)`.
- Rewrite SYNOPSIS / DESCRIPTION / PARAMETER AllInstalled / PARAMETER Name / EXAMPLEs per design (engines verbatim, "not installed by this bucket" phrase present).

Watch all tests pass — new 5 + existing 22 (via alias) + the other 26.

### T3 — Phase 4 Refactor
Nothing structural expected; verify functions ≤ 20 lines unchanged.

### T4 — Phase 5 Functional + Phase 5b Evidence
- Capture `Get-Help Update-Package -Full` showing the new help.
- Capture `Update-Package -AllInstalled -DryRun` transcript.
- Capture `Update-Package -All -DryRun` transcript (alias still works).

### T5 — PSScriptAnalyzer + commit + PR

## Commits
1. `test(update): add failing tests for -AllInstalled rename (#261)`
2. `feat(update): rename -All to -AllInstalled with explicit-engine help (#261)`
