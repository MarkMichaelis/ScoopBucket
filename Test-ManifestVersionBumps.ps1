<#
.SYNOPSIS
    Verify (and optionally auto-fix) that every Scoop manifest's `version`
    has been bumped whenever any file the manifest references was modified.

.DESCRIPTION
    Enforces the rule documented in README -> Manifest versioning:

        Whenever any file referenced by a bundle's manifest is modified
        (its .ps1, helpers it dot-sources such as Utils.ps1, embedded
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
    return $files
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

function Get-LastVersionLineCommit {
    param([Parameter(Mandatory)][string]$ManifestRel)
    $relForGit = $ManifestRel -replace '\\','/'
    $out = Invoke-Git -GitArgs @('log', '-L', "/`"version`"/,+1:$relForGit", '--pretty=format:%H', '-s', '-n', '1') -AllowFailure
    $sha = ($out | Where-Object { $_ -match '^[0-9a-f]{7,40}$' } | Select-Object -First 1)
    return $sha
}

function Get-LastTouchedCommit {
    param([Parameter(Mandatory)][string]$RelPath)
    $relForGit = $RelPath -replace '\\','/'
    $out = Invoke-Git -GitArgs @('log', '-1', '--follow', '--format=%H', '--', $relForGit) -AllowFailure
    $sha = ($out | Where-Object { $_ -match '^[0-9a-f]{7,40}$' } | Select-Object -First 1)
    return $sha
}

function Test-IsAncestor {
    param([Parameter(Mandatory)][string]$Maybe, [Parameter(Mandatory)][string]$Of)
    if (-not $Maybe -or -not $Of) { return $false }
    if ($Maybe -eq $Of) { return $true }
    $null = Invoke-Git -GitArgs @('merge-base','--is-ancestor', $Maybe, $Of) -AllowFailure
    return ($LASTEXITCODE -eq 0)
}

function Test-IsWorkingTreeDirty {
    param([Parameter(Mandatory)][string]$RelPath)
    $relForGit = $RelPath -replace '\\','/'
    $out = Invoke-Git -GitArgs @('status','--porcelain','--', $relForGit) -AllowFailure
    return ($null -ne ($out | Where-Object { $_ -and ($_.ToString().Trim().Length -gt 0) }))
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

$manifests = Get-ChildItem -Path $BucketDir -Filter '*.json' | ForEach-Object {
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
