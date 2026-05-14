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
    'extras/beyondcompare'                                 = 'bcompare'
    'calibre.calibre'                                      = 'calibre'
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
    '9NT1R1C2HH7J','9NRQBLR605RG','XPDDXX9QW8N9D7','9NKSQGP7F2NH','XPDNSF6TXN2R6Z',
    'gitextensions','gitkraken','git-credential-manager-for-windows',
    'Microsoft-Teams','Office365ProPlus','foxitreader','Foxit.FoxitReader',
    'geosetter','TotalCommander','MarkMichaelis/ChatGPT',
    'MarkMichaelis/Claude','MarkMichaelis/Gemini','MarkMichaelis/MicrosoftCopilot',
    'MarkMichaelis/ClaudeExcel','MarkMichaelis/AIAgents',
    # Scoop GUI desktop apps (separate from corresponding CLI packages above)
    'extras/claude','extras/notion','extras/spotify',
    # Bundle of tools (procexp/procmon/psexec/...); availability handled by
    # adding the install dir to Machine PATH in OSBasePackages.ps1, not by
    # probing for a single binary called "sysinternals".
    'extras/sysinternals',
    # PS modules / chocolatey-internal packages without a CLI surface.
    'au','Pester','chocolatey-core.extension',
    # Anthropic.Claude is the desktop GUI; the CLI ships as Anthropic.ClaudeCode
    # (mapped via MarkMichaelis/ClaudeCode override above).
    'Anthropic.Claude',
    # Parser-defense: the .EXAMPLE comment in Utils.ps1 used to slip "VisualStudio"
    # past the choco-install regex.  The Strip-comment-blocks pass below is the
    # primary fix; this entry is belt-and-braces in case someone re-introduces
    # an .EXAMPLE doc that mentions a literal `choco install VisualStudio`.
    'VisualStudio'
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

$script:FindBinaryScript  = Join-Path $PSScriptRoot 'Find-PackageBinary.ps1'
$script:HelpProbeScript   = Join-Path $PSScriptRoot 'Test-CliHelpFlag.ps1'

