<#
.SYNOPSIS
    Phase 1 CLI-availability discovery for the MarkMichaelis/ScoopBucket bucket.

.DESCRIPTION
    Parses every bucket\*.ps1 bundle script (excluding *.Tests.ps1) for
    package install commands across the four engines this bucket uses:

        - winget (`winget install ... --id <id>`, plus WinGetID = '<id>'
          hashtable values used by the bundle scripts' loop pattern)
        - scoop  (`scoop install [-g] [<bucket>/]<name>`)
        - choco  (`choco install [-y] <name>`)
        - PSGallery (`Install-Module -Name <name>`)

    For each discovered package, a probable short CLI name is computed via
    a hard-coded override map first, then by heuristic from the package
    identifier (last `.`-segment of a winget ID, lowercased; or the
    package name for scoop/choco/module installs).

    For each (Source, PackageId, ExpectedCli) tuple, `Get-Command` is used
    to determine whether the CLI is currently on PATH on this machine.
    Results are written to `cli-availability.json` in the repo root,
    printed as a Markdown table to stdout, and appended to the
    `GITHUB_STEP_SUMMARY` file when that env var is set.

    The script is idempotent and has no side effects beyond writing
    `cli-availability.json` (gitignored). It returns the array of records
    so callers (e.g. the Pester scaffold) can inspect them.

.PARAMETER BucketPath
    Path to the bucket directory containing the *.ps1 bundle scripts.
    Defaults to the bucket directory of the repo this script lives in.

.PARAMETER OutputJson
    Path for the JSON artifact. Defaults to `cli-availability.json` at
    the repo root.

.PARAMETER Quiet
    If set, suppress the Markdown table written to stdout. The JSON file
    and `GITHUB_STEP_SUMMARY` append are still produced.

.EXAMPLE
    pwsh -NoProfile -File .\.github\scripts\Get-PackageCommands.ps1
#>
[CmdletBinding()]
param(
    [string] $BucketPath,
    [string] $OutputJson,
    [switch] $Quiet
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $BucketPath)  { $BucketPath  = Join-Path $repoRoot 'bucket' }
if (-not $OutputJson)  { $OutputJson  = Join-Path $repoRoot 'cli-availability.json' }

# ---------------------------------------------------------------------------
# Override map: package identifier -> expected short CLI name (or $null when
# the package ships no CLI). Match is case-insensitive on the WinGetID, the
# scoop/choco package name, or the PSGallery module name.
# ---------------------------------------------------------------------------
$ExpectedCliOverrides = @{
    'cli/cli'                                              = 'gh'
    'GitHub.cli'                                           = 'gh'
    'Bitwarden.CLI'                                        = 'bw'
    'dotnet'                                               = 'dotnet'
    'Gyan.FFmpeg'                                          = 'ffmpeg'
    'ChrisBagwell.SoX'                                     = 'sox'
    'Microsoft.VisualStudioCode'                           = 'code'
    'Python.Python.3.14'                                   = 'python'
    'BurntSushi.ripgrep.MSVC'                              = 'rg'
    'ripgrep'                                              = 'rg'
    'sharkdp.bat'                                          = 'bat'
    'bat'                                                  = 'bat'
    'junegunn.fzf'                                         = 'fzf'
    '7Zip.7Zip'                                            = '7z'
    'Google.CloudSDK'                                      = 'gcloud'
    'GitHub.Copilot'                                       = 'copilot'
    'GitKraken.cli'                                        = 'gk'
    'voidtools.Everything.Cli'                             = 'es'
    'Microsoft.WindowsTerminal'                            = 'wt'
    'nodejs'                                               = 'node'
    'exiftool'                                             = 'exiftool'
    'dbxcli'                                               = 'dbxcli'
    'eSpeak-NG.eSpeak-NG'                                  = 'espeak-ng'
    'ScooterSoftware.BeyondCompare.4'                      = 'bcompare'
    'calibre.calibre'                                      = 'calibre'
    'Anthropic.Claude'                                     = 'claude'
    'MarkMichaelis/ClaudeCode'                             = 'claude'
    'MarkMichaelis/Codex'                                  = 'codex'
    'MarkMichaelis/GeminiCli'                              = 'gemini'
    'MarkMichaelis/GitHubCopilotCli'                       = 'copilot'
    'MarkMichaelis/Aspire'                                 = 'aspire'
    'VisualStudio2026Enterprise'                           = 'devenv'
}

# Identifiers known to ship no CLI; expected CLI -> $null (Available stays
# $false but no probe is meaningful).
$NoCliPackages = @(
    'Amazon.Kindle','Bitwarden.Bitwarden','Notion.Notion',
    'Pushbullet.Pushbullet','OpenWhisperSystems.Signal','TechSmith.Snagit.2024',
    'Spotify.Spotify','Doist.Todoist','Zoom.Zoom.EXE','Dropbox.Dropbox',
    'Google.Chrome','voidtools.Everything','WinDirStat.WinDirStat',
    'Microsoft.Sysinternals.ProcessExplorer','Microsoft.Sysinternals.Suite',
    'WindowsPostInstallWizard.UniversalSilentSwitchFinder',
    '9NT1R1C2HH7J','9NRQBLR605RG','XPDDXX9QW8N9D7','9NKSQGP7F2NH',
    'gitextensions','gitkraken','git-credential-manager-for-windows',
    'Microsoft-Teams','Office365ProPlus','foxitreader','geosetter',
    'TotalCommander','VisualStudio2019Enterprise','MarkMichaelis/ChatGPT',
    'MarkMichaelis/Claude','MarkMichaelis/Gemini','MarkMichaelis/MicrosoftCopilot',
    'MarkMichaelis/ClaudeExcel','MarkMichaelis/AIAgents'
)

function Get-ExpectedCliName {
    param(
        [Parameter(Mandatory)][string] $Identifier,
        [Parameter(Mandatory)][string] $Source
    )

    if ($Identifier -eq '(variable)') { return $null }

    foreach ($key in $ExpectedCliOverrides.Keys) {
        if ($Identifier -ieq $key) { return $ExpectedCliOverrides[$key] }
    }

    if ($NoCliPackages -contains $Identifier) { return $null }

    switch ($Source) {
        'winget' {
            $last = ($Identifier -split '\.')[-1]
            $last = $last.ToLowerInvariant()
            $last = $last -replace '\.exe$',''
            if ($last -match '^[0-9]') { return $null }
            return $last
        }
        'scoop' {
            $name = $Identifier -replace '^[^/]+/',''
            return $name.ToLowerInvariant()
        }
        'choco'    { return $Identifier.ToLowerInvariant() }
        'psmodule' { return $null }
        default    { return $Identifier.ToLowerInvariant() }
    }
}

function New-Record {
    param(
        [Parameter(Mandatory)][string] $Package,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $SourceScript,
        [string] $ParserNote = ''
    )

    $expected  = Get-ExpectedCliName -Identifier $PackageId -Source $Source
    $available = $false
    $path      = $null

    if ($expected) {
        $cmd = Get-Command $expected -ErrorAction Ignore | Select-Object -First 1
        if ($cmd) {
            $available = $true
            if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) {
                $path = $cmd.Source
            } elseif ($cmd.PSObject.Properties['Definition']) {
                $path = $cmd.Definition
            }
        }
    }

    [pscustomobject]@{
        Package      = $Package
        Source       = $Source
        PackageId    = $PackageId
        ExpectedCli  = $expected
        Available    = $available
        Path         = $path
        SourceScript = $SourceScript
        ParserNote   = $ParserNote
    }
}

