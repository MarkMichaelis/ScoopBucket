# Rename Update-Package -AllInstalled → -MachineWide (and drop -All alias) — Plan

Issue: #263. Worktree: `.worktrees/263-rename-machinewide`.
Branch: `feat/263-rename-machinewide`.

## Goal

Single clear name for the machine-wide sweep switch: `-MachineWide`.
Both prior spellings (`-AllInstalled`, `-All`) removed outright — no alias,
no deprecation.

## TDD task list

1. **RED — rewrite the existing test suites in-place.**
   - In `bucket/UpdatePackage.Tests.ps1`:
     - Delete the entire `Describe 'Update-Package -All dispatcher'` block (lines ~731-759).
     - In the `Describe 'Update-Package -AllInstalled rename (#261)'` block (lines ~761-788):
       - Rename to `Describe 'Update-Package -MachineWide dispatcher (#263)'`.
       - Replace every `-AllInstalled` token with `-MachineWide`.
       - Update the "should not be called under" message string.
       - Delete the `-All (back-compat alias)` It-block.
     - In the help-doc block (lines ~790-...):
       - Rename to `Describe 'Update-Package help documents -MachineWide explicitly (#263)'`.
       - Replace `'AllInstalled'` with `'MachineWide'` in the parameter Where-Object.
   - Add a new `Describe 'Update-Package legacy names are removed (#263)'` block with two `It` blocks:
     - `-All throws ParameterBindingException`.
     - `-AllInstalled throws ParameterBindingException`.
   - Run Pester → confirm reds.

2. **GREEN — rename in production.**
   - `module/.../Public/Update-Package.ps1`:
     - Param: `[Alias('All')] [switch]$AllInstalled` → `[switch]$MachineWide` (no alias).
     - Guard: `if ($AllInstalled)` → `if ($MachineWide)`.
     - Help SYNOPSIS / DESCRIPTION / .PARAMETER / .EXAMPLE blocks: replace every `-AllInstalled` and `-All` with `-MachineWide`. Drop the back-compat note ("`-All` is preserved as a back-compat alias of `-AllInstalled`"). Drop the `Update-Package -All` example added in #262. Keep the verbatim disclaimer "**This updates EVERY installed package the engine knows about on the local machine, INCLUDING packages that were NOT installed by this bucket.**" and the five-engine command list.
     - On `-Name` parameter: contrast sentence reads "To update every installed package on the machine regardless of source, use **-MachineWide**."
   - `module/.../Private/Invoke-AllEnginesUpdate.ps1`:
     - File header comment: `Update-Package -All` → `Update-Package -MachineWide`.
     - Completer-refresh note: `-AllInstalled` → `-MachineWide`.
   - Run full suite → green.

3. **Refactor (Phase 4).** No structural changes expected; the rename is mechanical.

4. **Functional / evidence (Phase 5b).**
   - `Get-Help Update-Package -Full` shows `-MachineWide` parameter with five-engine list.
   - `Update-Package -MachineWide -DryRun` plans across all five engines.
   - `Update-Package -All` errors with ParameterBindingException.
   - `Update-Package -AllInstalled` errors with ParameterBindingException.

5. **PR.** Body includes "## Breaking change" section listing removed identifiers.
   `Closes #263`.

## Out of scope

- Renaming the internal `Update-All*Packages` private functions.
- Touching the bucket-scoped `-Name` / `*` parameter set.
- Any further naming churn.
