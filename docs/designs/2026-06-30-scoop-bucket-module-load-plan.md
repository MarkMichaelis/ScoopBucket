# Plan: Fix scoop bundle module load + opt-in per-machine module registration (#390)

Date: 2026-06-30
Branch: feat/390-scoop-bucket-module-load

## Part B -- portable core fix (the original bug)

Replace the 2-line module-import header in all 16 production bundle `.ps1` files with a
3-branch, self-contained, region-delimited block. Branch 1 (repo checkout) keeps each
file's existing depth; branch 2 (scoop bucket clone) is new; branch 3 (by-name) last.

Canonical block (top-level bundles use `..\module`; subdir bundles use `..\..\module`
on the psd1 Join-Path line -- everything else identical):

```powershell
#region MarkMichaelis.ScoopBucket bundle module import (scoop-portable; see README)
$scoopBucketModule = 'MarkMichaelis.ScoopBucket'
$scoopBucketPsd1 = Join-Path $PSScriptRoot "..\module\$scoopBucketModule\$scoopBucketModule.psd1"
if (-not (Test-Path $scoopBucketPsd1)) {
    $scoopBucketRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $PSScriptRoot '..\..\..' }
    $scoopBucketFound = Get-ChildItem -Path (Join-Path $scoopBucketRoot "buckets\*\module\$scoopBucketModule\$scoopBucketModule.psd1") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($scoopBucketFound) { $scoopBucketPsd1 = $scoopBucketFound.FullName }
}
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module $scoopBucketModule -Force }
#endregion MarkMichaelis.ScoopBucket bundle module import
```

Under scoop, the bundle runs from `<scoopRoot>\apps\<bundle>\<ver>\`, so branch 2's
`$PSScriptRoot\..\..\..` == `<scoopRoot>` for ALL bundles regardless of repo subdir. Prefer
`$env:SCOOP` when set. The `buckets\*` glob works whatever the bucket was named.

### 16 files (branch-1 depth preserved) + manifest minor bumps

Top-level (`..\module`): AIAgents, ClientBasePackages, DeveloperBasePackages, OSBasePackages
Subdir (`..\..\module`): ai/ChatGPT, ai/ClaudeExcel, ai/Gemini, client/MicrosoftOffice365,
developer/Aspire, developer/Chocolatey, developer/GitConfigBeyondCompare, developer/GitConfigure,
developer/GitConfigVisualStudio, developer/GitConfigVSCode, developer/PowerShell, os/McAfeeUninstall

Each corresponding `.json` gets a MINOR bump (patch -> 000), e.g. OSBasePackages 1.33.000 -> 1.34.000.

## Part C -- opt-in per-machine module registration

New repo-root `Register-BucketModule.ps1` (`[CmdletBinding(SupportsShouldProcess)]`):
- Resolves the module source dir: `-ModulePath` (explicit, e.g. a local checkout) > sibling
  `module\MarkMichaelis.ScoopBucket` when present (and not `-FromBucketClone`) > this machine's
  bucket clone `<scoopRoot>\buckets\*\module\MarkMichaelis.ScoopBucket`.
- `<scoopRoot>` = `-ScoopRoot` param > `$env:SCOOP` > `~\scoop`.
- Creates/repairs junction `<scoopRoot>\modules\MarkMichaelis.ScoopBucket` -> module source
  (idempotent; SupportsShouldProcess). `~\scoop\modules` is already on PSModulePath.
- Appends exactly one idempotent, sentinel-bracketed `Import-Module MarkMichaelis.ScoopBucket`
  block to `-ProfilePath` (default `$PROFILE.CurrentUserAllHosts`). Distinct sentinel
  (`RegisterBucketModule`) so it never collides with Install-Module.ps1's lazy v3 block.
- `-Remove` reverses both: the junction (only when it is a reparse point at that path -- a
  real directory there is left untouched with a warning, and only the link is deleted, never
  the target contents) and the sentinel-bracketed profile block (always).

New opt-in manifest `bucket\admin\RegisterBucketModule.json` (mirrors the admin precedent;
NO new executable `.ps1` under bucket/ so bundle discovery never executes it):
- `url` -> repo-root `Register-BucketModule.ps1` (scoop downloads it to `$dir`).
- `installer.script`: `& "$dir\Register-BucketModule.ps1"`
- `uninstaller.script`: `& "$dir\Register-BucketModule.ps1" -Remove`
NOT wired as a `depends` on any other bundle.

## Tests (behavior-first, Light, temp/child-process isolation)

- `bucket\ScoopAppDirModuleImport.Tests.ps1` (Part B): stage a fake scoop layout in TestDrive
  (`apps\<bundle>\<ver>\<bundle>.ps1` copy with NO sibling module; sibling
  `buckets\TestBucket\module\MarkMichaelis.ScoopBucket\` copy of the real module). Extract the
  canonical header REGION from a real production bundle, compose a minimal bundle
  (`[Package]@{ Name='BootstrapProbe'; CustomInstallScript={} }` + `Invoke-PackageInstall -DryRun`),
  run under `pwsh -NoProfile -File`, assert `RESULT:BootstrapProbe=Installed`. Cover both the
  `..\..\..` derivation (SCOOP unset) and `$env:SCOOP` set. Negative control: remove the bucket
  clone -> the same run FAILS (proves branch 2 is what loads the module -> fail-on-revert).
- `bucket\BundleModuleImportDrift.Tests.ps1` (Part B drift guard): assert all 16 production
  bundles contain the identical canonical region (modulo branch-1 depth) so no bundle can
  silently lose branch 2.
- `bucket\admin\RegisterBucketModule.Tests.ps1` (Part C): invoke the repo-root script with
  `-ScoopRoot`/`-ProfilePath`/`-ModulePath` seams against TestDrive. Assert: junction created to
  the module source; exactly one Import-Module line added; `-WhatIf` makes no changes; second run
  idempotent; bucket-clone discovery finds a staged clone; `-Remove` reverses both.

## Docs

- README.md: update the bundle header example (lines ~85-99) to the new canonical block; add a
  short "Register the module on another machine" note referencing RegisterBucketModule.
- bucket\Test-Template.Tests.ps1.txt: update its header to the canonical block (top-level depth).

## Commit sequence (Conventional Commits + Co-authored-by: Copilot)

1. test(bundle): add fake-scoop-layout module-load + drift tests (red)
2. fix(bundle): load module from scoop bucket clone under -NoProfile (16 headers) + manifest bumps
3. test(admin): add Register-BucketModule behavior-first tests (red)
4. feat(admin): add opt-in Register-BucketModule.ps1 + RegisterBucketModule manifest
5. docs(readme,template): document the scoop-portable header + module registration