function Update-PathFromRegistry {
    <#
    .SYNOPSIS
        Refresh $env:Path with the current Machine + User PATH from the registry.
    .DESCRIPTION
        Installer programs (winget, scoop -g, choco) write to the *Machine* PATH
        in the registry, but a long-running PowerShell process inherits its
        $env:Path snapshot at start-up and never re-reads it.  In CI that means
        every CLI installed during the same job appears "missing on PATH" even
        though a fresh shell would see it (issue surfaced by run 25642136341 —
        bw/rg/copilot/fzf/bat/es all sat in C:\Program Files\WinGet\Links\
        which Machine PATH knew about but our pwsh process didn't).

        Call this once after install batches and before CLI probing.  Idempotent.
    #>
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $current = $env:Path
    $segments = @()
    foreach ($src in @($machine, $user, $current)) {
        if (-not $src) { continue }
        foreach ($p in ($src -split ';')) {
            $p = $p.Trim()
            if ($p -and ($segments -notcontains $p)) { $segments += $p }
        }
    }
    $env:Path = $segments -join ';'
}

# Refresh PATH from the registry so freshly-installed CLIs (whose installers
# updated Machine PATH after this process started) become discoverable to the
# Get-Command probe below.
Update-PathFromRegistry

function New-Record {
    param(
        [Parameter(Mandatory)][string] $Package,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $SourceScript,
        [string] $ParserNote = ''
    )

    $expected     = Get-ExpectedCliName -Identifier $PackageId -Source $Source
    $available    = $false
    $path         = $null
    $onDiskPath   = $null
    $helpFlag     = $null
    $helpExit     = $null

    if ($expected) {
        $cmd = Get-Command $expected -ErrorAction Ignore | Select-Object -First 1
        if ($cmd) {
            $available = $true
            if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) {
                $path = $cmd.Source
            } elseif ($cmd.PSObject.Properties['Definition']) {
                $path = $cmd.Definition
            }
        } else {
            # Fallback: not on PATH — see if the binary exists on disk and
            # responds to a help flag. Distinguishes "not installed" from
            # "installed but PATH/shim missing" (issue #47).
            try {
                $hit = & $script:FindBinaryScript -Name $expected
            } catch {
                $hit = $null
            }
            if ($hit -and $hit.Path) {
                $onDiskPath = $hit.Path
                try {
                    $probe = & $script:HelpProbeScript -Path $hit.Path
                    if ($probe -and $probe.Success) {
                        $helpFlag = $probe.Flag
                        $helpExit = $probe.ExitCode
                    } elseif ($probe) {
                        $helpExit = $probe.ExitCode
                    }
                } catch {
                    # swallow — discovery is best-effort
                }
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
        OnDiskPath   = $onDiskPath
        HelpFlag     = $helpFlag
        HelpExitCode = $helpExit
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

# ---------------------------------------------------------------------------
# Source 0: declarative [Package] arrays via the ScoopBucket module.
# Walks every migrated bundle's $Packages collection and emits one record
# per CliCommand. Bundles that have already moved to the declarative form
# stop contributing to the text-parsed sources below (their bodies no
# longer contain `winget install` / `scoop install` / `choco install` /
# `Install-Module` lines), so no duplicates are produced.
# ---------------------------------------------------------------------------

$declarativeBundles = @{}
try {
    $modulePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'module\ScoopBucket\ScoopBucket.psd1'
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force -ErrorAction Stop
        $declarativePackages = Get-Package -BucketPath $BucketPath -ErrorAction Stop
        foreach ($p in $declarativePackages) {
            $declarativeBundles[$p.Bundle] = $true
            # Map [Package].Installer to the discovery Source vocabulary.
            $src = switch ($p.Installer) {
                'winget'     { if ($p.Source -eq 'msstore') { 'winget-msstore' } else { 'winget' } }
                'scoop'      { 'scoop' }
                'choco'      { 'choco' }
                'npmGlobal'  { 'npm' }
                'dotnetTool' { 'dotnetTool' }
                'custom'     { 'custom' }
                default      { $p.Installer }
            }
            $bundleScript = "$($p.Bundle).ps1"
            $clis = @($p.CliCommands)
            if ($clis.Count -eq 0) {
                # No expected CLI -- still record the package so coverage reflects it.
                $key = "$src|$($p.Id)|$bundleScript|"
                if ($seen.Add($key)) {
                    $rec = New-Record -Package $p.Name -Source $src -PackageId ([string]$p.Id) -SourceScript $bundleScript -ParserNote 'declarative'
                    # Override expected CLI when the declarative form said "none".
                    $rec.ExpectedCli = $null
                    $rec.Available   = $false
                    $records.Add($rec) | Out-Null
                }
            } else {
                foreach ($cli in $clis) {
                    $key = "$src|$($p.Id)|$bundleScript|$cli"
                    if (-not $seen.Add($key)) { continue }
                    $rec = New-Record -Package $p.Name -Source $src -PackageId ([string]$p.Id) -SourceScript $bundleScript -ParserNote 'declarative'
                    # CliCommands wins over the heuristic ExpectedCli that
                    # New-Record computed from the engine identifier.
                    if ($rec.ExpectedCli -ne $cli) {
                        $rec.ExpectedCli = $cli
                        $cmd = Get-Command $cli -ErrorAction Ignore | Select-Object -First 1
                        if ($cmd) {
                            $rec.Available = $true
                            $rec.Path = if ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
                            $rec.OnDiskPath = $null
                            $rec.HelpFlag = $null
                            $rec.HelpExitCode = $null
                        } else {
                            $rec.Available = $false
                        }
                    }
                    $records.Add($rec) | Out-Null
                }
            }
        }
    }
} catch {
    Write-Warning "ScoopBucket module Get-Package discovery failed: $($_.Exception.Message). Falling back to text parsing only."
}

# ---------------------------------------------------------------------------
# Scan bucket\*.ps1 (excluding *.Tests.ps1) for install patterns.
# Bundles already covered by the declarative source above are skipped.
# ---------------------------------------------------------------------------

$bundleScripts = Get-ChildItem -Path $BucketPath -Filter *.ps1 |
    Where-Object { $_.Name -notlike '*.Tests.ps1' } |
    Where-Object {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        -not $declarativeBundles.ContainsKey($stem)
    }

foreach ($file in $bundleScripts) {
    $scriptName = $file.Name
    $content    = Get-Content -Path $file.FullName -Raw

    # Strip multi-line comment-help blocks (<# ... #>) first so .EXAMPLE
    # snippets (e.g. "choco install VisualStudio -y --force" inside Utils.ps1's
    # comment header) aren't parsed as real installs.  Then strip line-leading
    # # comments so commented-out installs are also ignored.
    $stripped = [regex]::Replace($content, '(?s)<#.*?#>', '')
    $sanitizedLines = @()
    foreach ($line in ($stripped -split "`r?`n")) {
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
$lines.Add('| Source | Package | PackageId | ExpectedCli | Available | Path | OnDiskPath | HelpFlag | HelpExit | SourceScript |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
foreach ($r in $sorted) {
    if ($r.ExpectedCli) { $cli = '`' + $r.ExpectedCli + '`' } else { $cli = '_(none)_' }
    if ($null -eq $r.ExpectedCli) {
        $availSym = 'n/a'
    } elseif ($r.Available) {
        $availSym = 'yes'
    } else {
        $availSym = 'no'
    }
    if ($r.Path)       { $pathCell    = '`' + $r.Path + '`' }       else { $pathCell    = '' }
    if ($r.OnDiskPath) { $onDiskCell  = '`' + $r.OnDiskPath + '`' } else { $onDiskCell  = '' }
    if ($r.HelpFlag)   { $flagCell    = '`' + $r.HelpFlag + '`' }   else { $flagCell    = '' }
    if ($null -ne $r.HelpExitCode) { $exitCell = [string]$r.HelpExitCode } else { $exitCell = '' }
    $note = ''
    if ($r.ParserNote) { $note = " _($($r.ParserNote))_" }
    $lines.Add("| $($r.Source) | $($r.Package)$note | $($r.PackageId) | $cli | $availSym | $pathCell | $onDiskCell | $flagCell | $exitCell | $($r.SourceScript) |")
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
