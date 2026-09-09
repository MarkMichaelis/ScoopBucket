---
description: 'Project-specific instructions and conventions. Edit this file in the consuming project; it is never overwritten by Pull-SDLC.ai.ps1.'
applyTo: '**/*'
---

<!--
This file is OWNED BY THE CONSUMING PROJECT.

It was created from `project.instructions.md.template` (shipped by
IntelliSDLC.ai) and is never modified by `Pull-SDLC.ai.ps1`.

Use this file for ANY project-specific guidance that AI agents should follow.
The upstream instruction files (`CLAUDE.md`, `.github/copilot-instructions.md`,
`.github/agents/*`, generic `.github/instructions/*`, `.github/skills/*`) must
NOT contain project-specific content -- put it here instead.
-->

# Project Instructions

## Project Overview

ScoopBucket is a personal [Scoop](https://scoop.sh/) bucket of Windows
install/configuration scripts: base package bundles for client, developer, and
AI workflows; an `AIAgents` bundle that wires up Claude/ChatGPT/Gemini/Microsoft
Copilot plus a curated set of MCP servers; and miscellaneous one-shot system
configurations. The target user is a Windows developer bootstrapping a fresh
machine from `install.ps1`.

## Architecture

- `bucket/<category>/` -- Scoop manifests (`*.json`) paired with the PowerShell
  script they install (`*.ps1`) and their Pester tests (`*.Tests.ps1`).
  Categories: `admin`, `ai`, `client`, `developer`, `os`.
- `bucket/*.Tests.ps1` (category-less) -- cross-cutting guard suites that assert
  invariants over the whole bucket: structure, manifest version bumps, bundle
  module-import drift, completion coverage.
- `module/MarkMichaelis.ScoopBucket/` -- the shared PowerShell module every
  script imports via the standard `#region ... bundle module import` header.
- Bundle scripts (`OSBasePackages`, `DeveloperBasePackages`, `ClientBasePackages`,
  `AIAgents`) are the opt-in entry points; individual configurators are
  installable on their own and are also dot-sourced from a bundle.

## Tech Stack

| Layer            | Technology |
|------------------|------------|
| Language/Runtime | PowerShell 7+ (pwsh) on Windows |
| Packaging        | Scoop manifests; Chocolatey, winget, and `Install-Module` as install backends |
| Testing          | Pester v5+ (v6 locally), tag-partitioned `Light` / `Heavy` / `Install` |

## Build, Test, Format

There is no compile step. The test suite is the build.

```powershell
# Fast pre-push gate (what CI's "Light suite" runs)
.\bucket\Invoke-Tests.ps1

# Full integration run -- installs/uninstalls real packages; only on a real dev machine
.\bucket\Invoke-Tests.ps1 -Tag Heavy,Install

# One manifest's tests
.\bucket\Invoke-Tests.ps1 -Pattern <ManifestName> -Tag All

# Manifest version-bump guard (also enforced in CI)
.\Test-ManifestVersionBumps.ps1
```

**Gotcha:** CI runs only the `Light` tag. `Heavy` / `Install` tests -- which is
where `Install-LocalManifest` coverage lives -- never run in CI, so run them
locally before merging any change to a manifest or its installer script.

## Run / Debug

Register the bucket's module against the working tree, then invoke a configurator
directly:

```powershell
.\Register-BucketModule.ps1
& .\bucket\<category>\<Name>.ps1
```

Scripts self-invoke their `Invoke-<Name>` function on the last line of the file,
so dot-sourcing one runs it.

## Key Conventions

Only deviations from and additions to the upstream conventions:

### PR review is done by an Anthropic model, not Copilot

This project **replaces** the `@copilot` review step in the upstream dev loop
(Phase 7, `dev-loop.agent.md` Step 5, and the corresponding
`dev-loop-phase-gate` checklist item). Do **not** run
`gh pr edit <pr-number> --add-reviewer "@copilot"`.

Instead, review every PR with an Anthropic model **other than the one that wrote
the code**, dispatched as a subagent:

- Determine the authoring model from the `Co-Authored-By:` trailer on the
  branch's commits.
- Spawn a review subagent with an explicit `model` override naming a *different*
  Anthropic model (e.g. code written by Opus 5 is reviewed by Sonnet 5).
- Give the reviewer the diff (`git diff main...HEAD`), the linked issue, the
  sibling files that establish the pattern being followed, and any behavior
  already verified by hand, so it spends its effort on uncovered paths.
- Treat its findings as the upstream loop treats Copilot threads: fix, push, and
  re-review until a review introduces zero new findings. Report the findings to
  the user rather than silently acting on all of them -- a subagent's findings
  are not automatically correct.

**Why:** Copilot review adds little on a PowerShell/Scoop codebase whose
correctness lives in shell quoting, idempotency, and Pester tagging, and a model
reviewing its own output reproduces its own blind spots. A second, different
model reads the diff cold.

The rest of Phase 7 is unchanged: CI must be green, the dry run must pass, and
merges are rebase-only via `gh pr merge <n> --rebase --delete-branch`.

### Idempotency contract

**Every script in this bucket must be safely re-runnable** -- a second
invocation must not throw and must not create duplicate links, files, registry
entries, or profile imports. See the "Idempotency contract" section of
`README.md` for the full contract and the patterns that honor it (guarded
`New-Item`, always `git config --global`, `-y`/`--silent` on package managers,
`Get-Command` early-exit guards, read-mutate-write for config files). Run any
new or changed script **twice** locally before pushing.

### Manifest changes require a version bump

Any change to a `bucket/**/*.ps1` shipped by a manifest requires bumping the
`version` in every manifest whose `url` list includes that file -- including
bundle manifests that ship it transitively. `Test-ManifestVersionBumps.ps1`
enforces this and CI fails without it. Versions are `M.NN.000`.

### New configurator checklist

A new configurator ships alongside its siblings in one `bucket/<category>/`
directory: `<Name>.ps1`, `<Name>.json`, `<Name>.Tests.ps1`, plus any data file it
reads. The `.ps1` opens with the verbatim bundle module-import header (copied
from a sibling -- `BundleModuleImportDrift.Tests.ps1` counts the occurrences and
must be updated), guards on `Get-Command <tool>` and warns-and-returns when the
tool is absent, and self-invokes its `Invoke-<Name>` function on the last line.
Every file it needs at runtime must appear in the manifest's `url` list, since
Scoop downloads only the listed files into the app dir.

## Domain Glossary

- **Bundle** -- a manifest whose script dot-sources several individual
  configurators (e.g. `DeveloperBasePackages`, `AIAgents`). Installed by users
  directly; the constituent configurators are also individually installable.
- **Configurator** -- a single-purpose script that configures an already-installed
  tool rather than installing it (e.g. `GitConfigVSCode`, `GitConfigGitHubCli`).
- **Companion** -- a configurator dot-sourced by a parent script, following the
  parent's naming prefix (`GitConfigure` -> `GitConfig*`).
- **Sidecar** -- a generated completion script written alongside a registered CLI
  completion.
- **Light / Heavy / Install** -- Pester tags. `Light` is side-effect-free and runs
  in CI; `Heavy` and `Install` mutate the machine and run only locally.

## External Dependencies & Secrets

No secrets live in the repo. Scripts shell out to `choco`, `scoop`, `winget`, and
`gh`; `gh` relies on the developer's existing `gh auth login` credentials, and
per-user tool config (e.g. `%APPDATA%\GitHub CLI\config.yml`, `~\.gitconfig`) is
treated as user state the scripts provision but never overwrite wholesale.

## Known Limitations / Don'ts

- Never edit upstream-managed files (`CLAUDE.md`, `.github/copilot-instructions.md`,
  `.github/agents/*`, `.github/skills/*`, and `.github/instructions/*` other than
  this file). Changes there belong in the IntelliSDLC.ai repo.
- Do not assume CI green means the change is verified -- CI runs `Light` only.
- Do not use bare `git config`; always `git config --global`.