# ---------------------------------------------------------------------------
# Scan bucket\*.ps1 (excluding *.Tests.ps1) for install patterns.
# ---------------------------------------------------------------------------

$records = [System.Collections.Generic.List[object]]::new()
$seen    = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

$bundleScripts = Get-ChildItem -Path $BucketPath -Filter *.ps1 |
    Where-Object { $_.Name -notlike '*.Tests.ps1' }

foreach ($file in $bundleScripts) {
    $scriptName = $file.Name
    $content    = Get-Content -Path $file.FullName -Raw

    # Strip line-leading comments so commented-out installs are ignored.
    $sanitizedLines = @()
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*#') { $sanitizedLines += '' } else { $sanitizedLines += $line }
    }
    $sanitized = $sanitizedLines -join "`n"

    # ----- WinGetID hashtable values -----
    foreach ($m in [regex]::Matches($sanitized, "WinGetID\s*=\s*'([^']+)'")) {
        $id  = $m.Groups[1].Value.Trim()
        if (-not $id) { continue }
        $key = "winget|$id|$scriptName"
        if ($seen.Add($key)) {
            $records.Add((New-Record -Package $id -Source 'winget' -PackageId $id -SourceScript $scriptName)) | Out-Null
        }
    }

    # ----- winget install --id <id> -----
    foreach ($m in [regex]::Matches($sanitized,
        '(?im)^\s*winget\s+install\b[^\r\n]*?--id\s+([A-Za-z0-9][\w\.\-]+)')) {
        $id  = $m.Groups[1].Value
        if ($id.StartsWith('$')) { continue }   # variable; covered by hashtable pass
        $key = "winget|$id|$scriptName"
        if ($seen.Add($key)) {
            $records.Add((New-Record -Package $id -Source 'winget' -PackageId $id -SourceScript $scriptName)) | Out-Null
        }
    }

    # ----- winget install <Id-as-positional> (e.g. `winget install --scope machine GitHub.cli`) -----
    foreach ($m in [regex]::Matches($sanitized,
        '(?im)^\s*winget\s+install\s+(?:--scope\s+\S+\s+)?([A-Za-z][\w]*\.[\w\.\-]+)\s*$')) {
        $id  = $m.Groups[1].Value
        $key = "winget|$id|$scriptName"
        if ($seen.Add($key)) {
            $records.Add((New-Record -Package $id -Source 'winget' -PackageId $id -SourceScript $scriptName)) | Out-Null
        }
    }

    # ----- choco install [-y] <name>  (literal package as positional) -----
    foreach ($m in [regex]::Matches($sanitized,
        '(?im)^\s*choco\s+install\s+(?:-y\s+)?([A-Za-z0-9][\w\.\-]*)')) {
        $name = $m.Groups[1].Value.Trim().TrimEnd(',')
        if (-not $name -or $name -eq '-y') { continue }
        $key = "choco|$name|$scriptName"
        if ($seen.Add($key)) {
            $records.Add((New-Record -Package $name -Source 'choco' -PackageId $name -SourceScript $scriptName)) | Out-Null
        }
    }

    # ----- choco install of a variable (parser-skip log) -----
    foreach ($m in [regex]::Matches($sanitized,
        '(?im)^\s*choco\s+install\s+(?:-y\s+)?\$[A-Za-z_]')) {
        $key = "choco|parser-skip|$scriptName"
        if ($seen.Add($key)) {
            $records.Add((New-Record -Package '(variable)' -Source 'choco' -PackageId '(variable)' -SourceScript $scriptName -ParserNote 'parser-skip: choco install of a variable')) | Out-Null
        }
    }

    # ----- choco install '<a>','<b>' | ForEach-Object { choco install -y $_ } -----
    $chocoPipe = "(?ims)((?:'[^']+'\s*,\s*[\r\n\s]*)*'[^']+')\s*\|\s*ForEach-Object\s*\{[^}]*choco\s+install\s+-y\s+\`$_"
    foreach ($m in [regex]::Matches($sanitized, $chocoPipe)) {
        $listText = $m.Groups[1].Value
        foreach ($lm in [regex]::Matches($listText, "'([^']+)'")) {
            $name = $lm.Groups[1].Value.Trim()
            if (-not $name) { continue }
            $key = "choco|$name|$scriptName"
            if ($seen.Add($key)) {
                $records.Add((New-Record -Package $name -Source 'choco' -PackageId $name -SourceScript $scriptName)) | Out-Null
            }
        }
    }

    # ----- scoop install [-g] [<bucket>/]<name> (literal positional) -----
    foreach ($m in [regex]::Matches($sanitized,
        '(?im)^\s*scoop\s+install\s+(?:-g\s+)?([A-Za-z0-9][\w\-/.]+)\s*$')) {
        $name = $m.Groups[1].Value
        if ($name.StartsWith('$')) { continue }
        $key = "scoop|$name|$scriptName"
        if ($seen.Add($key)) {
            $records.Add((New-Record -Package $name -Source 'scoop' -PackageId $name -SourceScript $scriptName)) | Out-Null
        }
    }

    # ----- scoop install pipelines: 'a','b' | ForEach-Object { scoop install [-g] $_ } -----
    $scoopPipe = "(?ims)((?:'[^']+'\s*,\s*[\r\n\s]*)*'[^']+')\s*\|\s*ForEach-Object\s*\{[^}]*scoop\s+install\s+(?:-g\s+)?\`$_"
    foreach ($m in [regex]::Matches($sanitized, $scoopPipe)) {
        $listText = $m.Groups[1].Value
        foreach ($lm in [regex]::Matches($listText, "'([^']+)'")) {
            $name = $lm.Groups[1].Value.Trim()
            if (-not $name) { continue }
            $key = "scoop|$name|$scriptName"
            if ($seen.Add($key)) {
                $records.Add((New-Record -Package $name -Source 'scoop' -PackageId $name -SourceScript $scriptName)) | Out-Null
            }
        }
    }

    # ----- Install-Module [-Name] <name> -----
    foreach ($m in [regex]::Matches($sanitized,
        '(?im)^\s*Install-Module\s+(?:-Name\s+)?([A-Za-z][\w\-\.]+)')) {
        $name = $m.Groups[1].Value
        if ($name.StartsWith('$')) { continue }
        $key = "psmodule|$name|$scriptName"
        if ($seen.Add($key)) {
            $records.Add((New-Record -Package $name -Source 'psmodule' -PackageId $name -SourceScript $scriptName)) | Out-Null
        }
    }
}

