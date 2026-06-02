# Fix #295 -- Relocate version-less PSCompletionsCatalog.json out of bucket/

Date: 2026-06-02

## Problem
`bucket/PSCompletionsCatalog.json` is a generated data snapshot (keys: Source,
RefreshScript, Completions) with no top-level `version`. Scoop treats every
`bucket/*.json` as a manifest and reads `version` via the non-Try
`GetProperty('version')`, which throws on this file. The module `scoop`
wrapper resolves bare app names via `scoop search ... -PSCustomObject`, hits
this file, and crashes.

## Fix
Move the snapshot out of `bucket/` to `data/PSCompletionsCatalog.json` at the
repo root (a non-bucket data location). Nothing loads it at runtime; only the
generator script writes it and Bundles.Tests.ps1 reads it.

## Tasks
1. (Red) Add `bucket/BucketManifestVersion.Tests.ps1`: assert every `*.json`
   directly in `bucket/` parses and has a non-empty top-level `version` string,
   plus a regression test emulating Scoop's `GetProperty('version')` via
   System.Text.Json so a version-less file throws the same key error. With the
   file still in bucket/, the test FAILS naming PSCompletionsCatalog.json.
2. (Green) `git mv bucket/PSCompletionsCatalog.json data/PSCompletionsCatalog.json`.
3. Update `.github/scripts/Update-PSCompletionsCatalog.ps1` `$OutPath` ->
   `data/PSCompletionsCatalog.json`; update synopsis/Write-Host wording.
4. Update `bucket/Bundles.Tests.ps1` path resolution (~line 179) to resolve
   `data/PSCompletionsCatalog.json` from the repo root, and the skip message.
5. Run Pester on the new + affected test files; confirm green.
6. Confirm no version-less `.json` remains in `bucket/`.

## References checked
Grep `PSCompletionsCatalog` -> only the 3 files above. No workflow references.

## Verification
- pwsh -File bucket/Invoke-Tests.ps1 -Pattern BucketManifestVersion -Tag All
- pwsh -File bucket/Invoke-Tests.ps1 -Pattern Bundles -Tag All
