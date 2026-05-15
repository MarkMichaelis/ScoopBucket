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
```

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
  story, register it via
  [`PSCompletions`](https://github.com/abgox/PSCompletions). Completion
  registration belongs in the bundle's `.ps1` (idempotent — guard so
  re-runs don't double-register).

### CLI-availability discovery (in progress)

See #45 for the tracking issue. Rolling out in three phases:

- **Phase 1 — Local discovery.** A `Get-PackageCommands.ps1` helper
  parses every `bucket\*.ps1` for winget / scoop / choco / module
  install patterns, derives a probable CLI short name per package, runs
  `Get-Command` against it, and writes `cli-availability.json`.
- **Phase 2 — CI integration.** A Pester `Heavy`-tagged test
  (`bucket\PackageCommands.Tests.ps1`) runs the discovery script after
  the validate-installs job, uploads `cli-availability.json` as an
  artifact, and posts a Markdown summary to `GITHUB_STEP_SUMMARY`. The
  test does **not** fail the build at this phase — it only reports.
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
(currently `bw`, `copilot`, `gcloud` — see #73) deliberately have no
`-NativeCommand` wiring. They receive completion via the PSCompletions
fallback below, and `Register-CliCompletion` will emit a
`Write-Warning` if a future change re-introduces a dead native
command (silent dead wiring would otherwise hide).

Bundles that install many CLIs (`AIAgents`, `ClientBasePackages`,
`DeveloperBasePackages`) additionally call `Invoke-CliCompletionsSweep
-Force` at the end of their install, which (a) ensures the
[`PSCompletions`](https://github.com/abgox/PSCompletions) module is
installed and (b) registers a PSCompletions-fallback block for any CLI
on `PATH` whose owning bundle didn't supply a native command. To
re-run the sweep manually after installing other tools by hand:

```powershell
Import-Module D:\Git\ScoopBucket\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1 -Force
Invoke-CliCompletionsSweep -Force
```

Behavior:

- Each CLI is resolved in order: caller-supplied `-NativeCommand`
  scriptblock (owned by the install script) → `PSCompletions`
  (`abgox/PSCompletions`) fallback → skipped with a reason.
- All registrations are written as sentinel-delimited blocks
  (`# ScoopBucket:CliCompletion:<cli>:BEGIN v1 … :END`) inside
  `$PROFILE.AllUsersAllHosts`. Two runs with `-Force` produce a
  byte-identical profile.
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

A per-package functional-test framework based on Pester is in development
(see `*.Tests.ps1` files alongside each manifest). Until the shared helper
lands, the simplest pre-push check is:

```powershell
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 1st run
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 2nd run — must succeed
```