# Sort for stable output.
$sorted = @($records | Sort-Object Source, Package, SourceScript)

# Persist JSON artifact (overwrite each run).
$sorted | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputJson -Encoding UTF8

# Build Markdown table.
$considered      = @($sorted | Where-Object { $_.ExpectedCli })
$availableCount  = @($considered | Where-Object { $_.Available }).Count
$totalConsidered = $considered.Count
$summaryLine = "**$availableCount / $totalConsidered** expected CLIs available on PATH " +
               "(of $($sorted.Count) discovered package entries; entries with no expected CLI excluded from ratio)."

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('## CLI-availability discovery (Phase 1)')
$lines.Add('')
$lines.Add($summaryLine)
$lines.Add('')
$lines.Add('| Source | Package | PackageId | ExpectedCli | Available | Path | SourceScript |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($r in $sorted) {
    if ($r.ExpectedCli) { $cli = '`' + $r.ExpectedCli + '`' } else { $cli = '_(none)_' }
    if ($null -eq $r.ExpectedCli) {
        $availSym = 'n/a'
    } elseif ($r.Available) {
        $availSym = 'yes'
    } else {
        $availSym = 'no'
    }
    if ($r.Path) { $pathCell = '`' + $r.Path + '`' } else { $pathCell = '' }
    $note = ''
    if ($r.ParserNote) { $note = " _($($r.ParserNote))_" }
    $lines.Add("| $($r.Source) | $($r.Package)$note | $($r.PackageId) | $cli | $availSym | $pathCell | $($r.SourceScript) |")
}
$markdown = ($lines -join [Environment]::NewLine)

if (-not $Quiet) {
    Write-Host $markdown
}

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $markdown -Encoding UTF8
}

# Return records so callers (Pester) can consume them.
$sorted
