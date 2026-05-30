# ScoopBucket

A personal [Scoop](https://scoop.sh/) bucket of Windows install/config
scripts: base packages for client, developer, and AI workflows; an
`AIAgents` bundle that wires up Claude/ChatGPT/Gemini/Microsoft Copilot
and a curated set of MCP servers; and miscellaneous one-shot system
configurations.

## Bootstrap

```powershell
iex (irm https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/master/install.ps1)
```

`install.ps1` installs Chocolatey, installs Scoop, registers this bucket
plus `extras`, then installs `OSBasePackages`. Other bundles
(`DeveloperBasePackages`, `ClientBasePackages`, `AIAgents`) are opt-in:

```powershell
scoop install MarkMichaelis/DeveloperBasePackages
scoop install MarkMichaelis/ClientBasePackages
scoop install MarkMichaelis/AIAgents
```

## Idempotency contract

**Every script in this bucket must be safely re-runnable.** Concretely:

- A second invocation must not throw.
- It must not create duplicate links, files, registry entries, or profile
  imports.
- It must not unconditionally reinstall PowerShell modules (no
  `Install-Module -Force` without a guard).
- It is allowed to be slower than the first run — `choco`, `scoop`,
  `winget`, and `Install-Module` will each hit their source and confirm
  "already installed". That is fine.

Patterns we use to honor the contract:

- Wrap `New-Item` (Junction, HardLink, SymbolicLink, Directory) in
  `if (-not (Test-Path …))` *or* use `-Force`.
- Use `git config --global` (never bare `git config`) so re-runs don't
  pollute the cwd repo.
- Always pass `--silent`, `-y`, or `--accept-…` to package managers so
  they exit deterministically.
- Use `Get-Command <cli>` / `Test-Path <marker>` early-exit guards for
  expensive paths (browser-watch installers, Node.js bootstrap, etc.).
- For config files (JSON, TOML), read → mutate the named entry → write,
  rather than appending.

When adding a new script, run it twice locally before pushing — see the
testing notes below.

## Repository structure

Each bundle in this bucket is a Scoop manifest (a `.json` file under
`bucket/`) that points at a sibling `.ps1` script which does the actual
installation work. A single JSON manifest typically corresponds to a
*group* of packages, and the matching `.ps1` enumerates and installs each
member of that group (e.g. `ClientBasePackages.json` →
`ClientBasePackages.ps1`, which installs Kindle, Bitwarden, Dropbox,
etc.). Shared helpers live in the `ScoopBucket` PowerShell module under
`module/MarkMichaelis.ScoopBucket/`, which every bundle script imports at the top.

### `ScoopBucket` PowerShell module

The repo ships a companion PowerShell module under `module/MarkMichaelis.ScoopBucket/`
that exposes a declarative `[Package]` class plus the helpers
`Install-Package`, `Get-Package`, and `Invoke-PackageInstall`. Most
bundles have been migrated to a declarative
`$Packages = [Package[]]@( ... )` collection driven by
`Invoke-PackageInstall`, replacing per-bundle imperative install loops,
ad-hoc completion try/catch boilerplate, and the override map in
`.github/scripts/Get-PackageCommands.ps1` (which now consumes
`Get-Package` directly for migrated bundles and falls back to text
parsing only for legacy ones).

Each migrated bundle now looks like:

```powershell
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$Packages = [Package[]]@(
    [Package]@{
        Name = 'ripgrep'; Installer = 'scoop'; Id = 'main/ripgrep'
        CliCommands = @('rg'); Completion = 'native'
        NativeCommandScript = { rg --generate complete-powershell }
    }
    # ...
)

Invoke-PackageInstall -Packages $Packages -Bundle 'OSBasePackages'
```

The `[Package]` class enforces enums on `Installer` / `Source` / `Scope` /
`Completion` and rejects misspelled property names at load time. See
`module/MarkMichaelis.ScoopBucket/Classes/Package.ps1` for the full schema (also
`Package.Validate()` for cross-field invariants).

The driver pipeline (validate → topo sort by `DependsOn` → engine
dispatch → `PostInstallScript` → completion register → completion verify
via `[CommandCompletion]::CompleteInput`) closes the long-standing gap
where tab-completion was registered but never end-to-end verified.

To use the module locally:

```powershell
& .\module\Install-Module.ps1
Import-Module MarkMichaelis.ScoopBucket -Force
Get-Command -Module MarkMichaelis.ScoopBucket
```

Top-level helpers for cross-bundle queries:

```powershell
Get-Package                       # list every declared package, across bundles
Get-Package -Installer scoop      # filter by engine
Get-Package -Name 'rip*','Bit*'   # wildcard
Install-Package -Name 'BitwardenCli'   # auto-pulls Bitwarden via DependsOn
Install-Package -Name beyon<Tab>       # Tab-completes to 'Beyond Compare'
```

`-Name` on both `Install-Package` and `Get-Package` registers a Tab
completer that suggests every package declared in any bundle (prefix
first, then substring), so you don't need to remember exact spelling.
For the completer to fire on the *very first* Tab in a fresh
PowerShell session, `module\Install-Module.ps1` also writes an
idempotent `Import-Module MarkMichaelis.ScoopBucket` snippet into
`$PROFILE.CurrentUserAllHosts` (pass `-SkipProfile` to suppress).

Note: `Install-Package` and `Get-Package` deliberately shadow the
rarely-used built-in `PackageManagement` cmdlets of the same name. The
OneGet cmdlets remain reachable as `PackageManagement\Install-Package`
and `PackageManagement\Get-Package`.

**Migration status:** OSBasePackages, DeveloperBasePackages,
ClientBasePackages, ChatGPT, and Aspire have been migrated to the
declarative pattern. AIAgents (with its MCP-server matrix logic) and
the small config-only bundles (`GitConfigVisualStudio`,
`SetPowerConfiguration`, `McAfeeUninstall`) remain imperative for now;
the discovery and validation tools handle both forms transparently.

### Personal post-install customization (`MarkMichaelis*` bundles)

A separate category of bundle whose name is prefixed with
`MarkMichaelis*`. These bundles do **not** install software; they
reshape state on the machine (sync roots, Known Folder Move bindings,
per-app settings) to match the author's personal layout. Members of
this family are designed to run **after** all install bundles --
ordering matters because they reference the accounts and folders
those installs created.

Intended run order:

```powershell
# 1. Install bundles first (in any order).
scoop install MarkMichaelis/OSBasePackages
scoop install MarkMichaelis/DeveloperBasePackages
scoop install MarkMichaelis/ClientBasePackages
scoop install MarkMichaelis/MicrosoftOffice365
scoop install MarkMichaelis/AIAgents

# 2. Personal post-install customization LAST.
scoop install MarkMichaelis/MarkMichaelisOneDriveConfiguration
```

Current members:

- **`MarkMichaelisOneDriveConfiguration`** -- pins every signed-in
  OneDrive account's sync root under a single configurable parent
  (default `C:\OneDrive`), applies tenant-redirection policy so future
  sign-ins land in the right place, and rewrites KFM bindings (Known
  Folder Move: Documents / Pictures / Desktop) to follow the canonical
  Work account when its folder moves. Supports `-WhatIf` for dry-run
  preview before a real migration. On creation, the `RootDir` ACL is
  hardened to match home-directory permissions so sync roots on
  alternate volumes are not readable by other local accounts.

  **Requires an elevated PowerShell session** (Run as Administrator):
  the bundle writes `HKLM:\SOFTWARE\Policies\Microsoft\OneDrive`
  (`DefaultRootDir`, `KFMSilentOptIn`), which is HKLM and admin-only.
  The script fails fast with a clear message if launched without
  elevation. If you have already pre-applied the HKLM policy via
  Group Policy and only want the per-user reshape, pass
  `-SkipElevationCheck` to bypass the pre-flight.

  For Business tenants with large cloud-only datasets (where a
  cross-volume robocopy migration would hydrate every Files-On-Demand
  placeholder), pass `-FreshSync <Slot-or-DisplayName>...`. Matching
  accounts are unlinked instead -- the per-account registry slot and
  local sync folder are deleted, the `DefaultRootDir` policy is still
  applied, and the user re-signs-in via the OneDrive UI so OneDrive
  recreates cloud-only placeholders at the policy-directed path. If
  the KFM owner is in `-FreshSync`, KFM rewrite is skipped and the
  user reconfigures KFM via OneDrive Settings -> Backup -> Manage
  backup after re-sign-in.

  Run `Get-Help .\bucket\MarkMichaelisOneDriveConfiguration.ps1 -Full`
  for the full parameter reference and worked examples.

## Authoring guidelines

### Manifest versioning

Bundle manifests use **semver `major.minor.patch`** with the minor
segment zero-padded to **2 digits** and the patch segment zero-padded
to **3 digits** (e.g. `1.01.000`, `1.12.007`):

- **patch** (3 digits) — bump for bug fixes that don't change the set
  of installed packages or their behavior (e.g. fixing a guard,
  correcting a parameter).
- **minor** (2 digits) — bump when a package is added, removed, or
  otherwise changed (including upgrades, flag changes, or edits to any
  file the manifest references — `.ps1`, embedded configs,
  anything in the manifest's `url` array). Reset patch to `000`.
- **major** — reserved for breaking changes to a bundle's contract.

If a single change touches files referenced by multiple manifests, bump
every affected manifest. The version bump must be in
the same commit as the change, so `scoop update` picks it up.

**This rule is auto-enforced and auto-fixed by CI.** A `verify-versions`
job runs first in both `test.yml` and `validate-installs.yml`. If a
referenced file changed without a matching bump, it bumps the minor
segment, amends the commit, and force-pushes back to the branch — your
downstream CI jobs then run against the corrected commit. On `main`,
the auto-fix is announced via a `::warning::` annotation (yellow, not
red); no human action is required. On fork PRs (where CI has no write
access) the job fails with instructions to run `-Fix` locally.

For the cleanest local flow, enable the opt-in pre-push hook so the
fix happens on your machine instead of on CI:

```powershell
git config core.hooksPath .githooks
```

The hook runs the same helper (`Test-ManifestVersionBumps.ps1 -Amend`)
and folds any needed bump into the commit being pushed.

> **Note.** For the auto-fix to cover a helper that your bundle's
> `.ps1` dot-sources, the helper must be declared in
> the manifest's `url` array. Files outside the `url` set are
> deliberately not tracked.


### Installation engine preference

When adding a package, choose the installer in this order, falling
through only when the higher-priority option doesn't carry the package
or doesn't work cleanly:

1. **Winget** (`winget install --scope machine --id <Id>`) — preferred
   default for GUI apps and CLIs.
2. **Scoop** (`scoop install <bucket>/<name>`) — for packages this
   bucket itself owns, or when winget lacks the package.
3. **Chocolatey** (`choco install -y <name>`) — last resort.

Microsoft Store-only apps go through `winget install --source msstore
--accept-package-agreements --accept-source-agreements`.

### Silent installs

Every package must install non-interactively. Always pass `-y`,
`--silent`, `--accept-package-agreements`, `--accept-source-agreements`,
or whatever flag the engine requires so no installer UI appears.

**If a package cannot be installed entirely silently (the installer will
show UI to the user), warn the developer in chat / PR description
*before* implementing it**, and only proceed once the trade-off is
acknowledged.

### Command-line surface (going forward)

These rules apply to *new* package additions; existing installs are not
required to be retrofitted.

- **CLI availability.** If a package ships a CLI, that CLI must be
  invokable from a fresh PowerShell session by its short name (e.g.
  `bw` for Bitwarden CLI, `gh` for GitHub CLI). Prefer creating a Scoop
  **shim** (or equivalent single-file forwarder) over appending the
  install directory to `$env:PATH` — keep `PATH` short.
- **Tab completion.** If the CLI supports tab completion, register it
  using whatever first-party mechanism the tool ships
  (`<tool> completion powershell`, `Register-ArgumentCompleter`, an
  `-Init` hook, etc.). If the tool has no built-in PowerShell completion
  story, hand-author a `NativeCommandScript` scriptblock on the
  `[Package]` declaration that emits the appropriate
  `Register-ArgumentCompleter` calls (see the `Node.js` package in
  `AIAgents.ps1` for an example: a single shared `NativeCommandScript`
  registers completion for `node`, `npm`, and `npx` uniformly).
  Completion registration belongs in the bundle's `.ps1` (idempotent
  — guard so re-runs don't double-register). The bucket used to
  install `abgox/PSCompletions` as a fallback for tools without
  first-party completion; that hard dependency was removed in #241
  once every bucket entry was migrated to native scripts.

### CLI-availability discovery (in progress)

See #45 for the tracking issue. Rolling out in three phases:

- **Phase 1 — Local discovery.** A `Get-PackageCommands.ps1` helper
  parses every `bucket\*.ps1` for winget / scoop / choco / module
  install patterns, derives a probable CLI short name per package, runs
  `Get-Command` against it, and persists the result via the module's
  `Save-Artifact` helper to `$env:TEMP\ScoopBucket\cli-availability\`
  (a rotating snapshot plus a stable `latest.json`; the helper keeps
  the 5 newest snapshots and prunes anything older than 1 day, so
  local diagnostic runs never accumulate in the working tree).
- **Phase 2 — CI integration.** A Pester `Heavy`-tagged test
  (`bucket\PackageCommands.Tests.ps1`) runs the discovery script after
  the validate-installs job, uploads
  `$env:TEMP\ScoopBucket\cli-availability\latest.json` as the
  `cli-availability` workflow artifact, and posts a Markdown summary
  to `GITHUB_STEP_SUMMARY`. The test does **not** fail the build at
  this phase — it only reports.
- **Phase 3 — Enforcement.** The test asserts availability for an
  explicit allow-list of "must-have CLI" packages (those covered by the
  rule above). Packages with non-obvious CLI names register themselves
  in an `ExpectedCliMap`, and any package missing its expected CLI
  fails the build.

## CLI tab-completion registration

Every bundle that installs CLI tools registers PowerShell tab completion
for the CLIs it owns. Per-CLI native-completion commands are co-located
with their install (e.g. `Register-CliCompletion -Cli gh -NativeCommand
{ gh completion -s powershell }` next to the `gh` install in
`GitConfigure.ps1`), so adding or dropping a CLI never requires editing
the shared module.

Only CLIs whose first-party `<tool> completion powershell` (or
equivalent) emits a real `Register-ArgumentCompleter` script are wired
with `-NativeCommand`. The currently-pinned set is:

| CLI | Owning bundle       | Native command                              |
|-----|---------------------|---------------------------------------------|
| gh  | `GitConfigure.ps1`  | `gh completion -s powershell`               |
| rg  | `OSBasePackages.ps1`| `rg --generate complete-powershell` (≥ v14) |

CLIs whose `completion` subcommand does **not** support PowerShell
(currently `bw`, `copilot`, `gcloud` — see #73) carry a
hand-authored `NativeCommandScript` on their `[Package]` declaration
that emits the appropriate `Register-ArgumentCompleter` blocks
directly. `Register-CliCompletion` will emit a `Write-Warning` if a
future change re-introduces a dead native command (silent dead
wiring would otherwise hide).

The `AIAgents` bundle calls `Invoke-CliCompletionsSweep -Force` at
the end of its install as a best-effort registration pass. The sweep
delegates to the legacy `Register-AllCliCompletions` /
`Register-CliCompletion` path (not the modern declarative
`NativeCommandScript` resolver), enumerating either bucket-declared
CLIs or `$env:PATH` depending on `-IncludeAllPath`. Per-CLI completion
is resolved via the legacy resolver, which (a) tries any
`-NativeCommand` scriptblock the bundle supplied for that CLI and
(b) opportunistically uses `PSCompletions` *only if the user
installed the module themselves* — post-#241 the bucket never
installs PSCompletions on the user's behalf. To re-run the sweep
manually after installing other tools by hand:

```powershell
Import-Module D:\Git\ScoopBucket\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1 -Force
Invoke-CliCompletionsSweep -Force
```

By default the sweep is **bucket-scoped**: it registers completions only
for CLIs declared in bucket package manifests (the union of `CliCommands`
across every `[Package]` returned by `Get-Package` whose `Completion`
field is not `'none'`). To opt into the legacy behavior of registering
completions for every executable on `PATH`, pass `-IncludeAllPath`:

```powershell
Register-AllCliCompletions -IncludeAllPath
```

`-Names <cli1>,<cli2>` overrides scope entirely.

### Recovering from a broken completion block

The bucket previously shipped an opportunistic
[`PSCompletions`](https://github.com/abgox/PSCompletions) fallback for
CLIs without first-party completion. PSCompletions is third-party
content and occasionally shipped completions whose PSReadLine key
handler referenced a property that doesn't exist on the object
PSReadLine actually passes — the symptom was every Tab press emitting:

```
An exception occurred in custom key handler, see $error for more
information: The property 'buffer' cannot be found on this object.
```

`Register-CliCompletion` defends against this by re-invoking the
freshly-added completion through `[CommandCompletion]::CompleteInput`
in a fresh `pwsh -NoProfile` child runspace. If validation errors the
add is rolled back with `psc remove <cli>` and the result row shows
`Action='Failed'` with the underlying reason — no sentinel block is
written.

If a broken handler nonetheless lands in your shell, restore Tab
behavior immediately with:

```powershell
Set-PSReadLineKeyHandler -Chord Tab -Function MenuComplete
```

Then surgically remove the offending sentinel block:

```powershell
$profile = $PROFILE.AllUsersAllHosts
$pattern = '(?ms)^\# ScoopBucket:CliCompletion:<CLI>:BEGIN \w+.*?^\# ScoopBucket:CliCompletion:<CLI>:END\r?\n?'
$text = Get-Content $profile -Raw
[System.IO.File]::WriteAllText($profile, ($text -replace $pattern, ''))
psc remove <CLI>
```

To repair completion blocks for CLIs whose owning bundles are already
installed -- for example after restoring a dev machine where the
`AllUsersAllHosts` profile wasn't backed up -- use the
declarative-bundle walker `Update-PackageCompletion`. It scans every
declarative `[Package]` across the bucket, finds CLIs on `PATH` with
no sentinel block in the profile, and registers them. Native and
`auto`-with-NativeCommandScript completion modes are repaired; legacy
`pscompletions` declarations (none remain in this bucket as of #241)
resolve to `Skipped` with a clear reason:

```powershell
Import-Module MarkMichaelis.ScoopBucket -Force
Update-PackageCompletion          # gap-fill: register only missing blocks
Update-PackageCompletion -Force   # refresh every eligible block
Update-PackageCompletion -WhatIf  # preview what would change
```

Native repairs reuse the `NativeCommandOutputs` text captured by
`Get-BundlePackages` in its child runspace, so no re-install or live
`<cli> completion powershell` call is needed.

Behavior:

- Each CLI is resolved in order: caller-supplied `-NativeCommand`
  scriptblock (owned by the install script) → skipped with a reason.
  Prior to #241 a `PSCompletions` fallback sat between the two; that
  branch was removed once every bucket entry adopted a
  `NativeCommandScript`.
- All registrations are written as sentinel-delimited blocks
  (`# ScoopBucket:CliCompletion:<cli>:BEGIN v2 … :END`) inside
  `$PROFILE.AllUsersAllHosts`. The v2 block wraps the cached
  completer payload in
  `Register-EngineEvent PowerShell.OnIdle -MaxTriggerCount 1 -Action {...}`
  so shell startup pays no subprocess cost — registration runs on
  the first idle tick after the prompt is drawn (#212). Two runs
  with `-Force` produce a byte-identical profile.
- `-Force` is opt-in for ad-hoc invocations (defaults to gap-fill
  only); the bundle installers pass `-Force` explicitly so reinstalls
  always refresh blocks.
- Writing to `$PROFILE.AllUsersAllHosts` requires an elevated session.
  Bundle scripts wrap the call in `try/catch` and emit a warning, so a
  non-elevated reinstall succeeds but the user is told their completion
  blocks were not refreshed.
- `-WhatIf` / `-Confirm` are honored (the helper opts in to
  `SupportsShouldProcess` with `ConfirmImpact='Medium'`).

## Testing

Package install tests use Pester. Most single-package manifests share the
same install-then-verify shape, so they're driven by a **data-driven
harness** rather than one file per manifest:

- `bucket/ManifestInstall.Tests.ps1` — discovers every `<name>.json`
  manifest in `bucket/`, then for each one declared in the hints table
  emits three test cases: *installs from the local manifest*, *is
  idempotent on re-run*, *passes the post-install verification*.
- `bucket/ManifestTestHints.ps1` — declarative table mapping each
  manifest to a verification strategy. Supported verifiers:
  - `Cli` — `Test-Command '<cli>'`
  - `GetProgram` — `Get-Program -Filter '<pattern>'`
  - `Choco` — `Test-ChocolateyPackageInstalled '<id>'`
  - `Custom` — arbitrary scriptblock returning truthy
  - `Scoop` (default) — `Test-ScoopPackageInstalled '<name>'`
  
  Optional per-entry knobs: `Manual` (adds the `Manual` tag),
  `PreserveIfInstalled` (skip the destructive `scoop uninstall` in
  `BeforeAll` and skip the install assertion when the package is already
  present), `Reason` (free-text rationale).

**Adding a new package**

1. Drop `<Name>.json` + `<Name>.ps1` in `bucket/`.
2. Add a `<Name> = @{ Verify = '...'; ... }` line to
   `bucket/ManifestTestHints.ps1`. Manifests with no entry fall through
   to the `Scoop` default, but a hint is preferred so the post-install
   contract is explicit.
3. A `Light`-tag drift test in `ManifestInstall.Tests.ps1` enforces that
   every manifest is accounted for and every hint targets a real
   manifest, so a missing or stale entry fails fast.

**Bespoke per-package tests** still live in their own `*.Tests.ps1`
files when the shape doesn't fit "install + idempotent + verify":

- `McAfeeUninstall.Tests.ps1` — uninstaller flow.
- `AddLocalRepoBucket.Tests.ps1`, `AddMarkMichaelisScoopBucket.Tests.ps1`
  — `scoop bucket add`, not `scoop install`.
- `GitConfigBeyondCompare.Tests.ps1`, `GitConfigVSCode.Tests.ps1`,
  `GitConfigVisualStudio.Tests.ps1`, `GitConfigure.Tests.ps1` —
  multi-assertion `git config` checks; the VSCode file also carries
  `Light/Unit` coverage for `Resolve-VSCodeCommand` / `Invoke-GitDiffCode`.

**Module-level tests** (`Package.Tests.ps1`, `PackageInstall.Tests.ps1`,
`PackageOrder.Tests.ps1`, `PackageNameCompletion.Tests.ps1`,
`InstallPackageFilter.Tests.ps1`, `Bundles.Tests.ps1`,
`ModuleBootstrap.Tests.ps1`, `PSCompletionsNotAutoInstalled.Tests.ps1`,
`Completion*.Tests.ps1`, `CliAvailabilityPinned.Tests.ps1`,
`Save-Artifact.Tests.ps1`, `ManifestVersionBumps.Tests.ps1`,
`PackageCommands.Tests.ps1`, `CliCompletionOutput.Tests.ps1`) exercise
the `MarkMichaelis.ScoopBucket` module itself rather than individual
package installs.

**Quick local check** for a single manifest:

```powershell
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 1st run
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 2nd run — must succeed
```

Or run only the harness's drift checks (fast; no installs):

```powershell
Invoke-Pester -Path bucket\ManifestInstall.Tests.ps1 -Tag Light
```

### Working-copy installs (`Install-LocalManifest`)

To exercise a manifest *as it would install from a bucket* without
pushing first, use `Install-LocalManifest` (exported from the
`MarkMichaelis.ScoopBucket` module). It reads the working-copy
`<Name>.json`, rewrites the `url[]` entries to `file://` paths anchored
at your repo, drops a temp manifest into `$env:TEMP`, and runs
`scoop install` against it.

```powershell
Install-LocalManifest -ManifestPath bucket\AIAgents.json
# or, with $env:SCOOPBUCKET_LOCAL_REPO set to the repo root:
Install-LocalManifest -ManifestName AIAgents
```

After the install succeeds, `Install-LocalManifest` patches the apps'
Scoop metadata so the install looks (to `scoop update` and friends) as
if it had come from the registered `MarkMichaelis` bucket:

- `~/scoop/apps/<App>/current/install.json` — `bucket` field is stamped
  to `MarkMichaelis` (Scoop leaves it empty for file-path installs).
- `~/scoop/apps/<App>/current/manifest.json` — `url[]` entries are
  restored to canonical
  `https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/master/bucket/<leaf>`
  so future re-installs/updates fetch from the bucket, not your local
  working copy.

The patch is best-effort (`install.json` is Scoop's internal schema, no
public contract): missing files, malformed JSON, and absent app
directories emit a warning but never throw. Light unit coverage lives
in `bucket/LocalManifestInstallJson.Tests.ps1`.

**Version-skew caveat.** If your working copy's manifest carries a
higher version than master (typical mid-PR), `scoop update <App>` will
still say "up to date" until master catches up — Scoop compares the
canonical URL's content, not your working tree. Re-running
`Install-LocalManifest` is the right way to iterate; `scoop update` is
not.

### Heavy validate-installs — local cleanup (`-Cleanup`)

`Test-Installs.ps1` (the Heavy CI driver) installs every package in the
bucket to prove they work on a clean Windows Server. On hosted runners
the image is discarded at end-of-job so no cleanup is needed; if you
ever run the same script **locally** to debug a CI failure, every
successful install lingers on your dev box.

The opt-in `-Cleanup` switch fixes that:

```powershell
& .github\scripts\Test-Installs.ps1 -Cleanup
```

Behavior:

1. **Pre-install probe.** Before each install, the matching package
   manager is queried for the package at the same scope. If it was
   already there, the install proceeds (it's idempotent) but the
   package is **not** recorded for cleanup. Pre-existing user state is
   never touched.
2. **Install ledger.** Each install that the run *actually added* is
   appended to a JSON ledger
   (default: `$env:TEMP\ScoopBucket-Cleanup-Ledger.json`).
3. **End-of-run uninstall.** Inside the script's `finally` block, every
   ledger entry is uninstalled via the same package manager and scope
   that produced it (`winget uninstall --scope <scope>`,
   `choco uninstall`, `scoop uninstall -g`, `Uninstall-Module`).
4. **Crash recovery.** If a `-Cleanup` run aborts mid-flight (Ctrl+C,
   OOM, runner cancellation), the ledger file survives on disk. The
   next `-Cleanup` invocation replays it *before* discovery, so you
   restart from a known-clean state.

**Already-installed semantics:**

| Case | Behavior |
|---|---|
| Package was on host before the run, same manager + scope | Probe sees it → no ledger entry → cleanup leaves it. |
| Package was on host via a *different* manager (e.g. choco-installed 7zip vs winget bucket) | Each manager only sees its own database. Cleanup uninstalls only what *our* manager installed, against its own database. The other manager's copy is untouched. |
| Package installed at a different scope than what the bundle requested | Probe is scope-scoped; cleanup uninstalls only at the scope we recorded. |

**Why CI does not pass `-Cleanup`.** The workflow's subsequent steps
("Apply post-install hooks", "CLI availability discovery", "CLI
availability — pinned contract") all read from the installs left by
Test-Installs.ps1. Uninstalling between them would break the contract
checks. Runners are ephemeral so no state leaks anyway. `-Cleanup` is
a dev-box convenience, not a CI invariant.

Light unit coverage lives in
`.github/scripts/Test-InstallsCleanup.Tests.ps1`.

