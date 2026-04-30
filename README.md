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

## Testing

A per-package functional-test framework based on Pester is in development
(see `*.Tests.ps1` files alongside each manifest). Until the shared helper
lands, the simplest pre-push check is:

```powershell
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 1st run
pwsh -NoProfile -File D:\Git\ScoopBucket\bucket\<Name>.ps1   # 2nd run — must succeed
```
