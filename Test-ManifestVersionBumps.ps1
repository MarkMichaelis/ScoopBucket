<#
.SYNOPSIS
    Verify (and optionally auto-fix) that every Scoop manifest's `version`
    has been bumped whenever any file the manifest references was modified.

.DESCRIPTION
    Enforces the rule documented in README -> Manifest versioning:

        Whenever any file referenced by a bundle's manifest is modified
        (its .ps1, helpers it dot-sources, embedded
        configs, anything in the manifest's `url` array), the
        major.minor.patch `version` field in the .json must be bumped:

          - patch (3 digits) -> bug fix that doesn't change packages
          - minor (2 digits) -> any other change to a referenced file
                                (resets patch to 000)
          - major             -> breaking change to the bundle's contract

    This script is the durable record's only consumer: it derives all
    state at runtime from `git log` / `git status`. There is no separate
    hash lockfile.

    Modes:

      -CheckOnly  (default) Report violations and exit non-zero.
      -Fix                  Auto-bump the minor segment of each violating
                            manifest, preserving padding and UTF-8 BOM,
                            and `git add` the change.
      -Amend                After -Fix, run `git commit --amend --no-edit`
                            so the bumps fold into the most recent commit.
      -Push                 After -Amend, run `git push --force-with-lease`
                            to publish the corrected commit. (CI use.)

    On -CheckOnly failure, an informational banner points the user at
    -Fix and the opt-in pre-push hook
    (`git config core.hooksPath .githooks`).

.PARAMETER Fix
    Apply minor-version bumps to violating manifests and stage them.

.PARAMETER Amend
    Implies -Fix. After bumping, fold the staged changes into HEAD via
    `git commit --amend --no-edit`. Safe only when the developer (or CI)
    intends to amend the most recent commit on the current branch.

.PARAMETER Push
    Implies -Amend. After amending, run
    `git push --force-with-lease origin HEAD:<branch>`.
    Used by CI's verify-versions job; not appropriate for local dev.

.PARAMETER Branch
    Branch to push when -Push is set. Defaults to the current branch
    (`git rev-parse --abbrev-ref HEAD`).

.PARAMETER RepoRoot
    Repository root to operate against. Defaults to this script's
    directory.

.EXAMPLE
    pwsh -File .\Test-ManifestVersionBumps.ps1
    # Read-only check; exits 1 with an instructional banner if any
    # manifest is missing a bump.

.EXAMPLE
    pwsh -File .\Test-ManifestVersionBumps.ps1 -Fix
    # Bumps minor segments for any violating manifests and stages
    # them with `git add`. You then commit normally; the staged bump
    # rides along.

.EXAMPLE
    pwsh -File .\Test-ManifestVersionBumps.ps1 -Amend
    # Pre-push hook flow: bump, stage, and amend HEAD so the corrected
    # commit is what gets pushed.
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Amend,
    [switch]$Push,
    [string]$Branch,
    [string]$RepoRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

if ($Push)  { $Amend = $true }
if ($Amend) { $Fix   = $true }

$BucketDir = Join-Path $RepoRoot 'bucket'
$RawUrlPrefix = 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/master/'

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$GitArgs, [switch]$AllowFailure)
    Push-Location $RepoRoot
    try {
        $output = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0 -and -not $AllowFailure) {
            throw "git $($GitArgs -join ' ') failed (exit $code): $output"
        }
        return ,@($output)
    } finally {
        Pop-Location
    }
}

