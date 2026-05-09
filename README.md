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

## Testing

A per-package functional-test framework based on Pester is in development
(see `*.Tests.ps1` files alongside each manifest). Until the shared helper
lands, the simplest pre-push check is:

```powershell
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 1st run
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 2nd run — must succeed
```
