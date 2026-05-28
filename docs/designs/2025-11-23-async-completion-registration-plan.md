# Plan: Defer Completion Registration via PowerShell.OnIdle

**Issue:** [#212](https://github.com/MarkMichaelis/ScoopBucket/issues/212)
**Branch:** `perf/212-async-completion-registration`
**Date:** 2025-11-23

## Task list

### Task 1 -- RED: assert OnIdle wrap is present in written block
File: `bucket/CompletionDeferredRegistration.Tests.ps1` (new), tag `Light`.
Test: `Register-PackageCompletion` with a fixture NativeCommand writes a block containing
`Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1`.

### Task 2 -- GREEN: add `Format-DeferredCompletionBlock` helper + wrap in Register-PackageCompletion
- Bump `$script:CompletionSentinelVersion = 'v2'` in `Register-PackageCompletion.ps1`.
- Add `Format-DeferredCompletionBlock([string]$InnerCode)` that returns:
  ```
  $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
  <inner>
  } | Out-Null
  ```
- In `Register-PackageCompletion`, wrap `$resolved.Code` with the helper before
  passing to `Set-PackageCompletionProfileBlock`.

### Task 3 -- RED: assert -PreCapturedNative bypasses NativeCommand scriptblock
Add test in same Pester file: pass a NativeCommand that throws + a -PreCapturedNative
string; result must succeed and the block body must contain the cached text.

### Task 4 -- GREEN: add `-PreCapturedNative` param
Add `[string]$PreCapturedNative` to `Register-PackageCompletion`. When set, Mode != 'pscompletions',
and non-empty: build `$resolved` directly from the cached text (apply the same `if (Get-Command ...)`
guard) without calling `Resolve-PackageCompletionSource`.

### Task 5 -- GREEN: plumb NativeCommandOutputs through Invoke-PackageInstall
In `Invoke-PackageInstall.ps1`, when invoking `Register-PackageCompletion` per CLI, look up
`$pkg.NativeCommandOutputs[$cli]` (supporting both hashtable and PSCustomObject shapes -- the
same pattern already used in `Update-PackageCompletion.ps1` lines 140-148) and pass it as
`-PreCapturedNative` when non-empty.

### Task 6 -- RED: assert v1 -> v2 migration on re-register
Test: pre-seed profile with a v1-formatted sentinel block; call `Register-PackageCompletion`;
assert resulting block uses `:BEGIN v2` and is wrapped in OnIdle.

### Task 7 -- GREEN: confirm `Set-PackageCompletionProfileBlock` replace path handles version bump
Already uses `\w+` regex; should pass without changes. Verify by re-running test.

### Task 8 -- RED: assert Import-PackageCompletion does NOT defer
New test in `bucket/ImportPackageCompletion.Tests.ps1` (or extend existing): after calling
`Import-PackageCompletion -Package <fake>` with a fixture native script, asking the completion
engine for matches succeeds *immediately* (no OnIdle drain needed); also assert no
PowerShell.OnIdle subscriber was registered by that call.

### Task 9 -- GREEN: verify no Import-PackageCompletion changes required
Audit that the current code path executes `[scriptblock]::Create($resolved.Code).InvokeReturnAsIs()`
synchronously and never calls `Register-EngineEvent`. (Already true; this is a defensive test.)

### Task 10 -- update Test-PackageCompletionWorks probe to drain OnIdle subscribers
In `Register-PackageCompletion.ps1` `Test-PackageCompletionWorks`, after dot-sourcing the profile
in the child runspace, iterate `Get-EventSubscriber -SourceIdentifier PowerShell.OnIdle`, run each
subscriber's Action scriptblock synchronously, then call `CompleteInput`.

### Task 11 -- update CompletionEndToEnd.Tests.ps1 probe analogously
Same drain step inside the inline probe in `CompletionEndToEnd.Tests.ps1` so the Heavy suite
keeps passing once blocks are deferred.

### Task 12 -- assert Update-PackageCompletion -Force rewrites v1 as v2
Extend `bucket/UpdatePackageCompletion.Tests.ps1` (or the new file): pre-seed v1 block, call
`Update-PackageCompletion -Force -ProfilePath <sandbox>`, assert v2 + OnIdle wrap.

### Task 13 -- assert profile-block top level has no top-level subprocess call
Test: with a NativeCommand whose cached output contains `& warp.exe completions powershell`,
inspect the block; outside the `-Action { ... }` body the block must contain only the
`Register-EngineEvent` line (no `&`, no `Invoke-Expression`).

### Task 14 -- run full Light suite + new Light tests
`Invoke-Pester -Path bucket\,module\ -ExcludeTag Heavy,Network,Idempotency,CompletionPinned,BucketScope`
plus our new tests.

### Task 15 -- evidence capture
Before/after timing of `pwsh -NoLogo -Command exit` with a synthetic profile holding 5 fake
subprocess-bearing blocks. Capture both timings in `.evidence/<phase-id>/perf-evidence.md`.

## Out of scope (per issue)

- Lazy stub completers (option 3).
- Modifying legacy `Register-CliCompletion` in `Legacy.ps1`.
- Bundle-level rewrites (e.g. AIAgents.ps1 warp/oz NativeCommandScript).
