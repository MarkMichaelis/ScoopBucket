# Version / available-update probe used to make -WhatIf accurate and to
# annotate the summary with a `from -> to` version transition (#283).
#
# Design: instead of probing each package individually (which would re-run a
# bulk scan per package), Get-PackageUpdateIndex runs each engine's bulk
# "what is installed / what is outdated" command ONCE and returns a lookup:
#
#   @{ winget = @{ '<id>' = @{ Installed='1.2'; Available='1.3' } }; scoop = ...; ... }
#
# Invoke-PackageUpdate / Invoke-PackageInstall then look up each package by
# Id (case-insensitively) to decide Updated vs AlreadyLatest under -WhatIf and
# to fill VersionFrom / VersionTo. Every parser is pure (text/JSON -> hashtable)
# so it can be unit-tested against canned CLI fixtures; the orchestrator only
# adds the CLI invocation and is defensive (any failure yields an empty/Unknown
# map rather than throwing, so a flaky probe never aborts a sweep).

function Format-VersionCell {
    # Normalise a version string sliced out of a fixed-width CLI table. winget
    # truncates an over-long column with a Unicode ellipsis (U+2026) which the
    # OEM console codepage renders as mojibake (e.g. "ÔÇª" / "ΓÇª"); strip every
    # non-printable / non-ASCII byte so a stray truncation marker never leaks
    # into the rendered `from -> to` transition. Returns the cleaned string.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value -replace '[^\x20-\x7E]', '').Trim()
}

function ConvertFrom-WingetVersionTable {
    # Parse the fixed-width table emitted by `winget list` (and `winget
    # upgrade`). Returns @{ '<id>' = @{ Installed; Available } } keyed by the
    # Id column (lower-cased). The Available column is empty when the package
    # is already current. winget right-pads columns to header width, so we
    # slice by the header's column start offsets rather than splitting on
    # whitespace (Names and versions both contain spaces).
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Lines)

    $map = @{}
    if (-not $Lines) { return $map }

    # Find the header row: the first line that contains both 'Id' and
    # 'Version' as column headers, immediately followed (next non-empty line)
    # by a dashed separator. winget may prefix spinner/progress noise lines.
    $headerIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l -match '(^|\s)Id(\s)' -and $l -match '(^|\s)Version(\s|$)') {
            $headerIdx = $i
            break
        }
    }
    if ($headerIdx -lt 0) { return $map }

    $header = $Lines[$headerIdx]
    $colId        = $header.IndexOf('Id')
    $colVersion   = $header.IndexOf('Version')
    $colAvailable = $header.IndexOf('Available')
    $colSource    = $header.IndexOf('Source')
    if ($colId -lt 0 -or $colVersion -lt 0) { return $map }

    # Right edge of the Id column = start of Version; of Version = start of
    # Available (or Source, or end-of-line when neither is present).
    $idEnd = $colVersion
    $verEnd = if ($colAvailable -ge 0) { $colAvailable } elseif ($colSource -ge 0) { $colSource } else { [int]::MaxValue }
    $availEnd = if ($colSource -ge 0) { $colSource } else { [int]::MaxValue }

    for ($i = $headerIdx + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^[-\u2500\s]+$') { continue }      # dashed separator
        if ($line.Length -le $colId) { continue }

        $slice = {
            param($start, $end)
            if ($start -lt 0 -or $start -ge $line.Length) { return '' }
            $stop = [Math]::Min($end, $line.Length)
            if ($stop -le $start) { return '' }
            return $line.Substring($start, $stop - $start).Trim()
        }

        $id = & $slice $colId $idEnd
        if (-not $id) { continue }
        $installed = Format-VersionCell (& $slice $colVersion $verEnd)
        $available = if ($colAvailable -ge 0) { Format-VersionCell (& $slice $colAvailable $availEnd) } else { '' }

        $map[(Format-VersionCell $id).ToLowerInvariant()] = @{ Installed = $installed; Available = $available }
    }
    return $map
}

function ConvertFrom-ChocoOutdated {
    # Parse `choco outdated -r --no-progress` machine-readable output:
    #   <id>|<currentVersion>|<availableVersion>|<pinned>
    # Returns @{ '<id>' = @{ Installed; Available } } for outdated packages.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Lines)

    $map = @{}
    if (-not $Lines) { return $map }
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        if ($parts.Count -lt 3) { continue }
        $id = $parts[0].Trim()
        if (-not $id) { continue }
        $map[$id.ToLowerInvariant()] = @{ Installed = $parts[1].Trim(); Available = $parts[2].Trim() }
    }
    return $map
}

