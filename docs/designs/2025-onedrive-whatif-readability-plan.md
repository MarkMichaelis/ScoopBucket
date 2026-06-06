# 2025 OneDrive -WhatIf Readability Plan (Issue #332)

## Fix 1 -- `-PassThru` switch suppresses plan-object dump by default
- Add `[switch] $PassThru` to the script-level `param()` block.
- Add `[switch]$PassThru` to `Invoke-MarkMichaelisOneDriveConfiguration` param block.
- Gate the WhatIf early return: `if ($PassThru) { return $plan }` else `return`.
- Gate the final return: `if ($PassThru) { return $plan }`.
- Forward `-PassThru:$PassThru` from the top-level invocation block.
- Add `.PARAMETER PassThru` comment-based help.
- Update the apply-mode capture test (`$secondPlan = ...`) to add `-PassThru`.

### Tests (Heavy)
- "does not emit the plan object to the pipeline by default under -WhatIf" -> `$out | Should -BeNullOrEmpty`.
- "emits the plan object when -PassThru is supplied under -WhatIf" -> `@($out).Count` > 0 and contains a `MoveAccount` item.
- Apply-mode capture test also asserts the first (no -PassThru) invocation emits nothing.

## Fix 2 -- tabular plan listing
- Replace the per-item foreach in `Format-OneDriveMigrationPlan` with a `Format-Table` rendering.
- Columns: Action / Type / From / To with shortened paths (~ = HomeDir, . = RootDir).
- Legend line + preserved skip/warning visibility.
- Empty plan renders no table.

### Test (Light)
- Non-empty plan with one MoveAccount item; assert table header (Type/To), `MoveAccount`,
  `~\OneDrive - Michaelis` (HomeDir shortening), `.\OneDrive - Michaelis` (RootDir shortening),
  the legend line, and that `Current:` is absent.

## Verify
`Invoke-Pester -Path .\bucket\os\MarkMichaelisOneDriveConfiguration.Tests.ps1`