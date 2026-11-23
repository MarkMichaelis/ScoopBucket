# Upgrading a program while it runs (#547).
#
# Windows refuses to overwrite or delete an executable that a running process has
# loaded. That is why `winget upgrade` of a portable package (claude.exe from
# Anthropic.ClaudeCode, copilot.exe from GitHub.Copilot) failed whenever any copy
# was running -- and winget's cleanup of the failed upgrade also removed the
# package's command alias, leaving the command unusable until a later upgrade
# succeeded. Windows DOES allow a loaded executable to be renamed: the running
# process keeps executing the renamed file, and the installer can then write the
# new version at the original path. No reboot is involved.
#
# Move-InUseFileAside renames each in-use executable image under the given
# directories to '<name>.superseded-<timestamp>-<pid>' just before the engine runs.
# Complete-InUseFileAside settles each one afterwards:
#   - nothing was upgraded (no upgrade, or it failed) -> put it back;
#   - upgraded, and a replacement exists -> delete the set-aside copy;
#   - upgraded, and the new version no longer ships that file (e.g. Grok Build's
#     versioned grok-<ver>.exe) -> delete it, never put it back. "Upgraded" is
#     judged per package folder: only when new files landed there during this run.
#     `winget upgrade --all` exits 0 while skipping pinned packages, so its exit
#     code alone cannot say which set-aside files were replaced.
# A set-aside copy that a process still runs cannot be deleted yet; it stays for a
# later run, renamed '<name>.obsolete-...' when it must never be restored.
# Every Move-InUseFileAside call first settles leftovers from earlier runs: that
# deletes copies that were still running last time and recovers from a run that
# was interrupted between the rename and the settle. The <pid> records which run
# set a copy aside, so a sweep never restores a file that a still-running run (a
# concurrent Update-Package) has moved out of its engine's way. Paths go through
# the .NET file APIs, which take them literally ('[', ']' in a profile path).

$script:SetAsidePattern = '^(?<original>.+\.(?:exe|dll))\.(?<kind>superseded|obsolete)-(?<stamp>\d{17})(?:-(?<owner>\d+))?$'

function Get-WingetPortableDirectory {
    # winget installs portable packages under <root>\Packages\<Id>_<SourceId>,
    # per-user under %LOCALAPPDATA% and machine-wide under Program Files. With -Id,
    # returns only that package's directories; without it, every portable package's.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Id)

    $roots = @(
        if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages' }
        if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'WinGet\Packages' }
        if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'WinGet\Packages' }
    ) | Select-Object -Unique

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if (-not $Id -or $dir.Name.StartsWith("$($Id)_", [StringComparison]::OrdinalIgnoreCase)) {
                $dir.FullName
            }
        }
    }
}

function Test-FileInUse {
    # A loaded executable image (or a file another process holds without write
    # sharing) cannot be opened exclusively for writing. Access-denied (no rights,
    # read-only) is NOT "in use": that is left for the engine to report.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None').Dispose()
        return $false
    } catch {
        $e = $_.Exception
        while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
        if ($e -is [System.UnauthorizedAccessException]) {
            Write-Verbose "Could not check whether '$Path' is in use (access denied); leaving it in place for the engine."
            return $false
        }
        return ($e -is [System.IO.IOException] -and $e -isnot [System.IO.FileNotFoundException] -and $e -isnot [System.IO.DirectoryNotFoundException])
    }
}

function Test-SetAsideOwnerRunning {
    # True when another, still-running process set the file aside (it will settle
    # it itself). This process's own earlier calls have finished, so they do not
    # count, and a process that started after the stamp only reuses a dead run's id.
    [OutputType([bool])]
    param(
        [AllowNull()][Nullable[int]]$Owner,
        [AllowNull()][string]$Stamp
    )

    if (-not $Owner -or $Owner -eq $PID) { return $false }
    $process = Get-Process -Id $Owner -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    if (-not $Stamp) { return $true }
    try {
        $setAt = [datetime]::ParseExact($Stamp, 'yyyyMMddHHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
        return ($process.StartTime -le $setAt)
    } catch {
        return $false
    }
}

function Test-NewFileSince {
    # True when a file other than a set-aside copy was created or written in
    # $Directory at or after $Since -- the sign that an upgrade landed there.
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [AllowNull()][Nullable[datetime]]$Since
    )

    if (-not $Since) { return $true }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        if ($file.Name -match $script:SetAsidePattern) { continue }
        if ($file.CreationTime -ge $Since -or $file.LastWriteTime -ge $Since) { return $true }
    }
    return $false
}