function ConvertFrom-NpmOutdated {
    # Parse `npm outdated -g --json` output. The JSON is an object keyed by
    # package name, each with { current, wanted, latest }. Returns
    # @{ '<name>' = @{ Installed; Available } } for packages with a newer latest.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Json)

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) { return $map }
    try { $obj = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $map }
    if (-not $obj) { return $map }
    foreach ($prop in $obj.PSObject.Properties) {
        $entry = $prop.Value
        $installed = [string]$entry.current
        $available = [string]$entry.latest
        $map[$prop.Name.ToLowerInvariant()] = @{ Installed = $installed; Available = $available }
    }
    return $map
}

function ConvertFrom-ScoopStatus {
    # Parse `scoop status` fixed-width table. Newer scoop emits columns:
    #   Name  Installed Version  Latest Version  Missing Dependencies  Info
    # Only apps with an available update are listed. Returns
    # @{ '<app>' = @{ Installed; Available } } keyed by bare app name.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Lines)

    $map = @{}
    if (-not $Lines) { return $map }

    $headerIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match 'Installed Version' -and $Lines[$i] -match 'Latest Version') {
            $headerIdx = $i; break
        }
    }
    if ($headerIdx -lt 0) { return $map }

    $header = $Lines[$headerIdx]
    $colName      = $header.IndexOf('Name')
    $colInstalled = $header.IndexOf('Installed Version')
    $colLatest    = $header.IndexOf('Latest Version')
    if ($colName -lt 0 -or $colInstalled -lt 0 -or $colLatest -lt 0) { return $map }

    # Column after Latest Version (Missing Dependencies / Info) bounds the slice.
    $colAfter = $header.IndexOf('Missing Dependencies')
    if ($colAfter -lt 0) { $colAfter = $header.IndexOf('Info') }

    for ($i = $headerIdx + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^[-\u2500\s]+$') { continue }
        if ($line.Length -le $colName) { continue }

        $slice = {
            param($start, $end)
            if ($start -lt 0 -or $start -ge $line.Length) { return '' }
            $stop = [Math]::Min($end, $line.Length)
            if ($stop -le $start) { return '' }
            return $line.Substring($start, $stop - $start).Trim()
        }

        $name = & $slice $colName $colInstalled
        if (-not $name) { continue }
        $installed = & $slice $colInstalled $colLatest
        $latestEnd = if ($colAfter -ge 0) { $colAfter } else { [int]::MaxValue }
        $latest = & $slice $colLatest $latestEnd

        $map[$name.ToLowerInvariant()] = @{ Installed = $installed; Available = $latest }
    }
    return $map
}

