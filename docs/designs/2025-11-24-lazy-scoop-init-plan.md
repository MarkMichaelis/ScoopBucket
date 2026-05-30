# Lazy-Load Scoop Environment -- Implementation Plan

**Issue:** #217
**Branch:** `perf/217-lazy-scoop-init`

## Goal
Cut `Import-Module MarkMichaelis.ScoopBucket` cold time by ~1.9s by deferring `Initialize-ScoopEnvironment` until a wrapper that actually needs scoop internals (`scoop`, `Get-LocalBucket`) is called.

## Tasks

### Task 1 -- RED: ImportPerformance test
Create `bucket/ImportPerformance.Tests.ps1`:
- `Tag 'Light','Module'`.
- Import module fresh; assert `Get-Command parse_app -Module MarkMichaelis.ScoopBucket -ErrorAction Ignore` is `$null`.
- Call `Get-LocalBucket` (tolerate any output); assert lookup now returns a command.
- Cold-timing block: skip on `$env:CI` truthy. Use `pwsh -NoProfile -Command "Measure-Command { Import-Module <psd1> }"`; median of 5; assert `< 1200` ms (loose).
This test will FAIL on `main` for the first assertion (parse_app IS present after import).

### Task 2 -- RED: LazyScoopInit guard test
Create `bucket/LazyScoopInit.Tests.ps1`:
- `Tag 'Light','Module'`.
- Discover scoop root via `Resolve-ScoopRoot` in a child process; if unavailable, skip whole file.
- Test 1: temporarily rename `lib\manifest.ps1` -> `.bak` in a child runspace, import module (should succeed), call `Initialize-ScoopEnvironment` (should throw or warn), assert guard remains false (re-callable). Restore file, call again, assert succeeds and `Get-Command parse_app -Module MarkMichaelis.ScoopBucket` is now present.
- Run entirely in a child `pwsh -NoProfile` process so file renames don't break the parent test runner.

### Task 3 -- GREEN: Convert Initialize-ScoopEnvironment to idempotent guarded helper
Edit `module/MarkMichaelis.ScoopBucket/Private/Legacy.ps1`:
- Add `$script:ScoopEnvironmentInitialized = $false` near top.
- In `Initialize-ScoopEnvironment`: early-return when guard true; only flip guard to `$true` AFTER all `. $p` calls succeed (use a local `$ok` set inside try, or flip after the foreach completes without throwing).
- Wrap the foreach so a single-file failure does not abort all loading -- actually, simpler: flip guard at the end of function only if all `Test-Path` files were successfully dot-sourced. Failures inside `. $p` propagate to caller (matches current semantics) but the guard stays false.

### Task 4 -- GREEN: Remove eager call, add lazy calls
- Edit `MarkMichaelis.ScoopBucket.psm1`: delete the `try { . Initialize-ScoopEnvironment } catch ...` line.
- Edit `Legacy.ps1`:
  - In `Get-LocalBucket`: add `Initialize-ScoopEnvironment` as first line (plain call, no dot-source).
  - In `scoop` wrapper: add same as first line.
- Audit other functions that reference any scoop-internal symbol; the grep showed only `Get-LocalBucket` and `scoop` use `parse_app`/`Find-BucketDirectory`/`search_bucket`. Other call sites use `scoop.ps1` (the binary) which doesn't need init.

### Task 5 -- Verify (Phase 4 Refactor / Phase 5 Functional)
- Run `Invoke-Pester -Path .\bucket\ -Tag Light` -- all green.
- Run `Invoke-Pester -Path .\bucket\ImportPerformance.Tests.ps1,.\bucket\LazyScoopInit.Tests.ps1` -- the two new tests green.
- Sanity: `Import-Module ...; Get-LocalBucket; scoop --version` works end-to-end.

### Task 6 -- Phase 5b Evidence
Run baseline timing on `main`, then on branch. Capture 5 cold imports each, median delta. Save artifact to `.evidence/phase-5b-<ts>/timing-comparison.md`.

### Task 7 -- Commit + PR
- `perf(module): lazy-load scoop environment on first wrapper call (#217)`
- `test(module): cover lazy scoop init contract (#217)`
- Rebase onto origin/main, push, open PR with `Closes #217`.

## Files touched
- `module/MarkMichaelis.ScoopBucket/MarkMichaelis.ScoopBucket.psm1` (delete eager line + 1 comment update)
- `module/MarkMichaelis.ScoopBucket/Private/Legacy.ps1` (add guard, mutate Initialize-ScoopEnvironment, add 2 lazy calls)
- `bucket/ImportPerformance.Tests.ps1` (new)
- `bucket/LazyScoopInit.Tests.ps1` (new)