function Get-RelatedFiles {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $manifestRel = Resolve-RepoRelative $ManifestPath
    $files = New-Object System.Collections.Generic.List[string]
    [void]$files.Add($manifestRel)

    $json = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
    $urls = @()
    if ($json.PSObject.Properties.Name -contains 'url') {
        $urls = @($json.url)
    }
    foreach ($u in $urls) {
        if (-not $u) { continue }
        if ($u.StartsWith($RawUrlPrefix)) {
            $rel = $u.Substring($RawUrlPrefix.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $abs = Join-Path $RepoRoot $rel
            if (Test-Path -LiteralPath $abs) {
                if (-not $files.Contains($rel)) { [void]$files.Add($rel) }
            }
        }
    }

    # The shared module is an IMPLICIT dependency of every bundle manifest:
    # each bundle .ps1 opens with the Import-Module preamble, so a change to
    # an engine (Install-WingetPackage, Invoke-PackageInstall, ...) changes
    # what every bundle does at install time -- without touching any file in
    # the manifest's own `url` array.
    #
    # That matters for delivery, not just bookkeeping: `scoop update` returns
    # early when the manifest version is unchanged (scoop-update.ps1), so a
    # module fix that never bumps a manifest never reaches an installed
    # machine. Treating the module tree as a related file is what turns
    # "module behavior changed" into a version bump users actually receive.
    #
    # Tests are excluded: they don't ship in the install path, so a
    # test-only edit legitimately needs no bump. See #401.
    #
    # The module is NOT expanded file-by-file here. Its ~370 files are related
    # to all 36 manifests identically, so per-file git queries would run the
    # same lookups 36 times over -- minutes of wall clock in a pre-push hook.
    # Get-ModuleChangeAggregate answers "did the shipped module change?" in two
    # git calls for the whole run; Get-ManifestViolation applies it per
    # manifest.
    return $files
}

# "Did the shipped module change, and when?" -- computed once per run.
#
# Two git calls (status + log) with a pathspec that excludes tests, instead of
# two per module file per manifest. Returns the newest commit touching the
# module and whether it has uncommitted edits.
$script:ModuleChangeCache = $null
function Get-ModuleChangeAggregate {
    if ($null -ne $script:ModuleChangeCache) { return $script:ModuleChangeCache }

    $pathspec = @('module/', ':(exclude)module/**/*.Tests.ps1')

    $status = Invoke-Git -GitArgs (@('status', '--porcelain', '--') + $pathspec) -AllowFailure
    $dirtyLine = $status |
        ForEach-Object { [string]$_ -split "`n" } |
        Where-Object { $_.Trim() } |
        Select-Object -First 1

    $log = Invoke-Git -GitArgs (@('log', '-1', '--format=%H', '--') + $pathspec) -AllowFailure
    $sha = $log |
        ForEach-Object { [string]$_ -split '\s+' } |
        Where-Object { $_ -match '^[0-9a-f]{7,40}$' } |
        Select-Object -First 1

    $script:ModuleChangeCache = [pscustomobject]@{
        IsDirty    = [bool]$dirtyLine
        DirtyHint  = if ($dirtyLine) { ([string]$dirtyLine).Trim() } else { $null }
        LastCommit = $sha
    }
    return $script:ModuleChangeCache
}

function Resolve-RepoRelative {
    param([Parameter(Mandatory)][string]$Path)
    $full = (Resolve-Path -LiteralPath $Path).Path
    $root = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' is not under repo root '$root'."
    }
    return $full.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
}

# Newest commit in which this manifest's version VALUE actually changed.
#
# Not `git log -L /"version"/,+1:<file>`: -L tracks a moving line RANGE, so any
# edit that shifts lines around the version line gets attributed to that line
# even when the version string itself is untouched. That produced a silent
# false negative -- edit a manifest, skip the bump, and the check passed
# because the "bump commit" and the "file changed" commit were the same sha.
# Compare the parsed value against the parent instead; only a real value
# change counts. See #401.
function Get-LastVersionLineCommit {
    param([Parameter(Mandatory)][string]$ManifestRel)
    $relForGit = $ManifestRel -replace '\\','/'

    # Invoke-Git can hand back all of git's stdout as ONE string rather than a
    # line per object, so split before matching or every sha is filtered out
    # and the walk below silently finds nothing.
    $commits = @(Invoke-Git -GitArgs @('log', '--format=%H', '--', $relForGit) -AllowFailure |
        ForEach-Object { [string]$_ -split '\s+' } |
        Where-Object { $_ -match '^[0-9a-f]{7,40}$' })

    foreach ($sha in $commits) {
        $now = Get-ManifestVersionAt -Commit $sha    -RelForGit $relForGit
        $was = Get-ManifestVersionAt -Commit "$sha^" -RelForGit $relForGit
        # $was is $null when the manifest was ADDED in this commit -- that
        # first appearance is itself the version's origin.
        if ($now -ne $was) { return $sha }
    }
    return $null
}