function Get-PackageUpdateIndex {
    <#
    .SYNOPSIS
        Build a per-engine map of installed + available versions by running
        each engine's bulk query ONCE. Used to make -WhatIf accurate and to
        annotate results with a from -> to version transition (#283).

    .DESCRIPTION
        Returns a hashtable keyed by installer name. Each value is a hashtable
        keyed by lower-cased package Id (bare app name for scoop) ->
        @{ Installed; Available; UpdateAvailable }.

          - winget : `winget list` (Available column populated when outdated)
          - choco  : `choco list -lo -r` (installed) + `choco outdated -r` (available)
          - scoop  : `scoop status` (only outdated apps)
          - npmGlobal : `npm outdated -g --json`
          - dotnetTool: `dotnet tool list -g` (installed only; Available unknown)

        Only the engines named in -Installers are probed. Any probe failure
        leaves that engine's map empty (callers treat a missing entry as
        "unknown" and fall back to optimistic behaviour) -- a flaky probe must
        never abort the sweep.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([string[]]$Installers)

    $index = @{}
    $want = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($Installers), [System.StringComparer]::OrdinalIgnoreCase)

    if ($want.Contains('winget') -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        try {
            # winget reads the attached console width (even when stdout is
            # redirected) and truncates over-long Version / Available columns
            # with an ellipsis. Temporarily widen the buffer so long versions
            # (e.g. Warp's "v0.2026.05.27.15.44.stable_01") survive intact, then
            # restore it. Guarded -- a headless / redirected host where the
            # buffer can't be set just falls back to winget's default width.
            $prevWidth = $null
            try { $prevWidth = [Console]::BufferWidth } catch { $prevWidth = $null }
            try { if ($null -ne $prevWidth -and $prevWidth -lt 512) { [Console]::BufferWidth = 512 } } catch { }
            try {
                $out = & winget list --accept-source-agreements 2>$null
            } finally {
                try { if ($null -ne $prevWidth -and $prevWidth -lt 512) { [Console]::BufferWidth = $prevWidth } } catch { }
            }
            $index['winget'] = ConvertFrom-WingetVersionTable @($out | ForEach-Object { [string]$_ })
        } catch { Write-Verbose "Get-PackageUpdateIndex/winget: $($_.Exception.Message)"; $index['winget'] = @{} }
    }

    if ($want.Contains('choco') -and (Get-Command choco -ErrorAction SilentlyContinue)) {
        try {
            $installedOut = & choco list --local-only --limit-output --no-progress 2>$null
            $cmap = @{}
            foreach ($line in @($installedOut | ForEach-Object { [string]$_ })) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $p = $line.Split('|')
                if ($p.Count -lt 2) { continue }
                $cid = $p[0].Trim()
                if ($cid) { $cmap[$cid.ToLowerInvariant()] = @{ Installed = $p[1].Trim(); Available = '' } }
            }
            $outdatedOut = & choco outdated --limit-output --no-progress 2>$null
            $omap = ConvertFrom-ChocoOutdated @($outdatedOut | ForEach-Object { [string]$_ })
            foreach ($k in $omap.Keys) {
                $cmap[$k] = @{ Installed = $omap[$k].Installed; Available = $omap[$k].Available }
            }
            $index['choco'] = $cmap
        } catch { Write-Verbose "Get-PackageUpdateIndex/choco: $($_.Exception.Message)"; $index['choco'] = @{} }
    }

    if ($want.Contains('scoop') -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
        try {
            $out = & scoop status *>&1
            $index['scoop'] = ConvertFrom-ScoopStatus @($out | ForEach-Object { $_.ToString() })
        } catch { Write-Verbose "Get-PackageUpdateIndex/scoop: $($_.Exception.Message)"; $index['scoop'] = @{} }
    }

    if ($want.Contains('npmGlobal') -and (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        try {
            $out = & npm.cmd outdated -g --json 2>$null
            $index['npmGlobal'] = ConvertFrom-NpmOutdated ([string]($out -join "`n"))
        } catch { Write-Verbose "Get-PackageUpdateIndex/npm: $($_.Exception.Message)"; $index['npmGlobal'] = @{} }
    }

    if ($want.Contains('dotnetTool') -and (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        try {
            $out = & dotnet tool list -g 2>$null | ForEach-Object { [string]$_ }
            $dmap = @{}
            foreach ($line in $out) {
                # Rows: "<package id>   <version>   <commands>" after a dashed
                # separator. Split on 2+ spaces; require a version-looking col 2.
                if ($line -match '^\s*(\S+)\s{2,}(\S+)\s{2,}\S+') {
                    $pid = $Matches[1].Trim()
                    if ($pid -ieq 'Package' -or $pid -match '^-+$') { continue }
                    $dmap[$pid.ToLowerInvariant()] = @{ Installed = $Matches[2].Trim(); Available = '' }
                }
            }
            $index['dotnetTool'] = $dmap
        } catch { Write-Verbose "Get-PackageUpdateIndex/dotnet: $($_.Exception.Message)"; $index['dotnetTool'] = @{} }
    }

    return $index
}

function Resolve-PackageVersionInfo {
    <#
    .SYNOPSIS
        Look a single package up in the index produced by
        Get-PackageUpdateIndex and return a uniform version record.

    .DESCRIPTION
        Returns @{ Present; Installed; Available; UpdateAvailable } where:
          - Present         : $true if the engine map listed the package,
                              $false if the map was built but the package was
                              absent, $null if the engine wasn't probed (unknown).
          - UpdateAvailable : $true / $false / $null (unknown).
        Scoop is keyed by bare app name (the '<bucket>/<app>' Id minus the
        bucket prefix), mirroring Update-ScoopPackage's own parsing.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][hashtable]$Index
    )

    $installer = [string]$Package.Installer
    $id = [string]$Package.Id

    # No engine map (engine not probed / not installed) => everything unknown.
    if (-not $Index.ContainsKey($installer)) {
        return @{ Present = $null; Installed = ''; Available = ''; UpdateAvailable = $null }
    }
    $map = $Index[$installer]

    $key = $id.ToLowerInvariant()
    if ($installer -eq 'scoop') {
        $bucket, $app = $id -split '/', 2
        if (-not $app) { $app = $bucket }
        $key = $app.ToLowerInvariant()
    }

    if (-not $map.ContainsKey($key)) {
        # winget/choco/dotnet maps list installed packages, so absence means
        # not installed. scoop/npm maps list ONLY outdated packages, so
        # absence means "installed and current" cannot be distinguished from
        # "not installed" -- treat as present+current (optimistic: a genuine
        # missing package surfaces as NotInstalled on the real run's probe).
        if ($installer -in @('scoop', 'npmGlobal')) {
            return @{ Present = $true; Installed = ''; Available = ''; UpdateAvailable = $false }
        }
        return @{ Present = $false; Installed = ''; Available = ''; UpdateAvailable = $null }
    }

    $entry = $map[$key]
    $installed = [string]$entry.Installed
    $available = [string]$entry.Available

    # dotnetTool map carries installed only (Available always '') -> unknown.
    if ($installer -eq 'dotnetTool') {
        return @{ Present = $true; Installed = $installed; Available = ''; UpdateAvailable = $null }
    }

    $updateAvailable = [bool]($available -and $available -ne $installed)
    return @{
        Present         = $true
        Installed       = $installed
        Available       = $available
        UpdateAvailable = $updateAvailable
    }
}
