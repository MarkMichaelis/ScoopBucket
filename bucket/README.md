# Bucket layout

This bucket is organised by **package group**. The four group-defining
aggregator bundles live at the bucket root and act as the table of contents;
their member manifests, helper scripts, and member-specific tests live in
group subfolders.

```
bucket/
  OSBasePackages.{json,ps1}          # 4 aggregator bundles (root = table of contents)
  ClientBasePackages.{json,ps1}
  DeveloperBasePackages.{json,ps1}
  AIAgents.{json,ps1}
  os/          OS tweaks + their *.Tests.ps1
  client/      client apps + their *.Tests.ps1
  developer/   dev tools / shells / git-config + their *.Tests.ps1
  ai/          AI assistant apps + their *.Tests.ps1
  admin/       bucket-bootstrap manifests (infrastructure, NOT an installable group)
  *.Tests.ps1  bucket-wide / aggregator-level tests (subject = the whole bucket)
  README.md
```

## Groups

| Group | Folder | Aggregator | Contents |
|-------|--------|-----------|----------|
| OS | `os/` | `OSBasePackages` | OS configuration tweaks (power, hibernate, OneDrive, McAfee removal, key remap) |
| Client | `client/` | `ClientBasePackages` | End-user apps (Office, Dropbox CLI, Lightroom, Overdrive, SmugMug, Total Commander, Epubor) |
| Developer | `developer/` | `DeveloperBasePackages` | Dev tools, PowerShell editions, WSL, git config, Visual Studio, .NET |
| AI | `ai/` | `AIAgents` | AI assistant apps and CLIs (Claude, ChatGPT, Gemini, Copilot, Codex) |
| Admin | `admin/` | _(none)_ | Bucket-bootstrap manifests + the `Invoke-GitDiffCode` helper. Infrastructure, not installed by any bundle. |

`AIAgents` is nested under `ClientBasePackages`.

## Conventions

- **Aggregators stay at root.** A manifest's basename **is** its scoop app name,
  so the four group definitions cannot be renamed or prefixed to sort first.
  Keeping them at root keeps the group definitions visible together.
- **Basenames are globally unique** across all folders and are never renamed
  (`scoop install <Name>` and installed app dirs resolve by basename).
- **Scoop recurses subfolders**, so foldering members does not affect
  `scoop install` / `scoop update` or nested bundle references
  (`Id = 'MarkMichaelis/<Name>'`).
- **Tests live beside their subject.** Member-manifest tests sit in the group
  folder with the manifest. Aggregator-level and bucket-wide tests
  (those that use `Get-Package -BucketPath $PSScriptRoot` against a root
  aggregator) stay at the bucket root.
- **`url[]` self-references** in each manifest must point at the script's real
  on-disk path (enforced by `ManifestUrlSelfReferences.Tests.ps1`). When a
  script moves into a group folder, every manifest `url[]` that downloads it is
  repointed to `bucket/<group>/<script>.ps1`.
- **`_placeholder`** (a shared no-op download target) stays at root.

The structure is enforced by `BucketStructure.Tests.ps1`: only the four
aggregators may sit at bucket root, and every other manifest must live directly
under a known group folder.