# Parsed `version` value of a manifest at a given commit, or $null when the
# path does not exist there (or the blob does not parse).
function Get-ManifestVersionAt {
    param([Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$RelForGit)
    $blob = Invoke-Git -GitArgs @('show', "${Commit}:${RelForGit}") -AllowFailure
    if ($LASTEXITCODE -ne 0 -or -not $blob) { return $null }
    try { return ((($blob -join "`n") | ConvertFrom-Json).version) } catch { return $null }
}

function Get-LastTouchedCommit {
    param([Parameter(Mandatory)][string]$RelPath)
    if ($script:LastTouchedCache.ContainsKey($RelPath)) { return $script:LastTouchedCache[$RelPath] }

    $relForGit = $RelPath -replace '\\','/'
    $out = Invoke-Git -GitArgs @('log', '-1', '--follow', '--format=%H', '--', $relForGit) -AllowFailure
    $sha = ($out | ForEach-Object { [string]$_ -split '\s+' } |
        Where-Object { $_ -match '^[0-9a-f]{7,40}$' } | Select-Object -First 1)

    $script:LastTouchedCache[$RelPath] = $sha
    return $sha
}

function Test-IsAncestor {
    param([Parameter(Mandatory)][string]$Maybe, [Parameter(Mandatory)][string]$Of)
    if (-not $Maybe -or -not $Of) { return $false }
    if ($Maybe -eq $Of) { return $true }
    $null = Invoke-Git -GitArgs @('merge-base','--is-ancestor', $Maybe, $Of) -AllowFailure
    return ($LASTEXITCODE -eq 0)
}

# Per-path git lookups, memoized.
#
# Every bundle manifest shares the same ~370-file module tree as related
# files, so without caching each of those files is re-queried once per
# manifest -- tens of thousands of git invocations, minutes of wall clock,
# and a pre-push hook that times out. The answers are identical across
# manifests within a single run, so compute each path once. See #401.
$script:DirtyCache       = @{}
$script:LastTouchedCache = @{}

function Test-IsWorkingTreeDirty {
    param([Parameter(Mandatory)][string]$RelPath)
    if ($script:DirtyCache.ContainsKey($RelPath)) { return $script:DirtyCache[$RelPath] }

    $relForGit = $RelPath -replace '\\','/'
    $out = Invoke-Git -GitArgs @('status','--porcelain','--', $relForGit) -AllowFailure
    $result = ($null -ne ($out | Where-Object { $_ -and ($_.ToString().Trim().Length -gt 0) }))

    $script:DirtyCache[$RelPath] = $result
    return $result
}

function Test-IsManifestVersionLineDirty {
    param([Parameter(Mandatory)][string]$ManifestRel)
    $relForGit = $ManifestRel -replace '\\','/'
    $out = Invoke-Git -GitArgs @('diff','HEAD','--unified=0','--', $relForGit) -AllowFailure
    return ($null -ne ($out | Where-Object { $_ -match '^[+-]\s*"version"\s*:' }))
}

function Get-ManifestViolation {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $manifestRel = Resolve-RepoRelative $ManifestPath
    $related     = Get-RelatedFiles -ManifestPath $ManifestPath
    $bumpCommit  = Get-LastVersionLineCommit -ManifestRel $manifestRel

    $violatingFiles = New-Object System.Collections.Generic.List[string]
    $reasons        = New-Object System.Collections.Generic.List[string]

    $versionLineDirty = Test-IsManifestVersionLineDirty -ManifestRel $manifestRel

    # If the developer (or a previous -Fix invocation in this session) has
    # edited the manifest's "version" line in the working tree, the rule is
    # already satisfied for this manifest — a pending bump will land in the
    # next commit. No violations to report.
    if ($versionLineDirty) {
        return [pscustomobject]@{
            ManifestPath   = $ManifestPath
            ManifestRel    = $manifestRel
            BumpCommit     = $bumpCommit
            ViolatingFiles = $violatingFiles
            Reasons        = $reasons
            IsViolation    = $false
        }
    }

    foreach ($rel in $related) {
        $rel = $rel -replace '/','\'

        if (Test-IsWorkingTreeDirty -RelPath $rel) {
            [void]$violatingFiles.Add($rel)
            [void]$reasons.Add("$rel has uncommitted changes but $manifestRel `"version`" is unchanged in working tree")
            continue
        }

        $fileCommit = Get-LastTouchedCommit -RelPath $rel
        if (-not $fileCommit) { continue }
        if (-not $bumpCommit) { continue }
        if ($fileCommit -eq $bumpCommit) { continue }

        if (-not (Test-IsAncestor -Maybe $fileCommit -Of $bumpCommit)) {
            [void]$violatingFiles.Add($rel)
            [void]$reasons.Add("$rel last changed at $($fileCommit.Substring(0,7)) but $manifestRel `"version`" was last bumped at $($bumpCommit.Substring(0,7)) (older)")
        }
    }

    # The shared module, applied as one aggregate rather than ~370 related
    # files (see Get-ModuleChangeAggregate). Every bundle .ps1 imports it, so a
    # change to an engine changes what every bundle does at install time
    # without touching anything in the manifest's own url array -- and since
    # `scoop update` returns early on an unchanged version, a module fix with
    # no bump never reaches an installed machine. See #401.
    $moduleChange = Get-ModuleChangeAggregate
    if ($moduleChange.IsDirty) {
        [void]$violatingFiles.Add('module\')
        [void]$reasons.Add("module has uncommitted changes ($($moduleChange.DirtyHint)) but $manifestRel `"version`" is unchanged in working tree")
    } elseif ($moduleChange.LastCommit -and $bumpCommit -and
              $moduleChange.LastCommit -ne $bumpCommit -and
              -not (Test-IsAncestor -Maybe $moduleChange.LastCommit -Of $bumpCommit)) {
        [void]$violatingFiles.Add('module\')
        [void]$reasons.Add("module last changed at $($moduleChange.LastCommit.Substring(0,7)) but $manifestRel `"version`" was last bumped at $($bumpCommit.Substring(0,7)) (older)")
    }

    return [pscustomobject]@{
        ManifestPath   = $ManifestPath
        ManifestRel    = $manifestRel
        BumpCommit     = $bumpCommit
        ViolatingFiles = $violatingFiles
        Reasons        = $reasons
        IsViolation    = ($violatingFiles.Count -gt 0)
    }
}

function Step-VersionMinor {
    param([Parameter(Mandatory)][string]$Version)
    if ($Version -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
        throw "Version '$Version' does not match major.minor.patch."
    }
    $major = [int]$Matches.major
    $minor = [int]$Matches.minor + 1
    $minorWidth = [Math]::Max(2, $Matches.minor.Length)
    return ('{0}.{1}.{2}' -f $major, $minor.ToString().PadLeft($minorWidth, '0'), '000')
}

function Set-ManifestVersion {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$NewVersion
    )
    $bytes  = [System.IO.File]::ReadAllBytes($ManifestPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text   = [System.IO.File]::ReadAllText($ManifestPath)
    $newText = [regex]::Replace(
        $text,
        '("version"\s*:\s*")[^"]+(")',
        { param($m) $m.Groups[1].Value + $NewVersion + $m.Groups[2].Value },
        [System.Text.RegularExpressions.RegexOptions]::None,
        [TimeSpan]::FromSeconds(2))
    if ($newText -eq $text) {
        throw "Failed to update version in $ManifestPath."
    }
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($ManifestPath, $newText, $enc)
}

function Write-FixHint {
    Write-Host ''
    Write-Host '[INFO] These violations can be auto-corrected by re-running with the' -ForegroundColor Cyan
    Write-Host '       -Fix switch:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '           pwsh -NoProfile -File ./Test-ManifestVersionBumps.ps1 -Fix' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '       -Fix bumps the minor segment of each affected manifest, stages' -ForegroundColor Cyan
    Write-Host '       the change with `git add`, and (with -Amend) folds it into the' -ForegroundColor Cyan
    Write-Host '       most recent commit. You can also enable the opt-in pre-push hook' -ForegroundColor Cyan
    Write-Host '       so this happens automatically on every push:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '           git config core.hooksPath .githooks' -ForegroundColor Cyan
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path $BucketDir)) {
    throw "Bucket directory not found: $BucketDir"
}

# -Recurse: manifests live both at bucket/ root (the bundles) and in the
# foldered subdirectories (bucket/ai, bucket/admin, bucket/client, bucket/os).
# Without it the foldered set was never version-checked at all, so a change to
# e.g. bucket/ai/ChatGPT.ps1 shipped with a stale manifest version -- and
# `scoop update ChatGPT` returns early on an unchanged version, so the change
# never reached an installed machine. See #401.
$manifests = Get-ChildItem -Path $BucketDir -Filter '*.json' -Recurse | ForEach-Object {
    $j = $null
    try { $j = Get-Content -Raw -Path $_.FullName | ConvertFrom-Json } catch { return }
    if ($null -eq $j) { return }
    $hasInstaller = $j.PSObject.Properties.Name -contains 'installer' -and
                    $j.installer -and
                    ($j.installer.PSObject.Properties.Name -contains 'script')
    if (-not $hasInstaller) { return }
    [pscustomobject]@{ Path = $_.FullName; Name = $_.BaseName; Json = $j }
} | Where-Object { $_ }

$violations = @()
foreach ($m in $manifests) {
    $v = Get-ManifestViolation -ManifestPath $m.Path
    if ($v.IsViolation) { $violations += $v }
}

if (-not $violations) {
    Write-Host "All $($manifests.Count) manifest(s) have up-to-date version bumps." -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "Found $($violations.Count) manifest(s) with missing version bumps:" -ForegroundColor Yellow
foreach ($v in $violations) {
    Write-Host "  $($v.ManifestRel)" -ForegroundColor Yellow
    foreach ($r in $v.Reasons) { Write-Host "    - $r" }
}

if (-not $Fix) {
    Write-FixHint
    exit 1
}

# -Fix path
$fixed = @()
foreach ($v in $violations) {
    $current = (Get-Content -Raw -Path $v.ManifestPath | ConvertFrom-Json).version
    try {
        $new = Step-VersionMinor -Version $current
    } catch {
        Write-Warning "Skipping $($v.ManifestRel): $_"
        continue
    }
    Set-ManifestVersion -ManifestPath $v.ManifestPath -NewVersion $new
    [void](Invoke-Git -GitArgs @('add','--', ($v.ManifestRel -replace '\\','/')))
    Write-Host "  bumped $($v.ManifestRel): $current -> $new" -ForegroundColor Green
    $fixed += [pscustomobject]@{ Manifest = $v.ManifestRel; From = $current; To = $new }
}

if (-not $fixed) {
    Write-Warning 'No manifests were bumped (all violations were unfixable). Exiting non-zero.'
    exit 1
}

if ($Amend) {
    [void](Invoke-Git -GitArgs @('commit','--amend','--no-edit'))
    Write-Host 'Amended HEAD with version bump(s).' -ForegroundColor Green
}

if ($Push) {
    if (-not $Branch) {
        $Branch = (Invoke-Git -GitArgs @('rev-parse','--abbrev-ref','HEAD') | Select-Object -First 1).ToString().Trim()
    }
    [void](Invoke-Git -GitArgs @('push','--force-with-lease','origin', "HEAD:$Branch"))
    Write-Host "Force-pushed amended commit to origin/$Branch." -ForegroundColor Green
}

# Emit a structured summary for CI consumers (one JSON line on stdout).
$summary = [pscustomobject]@{
    Fixed  = $fixed
    Amended = [bool]$Amend
    Pushed  = [bool]$Push
}
$summary | ConvertTo-Json -Compress | Write-Output

exit 0
