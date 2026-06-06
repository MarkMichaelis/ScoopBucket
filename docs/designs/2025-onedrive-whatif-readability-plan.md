# 2025 OneDrive -WhatIf Readability Plan (Issue #332)

## Fix 1 -- `-PassThru` switch suppresses plan-object dump by default
- Add `[switch] \` to the script-level `param()` block.
- Add `[switch]\` to `Invoke-MarkMichaelisOneDriveConfiguration` param block.
- Gate the WhatIf early return: `if (\) { return \ }` else `return`.
- Gate the final return: `if (\) { return \ }`.
- Forward `-PassThru:\` from the top-level invocation block.
- Add `.PARAMETER PassThru` comment-based help.
- Update the apply-mode capture test (`\ = ...`) to add `-PassThru`.

### Tests (Heavy)
- "does not emit the plan object to the pipeline by default under -WhatIf" -> `\ | Should -BeNullOrEmpty`.
- "emits the plan object when -PassThru is supplied under -WhatIf" -> count > 0 and contains MoveAccount.

## Fix 2 -- tabular plan listing
- Replace the per-item foreach in `Format-OneDriveMigrationPlan` with a `Format-Table` rendering.
- Columns: Action / Type / From / To with shortened paths (~ = HomeDir, . = RootDir).
- Legend line + preserved skip/warning visibility.
- Empty plan renders no table.

### Test (Light)
- Non-empty plan with one MoveAccount item; assert table header (Type/To), MoveAccount, `~\OneDrive - Michaelis` present, `Current:` absent.

## Verify
`Invoke-Pester -Path .\bucket\os\MarkMichaelisOneDriveConfiguration.Tests.ps1`