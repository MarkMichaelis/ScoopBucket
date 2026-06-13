#Requires -Version 5.1

<#
.SYNOPSIS
    Report the processes that currently hold open file handles under the
    OneDrive sync roots and would therefore block a same-volume Move-Item
    (NTFS rename) of a OneDrive folder. Standalone diagnostic; the
    MarkMichaelisOneDriveConfiguration bundle it was built for was removed
    (see https://github.com/MarkMichaelis/ScoopBucket/issues/382).

.DESCRIPTION
    A same-volume directory rename fails with a sharing violation if any file
    or subdirectory under the source is open without FILE_SHARE_DELETE -- which
    is how virtually every normal application opens files. Stopping OneDrive.exe
    itself does NOT close other apps (editors, Office, Snagit, an Explorer
    window parked in the folder, a terminal cd'd into it). This script lists
    those blockers up front so you can close them before moving a OneDrive
    folder, instead of discovering a lock halfway through.

    It uses Sysinternals handle.exe / handle64.exe (available on this machine
    via `scoop install sysinternals`) to enumerate open handles whose object
    path falls under any OneDrive root, then filters out OneDrive's own helper
    processes (which the migration stops on its own).

.PARAMETER Root
    One or more OneDrive root paths to scan. Defaults to the standard
    per-user OneDrive roots under $env:USERPROFILE (the personal root plus any
    "OneDrive - <Tenant>" business roots).

.PARAMETER IncludeOneDriveProcesses
    Also report handles held by OneDrive's own processes
    (OneDrive.exe / OneDrive.Sync.Service.exe / FileCoAuth.exe). By default
    these are excluded because the migration script stops them itself.

.INPUTS
    None.

.OUTPUTS
    PSCustomObject per blocking handle: Process, Id (PID), Path.
    Returns nothing (and prints an all-clear) when no blockers are found.

.EXAMPLE
    .\scripts\Test-OneDriveMoveBlockers.ps1

    List every non-OneDrive process holding a handle under the OneDrive roots.
    Close them (or save+close the documents) before running the migration.

.EXAMPLE
    .\scripts\Test-OneDriveMoveBlockers.ps1 -IncludeOneDriveProcesses

    Show everything, including OneDrive's own handles, for diagnostics.

.NOTES
    Requires Sysinternals handle (handle.exe / handle64.exe) on PATH.
    Install with: scoop install sysinternals
    Run elevated for complete coverage (handle can miss other users'/elevated
    processes' handles when run non-elevated).

    Originally a companion to the MarkMichaelisOneDriveConfiguration.ps1
    bundle, which was abandoned and removed
    (https://github.com/MarkMichaelis/ScoopBucket/issues/382). Kept as a
    standalone OneDrive folder-move blocker diagnostic.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string[]]$Root,

    [Parameter()]
    [switch]$IncludeOneDriveProcesses
)

$ErrorActionPreference = 'Stop'

function Get-DefaultOneDriveRoot {
    <#
    .SYNOPSIS
        Resolve the per-user OneDrive root folders to scan.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'OneDrive' -or $_.Name -like 'OneDrive - *' } |
        Select-Object -ExpandProperty FullName
}

$handle = Get-Command 'handle64.exe', 'handle.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $handle) {
    throw "Sysinternals 'handle' not found on PATH. Install it with: scoop install sysinternals"
}

$roots = if ($PSBoundParameters.ContainsKey('Root') -and $Root) {
    $Root
} else {
    Get-DefaultOneDriveRoot
}

if (-not $roots) {
    Write-Warning "No OneDrive root folders found under '$env:USERPROFILE'. Pass -Root explicitly."
    return
}

Write-Host 'Scanning for open handles that would block a OneDrive folder move:'
$roots | ForEach-Object { Write-Host "  $_" }

# OneDrive's own processes are stopped by the migration; do not count them.
$oneDriveProcessNames = @('OneDrive', 'OneDrive.Sync.Service', 'FileCoAuth')

# handle does case-insensitive substring matching on the object name, so a
# common prefix scan catches every root in one pass; we still re-filter each
# line against the resolved roots to avoid accidental prefix bleed.
$commonPrefix = ($roots | Sort-Object Length | Select-Object -First 1)

$rawLines = & $handle.Source -accepteula -nobanner $commonPrefix 2>$null |
    Where-Object { $_ -match 'pid:' }

$blockers = foreach ($line in $rawLines) {
    if ($line -notmatch '^(?<proc>\S+)\s+pid:\s*(?<pid>\d+)\s+type:\s*File\s+\w+:\s*(?<path>.+)$') {
        continue
    }
    $procName = $Matches.proc -replace '\.exe$', ''
    $path = $Matches.path.Trim()

    if (-not ($roots | Where-Object { $path.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })) {
        continue
    }
    if (-not $IncludeOneDriveProcesses -and $oneDriveProcessNames -contains $procName) {
        continue
    }

    [pscustomobject]@{
        Process = $Matches.proc
        Id      = [int]$Matches.pid
        Path    = $path
    }
}

$blockers = @($blockers)

if (-not $blockers) {
    Write-Host ''
    Write-Host 'CLEAR: no blocking handles found. A same-volume move should not hit a sharing violation.'
    return
}

Write-Host ''
Write-Host "Found $($blockers.Count) blocking handle(s) from $(@($blockers | Select-Object -ExpandProperty Id -Unique).Count) process(es):"
$blockers | Sort-Object Process, Id, Path | Format-Table -AutoSize | Out-Host

Write-Host 'Close these processes (save your work first) and re-run this check until it reports CLEAR.'
return $blockers
