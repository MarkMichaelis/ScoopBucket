# Plan: Sidecar `.ps1` files for cached CLI completer payloads (#216)

## Why

The v2 profile emit wraps each cached native completer payload inside an
`OnIdle -Action { if (Get-Command $cli) { <payload> } }` block. When the
payload itself starts with `using namespace System.Management.Automation`
(emitted by `rg --generate complete-powershell` and most clap/Rust
completers) the parser rejects the entire profile because `using` is only
legal as the FIRST statement of a script -- never inside an `if`/`Action`
scriptblock.

Fix: persist the raw cached payload to a sidecar `.ps1` file (where `using`
at the top IS legal) and dot-source it from the OnIdle Action.

## Tasks

### T1. RED: bump `CompletionPinned` assertion to v3
- Edit `bucket/CompletionPinned.Tests.ps1` -- replace the regex requiring
  `'v2'` with one requiring `'v3'`. Update the comment.
- Run `Invoke-Pester -Path .\bucket\CompletionPinned.Tests.ps1 -Tag CompletionPinned`
  -> must fail with "Expected $true, but got $false" (sentinel still v2).

### T2. RED: new sidecar test
- Create `bucket/CompletionUsingNamespaceSidecar.Tests.ps1`. Synthetic
  payload: a scriptblock that `Write-Output`s
  `"using namespace System.Management.Automation`r`nRegister-ArgumentCompleter -Native -CommandName demoUns -ScriptBlock { }"`.
  Call `Register-PackageCompletion` via the InModuleScope hook with
  `-ProfilePath $sandboxProfile -SidecarDirectory $sandboxSidecarDir`.
  Assertions:
    1. Profile content must NOT match `using namespace`.
    2. `<SidecarDir>\demoUns.ps1` must exist and its first non-empty line
       must be `using namespace System.Management.Automation`.
    3. Profile block must match `\.\s+'.*?demoUns\.ps1'` inside the
       `OnIdle -Action {` block.
    4. Spawn `pwsh -NoProfile -File <probe>` that dot-sources the profile
       and writes `OK` to stdout. Must print `OK` (no parser error).
  Run -> must fail (Register-PackageCompletion still inlines the payload).

### T3. GREEN: production change in `Register-PackageCompletion.ps1`
- Bump `$script:CompletionSentinelVersion = 'v3'`.
- Add `Get-PackageCompletionSidecarDirectory -ProfilePath <pp>
  -OverrideDirectory <od>` that returns:
    * `$OverrideDirectory` when set, or
    * `<dir of $ProfilePath>\completions` when `$ProfilePath` is non-null
      and not equal to `$PROFILE.AllUsersAllHosts` (test path), or
    * `Join-Path $env:ProgramData 'ScoopBucket\completions'` for prod.
  Creates the directory if missing. Elevation check piggy-backs on the
  profile path's elevation check -- the prod sidecar dir lives in
  `ProgramData` which already requires admin to write to.
- Add `Write-PackageCompletionSidecar -Cli <c> -Payload <p> -Directory <d>`
  that atomically writes `<d>\<c>.ps1` (UTF-8 no BOM) with the raw payload.
- Add `Remove-PackageCompletionSidecar -Cli <c> -Directory <d>` that
  deletes `<d>\<c>.ps1` if present.
- Change `Register-PackageCompletion`:
    * Accept new optional `-SidecarDirectory` parameter (test hook).
    * After resolving Native source, call
      `Write-PackageCompletionSidecar` to persist the raw payload (the
      `$resolved.Code` BEFORE we wrap it in the `if (Get-Command)` guard).
    * Build the inner code as:
      ```
      if (Get-Command <cli> -ErrorAction SilentlyContinue) {
          . '<sidecar-fullpath>'
      }
      ```
      and pass that to `Format-DeferredCompletionBlock`.
    * Resolve-PackageCompletionSource currently returns guarded code with
      the payload inlined; refactor so it returns the raw payload and the
      guard wrapper is applied at the call site that knows the sidecar
      path. Same fast-path for `-PreCapturedNative`.