function Resolve-SetAsideFile {
    # Settle one set-aside copy. Returns 'Deleted', 'Restored', or 'Kept' (a
    # process still runs it, or its owning run is still in progress).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Original,
        [Parameter(Mandatory)][string]$Renamed,
        # The engine reports an upgrade: a missing original was dropped by the new
        # version -- provided something new landed in its folder after $SetAt.
        [switch]$Upgraded,
        [Nullable[datetime]]$SetAt,
        # Already marked as no longer shipped: delete only.
        [switch]$Obsolete,
        [Nullable[int]]$Owner,
        [string]$Stamp
    )

    if (-not [System.IO.File]::Exists($Renamed)) { return 'Deleted' }
    $replaced = [System.IO.File]::Exists($Original)
    $dropped = (-not $replaced) -and $Upgraded -and (Test-NewFileSince -Directory ([System.IO.Path]::GetDirectoryName($Original)) -Since $SetAt)

    if (-not $replaced -and -not $dropped -and -not $Obsolete) {
        if (Test-SetAsideOwnerRunning -Owner $Owner -Stamp $Stamp) { return 'Kept' }
        try {
            [System.IO.File]::Move($Renamed, $Original)
            return 'Restored'
        } catch {
            Write-Warning "Could not put '$Original' back from '$Renamed': $($_.Exception.Message)"
            return 'Kept'
        }
    }

    try {
        [System.IO.File]::Delete($Renamed)
        return 'Deleted'
    } catch {
        # Still running. When the upgrade no longer ships this file, mark it so no
        # later sweep mistakes it for an interrupted run and puts it back.
        if (-not $replaced -and -not $Obsolete) {
            $marked = $Renamed -replace '\.superseded-(?=\d{17})', '.obsolete-'
            try { [System.IO.File]::Move($Renamed, $marked) } catch {
                Write-Verbose "Could not mark '$Renamed' obsolete: $($_.Exception.Message)"
            }
        }
        return 'Kept'
    }
}

function Get-SetAsideFile {
    # Copies earlier runs set aside under $Directory, with the original path, kind
    # and owning process id parsed from the name. Only .exe / .dll set-asides match,
    # so a vendor file that merely resembles one is never touched.
    [CmdletBinding()]
    param([string[]]$Directory)

    foreach ($dir in $Directory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -notmatch $script:SetAsidePattern) { continue }
            [pscustomobject]@{
                Original = Join-Path $file.DirectoryName $Matches.original
                Renamed  = $file.FullName
                Obsolete = ($Matches.kind -eq 'obsolete')
                Owner    = if ($Matches.owner) { [int]$Matches.owner } else { $null }
                Stamp    = $Matches.stamp
            }
        }
    }
}

function Get-InUseFile {
    # Executable images (.exe / .dll) under $Directory that a running process holds.
    [CmdletBinding()]
    param([string[]]$Directory)

    foreach ($dir in @($Directory | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($file.Extension -notin '.exe', '.dll') { continue }
            if (Test-FileInUse -Path $file.FullName) { $file }
        }
    }
}

function Move-InUseFileAside {
    <#
    .SYNOPSIS
        Rename every in-use executable under $Directory aside so an installer can
        write its replacement. Returns one Original/Renamed pair per renamed file.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Directory)

    $dirs = @($Directory | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
    if ($dirs.Count -eq 0) { return }

    foreach ($left in @(Get-SetAsideFile -Directory $dirs)) {
        $null = Resolve-SetAsideFile -Original $left.Original -Renamed $left.Renamed -Obsolete:$left.Obsolete -Owner $left.Owner -Stamp $left.Stamp
    }

    $setAt = Get-Date
    $stamp = $setAt.ToString('yyyyMMddHHmmssfff')
    foreach ($file in @(Get-InUseFile -Directory $dirs)) {
        $renamed = "$($file.FullName).superseded-$stamp-$PID"
        try {
            [System.IO.File]::Move($file.FullName, $renamed)
            Write-Verbose "Set aside in-use '$($file.FullName)' as '$renamed'."
            [pscustomobject]@{ Original = $file.FullName; Renamed = $renamed; SetAt = $setAt }
        } catch {
            Write-Warning "Could not set aside in-use file '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

function Complete-InUseFileAside {
    <#
    .SYNOPSIS
        Settle the pairs Move-InUseFileAside returned once the engine has run.
        -Upgraded says the engine upgraded the package, so a missing original is a
        file the new version dropped, not one to put back. Returns counts: Moved,
        Restored, Kept (still running; a later run deletes it).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Moved,
        [switch]$Upgraded
    )

    $pairs = @($Moved | Where-Object { $_ })
    $restored = 0
    $kept = 0
    foreach ($pair in $pairs) {
        $setAt = if ($pair.PSObject.Properties['SetAt']) { $pair.SetAt } else { $null }
        switch (Resolve-SetAsideFile -Original $pair.Original -Renamed $pair.Renamed -Upgraded:$Upgraded -SetAt $setAt) {
            'Restored' { $restored++ }
            'Kept'     { $kept++ }
        }
    }
    [pscustomobject]@{ Moved = $pairs.Count; Restored = $restored; Kept = $kept }
}

function Get-InUseUpgradeNote {
    # The summary note for an upgrade that went ahead while the program ran.
    [OutputType([string])]
    param([int]$Count)
    "upgraded while running ($Count file(s) in use); copies already running keep the previous version until they restart"
}