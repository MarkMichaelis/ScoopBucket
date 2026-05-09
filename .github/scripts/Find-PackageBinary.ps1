<#
.SYNOPSIS
    Locate a CLI binary on disk by short-name when it is not on $env:PATH.

.DESCRIPTION
    Phase 1.5 helper for issue #47 (a Phase-1.5 follow-up to #45). When
    Get-PackageCommands.ps1 finds an expected CLI is not reachable via
    Get-Command, it calls this helper to determine whether the binary
    exists somewhere on the machine — distinguishing "not installed" from
    "installed but PATH/shim missing".

    Default search roots (existence-checked):

        - $env:ProgramFiles
        - ${env:ProgramFiles(x86)}
        - $env:LOCALAPPDATA\Programs
        - $env:LOCALAPPDATA\Microsoft\WinGet\Packages
        - $env:USERPROFILE\scoop\apps
        - $env:ProgramData\scoop\apps
        - $env:ChocolateyInstall\bin (if $env:ChocolateyInstall is set)

    Plus the per-machine and per-user "App Paths" registry keys
    (HKLM/HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\<name>.exe).

.PARAMETER Name
    The CLI short-name (without extension), e.g. 'bw', 'gh', 'rg'.

.PARAMETER SearchRoots
    Optional override list of directories to search (recursively). When
    omitted, the defaults above are used.

.PARAMETER All
    If set, return every match found. Default returns the first match.

.OUTPUTS
    [pscustomobject] @{ Name=<short-name>; Path=<full path>; FoundIn=<root that matched> }
    Returns nothing when no match is found.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Name,
    [string[]] $SearchRoots,
    [int] $MaxDepth = 6,
    [switch] $All
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-DefaultSearchRoots {
    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:USERPROFILE 'scoop\apps'),
        (Join-Path $env:ProgramData 'scoop\apps')
    )
    if ($env:ChocolateyInstall) {
        $roots += (Join-Path $env:ChocolateyInstall 'bin')
    }
    $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}

function Get-AppPathsHit {
    param([string] $ShortName)
    $exe   = "$ShortName.exe"
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
    )
    foreach ($p in $paths) {
        try {
            $key = Get-Item -LiteralPath $p -ErrorAction Stop
            $default = $key.GetValue('')
            if ($default -and (Test-Path -LiteralPath $default)) {
                [pscustomobject]@{
                    Name    = $ShortName
                    Path    = [string]$default
                    FoundIn = $p
                }
            }
        } catch { }
    }
}

if (-not $SearchRoots -or $SearchRoots.Count -eq 0) {
    $SearchRoots = Get-DefaultSearchRoots
}

$candidates = @("$Name.exe", "$Name.cmd", "$Name.bat", "$Name.ps1")
$hits       = [System.Collections.Generic.List[object]]::new()

# Registry App Paths first — fastest, most authoritative for installed apps.
foreach ($r in (Get-AppPathsHit -ShortName $Name)) {
    $hits.Add($r) | Out-Null
    if (-not $All) { return $r }
}

foreach ($root in $SearchRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try {
        $found = Get-ChildItem -LiteralPath $root -Recurse -Depth $MaxDepth -File `
            -Include $candidates -ErrorAction Ignore -Force |
            Select-Object -First $(if ($All) { 100 } else { 1 })
    } catch {
        continue
    }
    foreach ($f in $found) {
        $rec = [pscustomobject]@{
            Name    = $Name
            Path    = $f.FullName
            FoundIn = $root
        }
        $hits.Add($rec) | Out-Null
        if (-not $All) { return $rec }
    }
}

if ($All) { return $hits.ToArray() }
return $null