- Change `Remove-PackageCompletionBlock`:
    * Accept new optional `-SidecarDirectory` parameter (test hook).
    * After stripping the block, call `Remove-PackageCompletionSidecar`.

### T4. Update existing CompletionDeferredRegistration tests
- The four tests assert `Register-ArgumentCompleter -Native -CommandName demo1`
  appears IN the profile. With sidecars that text now lives in the sidecar
  `.ps1`. Update each test to:
    * Pass a `-SidecarDirectory` pointing into the sandbox.
    * Assert the profile contains `. '<sandbox>\demoN.ps1'` (dot-source).
    * Assert the sidecar exists and contains the `Register-ArgumentCompleter`
      text.
    * Update the "rewrites v1 -> vN" test to assert `v3` not `v2`.
    * Update the critical-path test (no top-level subprocess call) to
      check the SIDECAR for no top-level subprocess call -- the sidecar
      is what loads on profile parse via `.` dot-source.

  Wait: re-reading the critical-path test, the intent is "profile parsing
  doesn't pay subprocess cost". The deferred-action body now is just
  `. 'sidecar.ps1'`. Sidecar gets dot-sourced ONLY when the OnIdle action
  fires (after first prompt). So the profile critical path is even cleaner
  than before. The assertion should be: the OnIdle Action body does NOT
  contain `&` or `Invoke-Expression` at top level -- still true (it's
  just a dot-source). Keep that test largely intact but updated to check
  the v3 sidecar pattern.

### T5. Update existing UninstallPackage Remove-PackageCompletionBlock tests
- The three Remove-tests pass `-ProfilePath` only. Add `-SidecarDirectory`
  for the new sidecar parameter. Add an additional assertion: after
  Remove, the sidecar file no longer exists.

### T6. GREEN verify
- Run `Invoke-Pester -Path .\bucket\,.\module\`. All must pass.
- Specifically run `-Tag CompletionPinned,DeferredCompletion`.

### T7. Refactor pass
- Look for duplication between `Register-PackageCompletion`'s native
  resolution and `Import-PackageCompletion`'s native resolution. The
  sidecar concept ONLY applies to profile-block path; in-runspace
  `Import-PackageCompletion` continues to `[scriptblock]::Create($code).
  InvokeReturnAsIs()` directly. No change there. (Confirms "out of scope".)

### T8. Commit, push, PR
- Single commit:
  `fix(completion): persist cached completer payloads as sidecar .ps1 files to allow leading 'using namespace' (#216)`
- PR body: includes `Closes #216`, lists verification scenarios, mentions
  sentinel bump v2 -> v3.

## File map
- MODIFY `module/MarkMichaelis.ScoopBucket/Private/Register-PackageCompletion.ps1`
- MODIFY `bucket/CompletionPinned.Tests.ps1`
- MODIFY `bucket/CompletionDeferredRegistration.Tests.ps1`
- MODIFY `bucket/UninstallPackage.Tests.ps1`
- CREATE `bucket/CompletionUsingNamespaceSidecar.Tests.ps1`
- (no new fields consumed by Test-Installs.ps1 -- the per-installer probe
  in Get-BundlePackages.ps1 and the flattener in Get-Package.ps1 are
  untouched.)

## Test command (CI mirror)
```
Invoke-Pester -Path .\bucket\,.\module\
```
Pre-push focus run:
```
Invoke-Pester -Path .\bucket\ -Tag CompletionPinned,DeferredCompletion
```

## Risks
- Existing v2 blocks in users' profiles will be re-written by
  `Register-PackageCompletion` only when called (Update-PackageCompletion
  -Force, or a fresh Install-Package). Until then the broken v2 blocks
  remain. Document this in PR description: users hitting #216 must run
  `Update-PackageCompletion -Force` (the very command that exposed the
  bug) to migrate. That command itself does not need rg present, so it
  will succeed even when the broken profile prevents `pwsh` startup --
  user can launch with `pwsh -NoProfile` once to run the migration.

