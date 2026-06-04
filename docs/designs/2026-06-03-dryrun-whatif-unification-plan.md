# Plan: Unify install/update preview on ShouldProcess/-WhatIf with -DryRun alias

Issue: #299
Branch: refactor/299-dryrun-whatif

## Design

Single preview mechanism = `$WhatIfPreference` / ShouldProcess. `-DryRun` becomes a
first-class alias: each public/driver function sets `$WhatIfPreference = $true` for the
call scope when `-DryRun` is supplied, then derives a local `$isWhatIf = [bool]$WhatIfPreference`
and keys every preview branch off that single boolean. `-WhatIf` / `-Confirm` continue to
work for free via `SupportsShouldProcess`. Preview stays opt-in; default executes;
`-WhatIf:$false` forces execution.

The private engine helpers (`Install-WingetPackage`, etc.) already take the standard
`[switch]$WhatIf` and return the `{ State; Reason }` contract -- they are NOT the custom
plumbing being removed (they never had `-DryRun`). They stay as-is; the drivers forward
`-WhatIf:$isWhatIf` to them.

## Tasks

1. TDD: add `bucket/DryRunWhatIfParity.Tests.ps1` proving the install + update trios
   (-WhatIf no-op + planned rows; -DryRun identical; default executes; -WhatIf:$false executes).
2. `Invoke-PackageInstall.ps1`: bridge `-DryRun` -> `$WhatIfPreference`; derive `$isWhatIf`;
   replace every `if ($DryRun)` / `-not $DryRun` with `$isWhatIf`; forward `-WhatIf:$isWhatIf`
   to engines; update `.PARAMETER DryRun` doc.
3. `Install-Package.ps1`: bridge `-DryRun` -> `$WhatIfPreference`; derive `$isWhatIf`; gate
   the bare-manifest path (c) with `$PSCmdlet.ShouldProcess`; forward `-DryRun:$isWhatIf`;
   replace `-not $DryRun` with `-not $isWhatIf`; rewrite the ~192-200 comment + `.PARAMETER`.
4. `Update-Package.ps1`: add `[switch]$DryRun` alias param; bridge before the existing
   `$isWhatIf = [bool]$WhatIfPreference`; add `.PARAMETER DryRun` + example.
5. `Invoke-PackageUpdate.ps1`: add `[switch]$DryRun` alias param; bridge to `$WhatIfPreference`.
6. README: add a short preview note describing -DryRun/-WhatIf as one opt-in mechanism.
7. Run focused tests + full safe sweep; PR; Copilot review; rebase-merge; cleanup.

## Verification

`Invoke-Pester` safe sweep (ExcludeTag Heavy,CliAvailability,Integration,Slow,Install) on
`bucket` green; CI green.
