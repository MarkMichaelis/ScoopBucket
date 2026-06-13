# scripts

Standalone maintenance / remediation scripts for this repo and machine.

## Test-OneDriveMoveBlockers.ps1

Pre-flight for `bucket\os\MarkMichaelisOneDriveConfiguration.ps1`. Lists the
processes that currently hold open file handles under the OneDrive sync roots
and would block a same-volume `Move-Item` (NTFS rename) during migration.

The migration stops OneDrive.exe itself, but **not** other apps (editors,
Office, Snagit, an Explorer window or terminal parked in the folder). A held
handle makes the directory rename throw a sharing violation mid-run, so check
first and close the offenders.

Uses Sysinternals `handle` (`scoop install sysinternals`). Run **elevated**
for complete coverage.

```powershell
# List blockers; re-run until it prints CLEAR, then run the migration
.\scripts\Test-OneDriveMoveBlockers.ps1

# Include OneDrive's own processes (diagnostics)
.\scripts\Test-OneDriveMoveBlockers.ps1 -IncludeOneDriveProcesses

# Scan specific roots
.\scripts\Test-OneDriveMoveBlockers.ps1 -Root 'C:\Users\Me\OneDrive - Contoso'
```

Outputs a `PSCustomObject` per blocking handle (`Process`, `Id`, `Path`) and
returns nothing once clear.

## Reset-OneDriveModuleJunction.ps1

Removes directory **junctions / symbolic links** that block OneDrive
**"Back up folders"** (Known Folder Move) so you can re-register the OneDrive
account and folder backup completes cleanly.

### The problem it fixes

OneDrive folder backup refuses to back up **any** reparse point. If a tool
"links" a PowerShell module into your user module path -- for example an older
`module/Install-Module.ps1` that junctioned `MarkMichaelis.ScoopBucket` into
`Documents\PowerShell\Modules` -- that junction lands under the
OneDrive-redirected `Documents` folder and OneDrive reports:

> `<name> in Documents is a directory junction or symlink and can't be backed up`

Backup then stays broken until the junction is removed.

### What it does

1. Finds the OneDrive-redirected `Documents` folder (via the `Personal` known
   folder, which KFM repoints into OneDrive).
2. Scans the PowerShell module folders under it
   (`PowerShell\Modules` and `WindowsPowerShell\Modules`).
3. Identifies **real** junctions/symlinks via `LinkType`. OneDrive
   Files-On-Demand placeholders are also reparse points but report a `null`
   `LinkType`, so they are **never** touched.
4. Removes each link **safely**: strips the `ReadOnly` attribute, then calls
   `[System.IO.Directory]::Delete($link, $false)` (non-recursive) so only the
   link is deleted -- it never follows the reparse point into, or deletes the
   contents of, the link target (your repo).

After it runs, re-run OneDrive **"Back up folders"** (or sign the account back
in) and backup should succeed.

### Usage

```powershell
# Preview only -- show what would be removed, change nothing
.\scripts\Reset-OneDriveModuleJunction.ps1 -ListOnly

# Dry run via the standard PowerShell switch
.\scripts\Reset-OneDriveModuleJunction.ps1 -WhatIf

# Remove repo-pointing junctions (the common case), with a confirmation prompt
.\scripts\Reset-OneDriveModuleJunction.ps1

# Remove with no prompt
.\scripts\Reset-OneDriveModuleJunction.ps1 -Confirm:$false

# Remove EVERY junction/symlink found, not just repo-pointing ones (careful)
.\scripts\Reset-OneDriveModuleJunction.ps1 -All -Confirm:$false

# Scan somewhere else
.\scripts\Reset-OneDriveModuleJunction.ps1 -Path 'D:\OtherOneDrive\Documents\PowerShell\Modules'
```

### End-to-end OneDrive reset

1. Run the script (`-ListOnly` first to review, then for real).
2. In the OneDrive flyout, open **Settings -> Sync and backup -> Manage backup**
   and click **Retry** (or re-add the account if you removed it).
3. Confirm the previously failing folder now backs up without the
   "directory junction or symlink" error.

### Parameters

| Parameter   | Purpose                                                                 |
|-------------|-------------------------------------------------------------------------|
| `-Path`     | Folders to scan. Default: OneDrive `Documents` PowerShell module folders. |
| `-All`      | Also remove links to other **existing** non-repo folders (default removes repo-pointing and dangling links only). |
| `-ListOnly` | Report findings and exit without removing anything.                     |
| `-WhatIf` / `-Confirm` | Standard `SupportsShouldProcess` dry-run / prompting.         |

### Output

Emits a `PSCustomObject` per junction/symlink found:
`Path`, `LinkType`, `Target`, `TargetExists`, `PointsToGitRepo`, `Action`
(`Removed` / `Skipped` / `WouldRemove` / `Listed` / `Failed: ...`).

### Permanent fix

The root cause -- the installer creating a junction under the OneDrive module
path -- was fixed in
[MarkMichaelis/ScoopBucket#375](https://github.com/MarkMichaelis/ScoopBucket/issues/375).
`module/Install-Module.ps1` now registers the module via `PSModulePath` (no
junction) and removes any legacy self-pointing junction on (re)install, so this
script is a one-time remediation for machines that were linked by an older
installer. For the scoop module specifically you can also just run
`module\Install-Module.ps1` (or `-Uninstall`) -- it performs the same safe
junction cleanup.
