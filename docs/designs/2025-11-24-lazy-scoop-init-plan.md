# Partial-Lazy Scoop Environment -- Implementation Plan

**Issue:** #217
**Branch:** `perf/217-lazy-scoop-init`

## Goal
Cut `Import-Module MarkMichaelis.ScoopBucket` cold time by ~1.4s (from ~2400ms to ~1030ms median) by deferring the heaviest part of `Initialize-ScoopEnvironment` (`libexec\scoop-search.ps1`, which transitively pulls in `versions.ps1` + `download.ps1`) until a wrapper that actually needs it (`scoop search -PSCustomObject`) is called.

The three lightweight libs (`lib\core.ps1`, `lib\buckets.ps1`, `lib\manifest.ps1` -- ~100ms total) stay eager because (a) they are tiny, (b) they are needed synchronously by `Get-LocalBucket` and the `scoop` wrapper before either has a chance to call a lazy initializer, and (c) keeping them eager preserves the existing contract that `parse_app` / `Find-BucketDirectory` are resolvable immediately after `Import-Module`.

## Design

### `Initialize-ScoopEnvironment` (eager, idempotent, 3 lightweight libs)

- Guarded by `$script:ScoopEnvironmentInitialized = $false` at module scope.
- Early-returns when the guard is true.
- Resolves `$env:SCOOP` via `Resolve-ScoopRoot`; returns silently if scoop is not installed.
- Dot-sources `lib\core.ps1`, `lib\buckets.ps1`, `lib\manifest.ps1` into module scope.
- Only flips the guard to `$true` AFTER every required lib was found AND dot-sourced. If any required lib file is missing (e.g. half-installed scoop) the guard stays `$false` so a retry after repair re-attempts the dot-source. Throws from inside `. $p` likewise propagate and leave the guard false.
- Called via the dot-source operator from the `.psm1` (`. Initialize-ScoopEnvironment`) so the inner `. $p` calls land in module scope and the dot-sourced functions persist there. A plain (non-dot-sourced) call would land them in this function's local scope, where they would evaporate on return.

### `Initialize-ScoopSearchEnvironment` (lazy, per-call)

- Separate function that dot-sources `libexec\scoop-search.ps1` (~1.8s) into the CALLER's scope.
- Invoked with the dot-source operator from the `scoop` wrapper's `search -PSCustomObject` branch immediately before any `search_bucket` call, so the heavy load is paid only by sessions that actually search.
- No module-scope guard: each call re-loads so the heavy dependencies never permanently land in module scope. Sessions that never search never pay the cost.

## Files touched

- `module/MarkMichaelis.ScoopBucket/MarkMichaelis.ScoopBucket.psm1` -- documentation comment explaining why `scoop-search.ps1` is excluded from the eager init.
- `module/MarkMichaelis.ScoopBucket/Private/Legacy.ps1` -- add module-scope guard, idempotent `Initialize-ScoopEnvironment`, new `Initialize-ScoopSearchEnvironment`, lazy dot-source from the `scoop search -PSCustomObject` branch.
- `bucket/ImportPerformance.Tests.ps1` (new) -- assert cold import median is under the budget (~1800ms).
- `bucket/LazyScoopInit.Tests.ps1` (new) -- guard idempotency, throw-retry, and missing-file-retry contracts.

## Verification

- `Invoke-Pester -Path .\bucket\ImportPerformance.Tests.ps1,.\bucket\LazyScoopInit.Tests.ps1` -- 6/6 green locally.
- `Invoke-Pester -Path .\bucket\ -Tag Light` -- full Light suite green.
- Sanity: `Import-Module ...; Get-LocalBucket; scoop --version; scoop search foo -PSCustomObject` works end-to-end.

## Trade-offs considered

- **Fully-lazy** (defer `Initialize-ScoopEnvironment` entirely until first wrapper call) was the original plan. Rejected because `Get-LocalBucket` and the `scoop` wrapper both need lightweight scoop symbols synchronously on their first call, and inserting an init-guard at the top of every such wrapper added more friction than benefit for ~100ms of work. The partial-lazy split (eager-light + lazy-heavy) gives ~95% of the win without the wrapper-level discipline.
- **Replacing `scoop-search.ps1` with a re-implementation** in pure module code was considered to drop the lazy hop entirely. Rejected for now because scoop's search internals (`search_bucket` semantics, JSON parsing quirks, bucket precedence) are non-trivial to mirror and would drift over time as scoop evolves.
