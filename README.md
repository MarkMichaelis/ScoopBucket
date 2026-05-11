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
etc.). Shared helpers live in `bucket/Utils.ps1`, which every bundle
script dot-sources at the top.

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
  file the manifest references — `.ps1`, `Utils.ps1`, embedded configs,
  anything in the manifest's `url` array). Reset patch to `000`.
- **major** — reserved for breaking changes to a bundle's contract.

If a single change touches files referenced by multiple manifests (e.g.
`Utils.ps1`), bump every affected manifest. The version bump must be in
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
> `.ps1` dot-sources (e.g. `Utils.ps1`), the helper must be declared in
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

Every bundle that installs CLI tools (`AIAgents`, `ClientBasePackages`,
`DeveloperBasePackages`) calls `Register-AllCliCompletions -Force` after
its installs run, so a fresh `scoop install` of any of these bundles
leaves a usable PowerShell tab-completion experience in place without an
extra opt-in step.

The standalone `CliCompletions` bundle exists for retroactive coverage —
install (or `scoop update CliCompletions`) at any time to scan every CLI
already on `PATH` and register completion for it. The bundle exposes a
`register-all-cli-completions` shim so you can re-run it on demand.

Behavior:

- Each CLI is resolved in order: built-in PowerShell-shell completion
  command (curated map in `Utils.ps1`) → `PSCompletions` (`abgox/PSCompletions`)
  fallback → skipped with a reason.
- All registrations are written as sentinel-delimited blocks
  (`# ScoopBucket:CliCompletion:<cli>:BEGIN v1 … :END`) inside
  `$PROFILE.AllUsersAllHosts`. Two runs with `-Force` produce a
  byte-identical profile.
- `-Force` is opt-in for ad-hoc invocations (`register-all-cli-completions`
  defaults to gap-fill only); the bundle installers pass `-Force`
  explicitly so reinstalls always refresh blocks.
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
