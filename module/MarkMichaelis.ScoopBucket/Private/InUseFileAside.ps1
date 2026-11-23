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
# directories to '<name>.superseded-<timestamp>' just before the engine runs.
# Complete-InUseFileAside settles each one afterwards:
#   - a replacement exists at the original path -> delete the set-aside copy, or,
#     while a process still runs it, keep it for a later run to delete;
#   - no replacement (no upgrade, or the upgrade failed) -> put it back.
# Every Move-InUseFileAside call first settles leftovers from earlier runs the same
# way, which is what eventually deletes a copy that was still running last time and
# recovers from a run that was interrupted between the rename and the settle.

$script:SupersededMarker = '.superseded-'

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
    # sharing) cannot be opened exclusively for writing. Access-denied (read-only,
    # ACL) is NOT "in use": that is left for the engine to report.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None').Dispose()
        return $false
    } catch {
        $e = $_.Exception
        while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
        return ($e -is [System.IO.IOException] -and $e -isnot [System.IO.FileNotFoundException] -and $e -isnot [System.IO.DirectoryNotFoundException])
    }
}

function Resolve-SupersededFile {
    # Settle one set-aside copy. Returns 'Deleted', 'Restored', or 'Kept' (a
    # process still runs it, so a later run deletes it).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Original,
        [Parameter(Mandatory)][string]$Renamed
    )

    if (-not (Test-Path -LiteralPath $Renamed)) { return 'Deleted' }
    if (-not (Test-Path -LiteralPath $Original)) {
        try {
            Move-Item -LiteralPath $Renamed -Destination $Original -ErrorAction Stop
            return 'Restored'
        } catch {
            Write-Warning "Could not put '$Original' back from '$Renamed': $($_.Exception.Message)"
            return 'Kept'
        }
    }
    try {
        Remove-Item -LiteralPath $Renamed -Force -ErrorAction Stop
        return 'Deleted'
    } catch {
        return 'Kept'
    }
}

function Get-SupersededFile {
    # Set-aside copies left under $Directory by earlier runs, as Original/Renamed pairs.
    [CmdletBinding()]
    param([string[]]$Directory)

    foreach ($dir in $Directory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $at = $file.Name.LastIndexOf($script:SupersededMarker, [StringComparison]::OrdinalIgnoreCase)
            if ($at -le 0 -or $file.Name.Substring($at + $script:SupersededMarker.Length) -notmatch '^\d+$') { continue }
            [pscustomobject]@{
                Original = Join-Path $file.DirectoryName $file.Name.Substring(0, $at)
                Renamed  = $file.FullName
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

    foreach ($left in @(Get-SupersededFile -Directory $dirs)) {
        $null = Resolve-SupersededFile -Original $left.Original -Renamed $left.Renamed
    }

    $stamp = (Get-Date).ToString('yyyyMMddHHmmssfff')
    foreach ($file in @(Get-InUseFile -Directory $dirs)) {
        $renamed = "$($file.FullName)$($script:SupersededMarker)$stamp"
        try {
            Move-Item -LiteralPath $file.FullName -Destination $renamed -ErrorAction Stop
            Write-Verbose "Set aside in-use '$($file.FullName)' as '$renamed'."
            [pscustomobject]@{ Original = $file.FullName; Renamed = $renamed }
        } catch {
            Write-Warning "Could not set aside in-use file '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

function Complete-InUseFileAside {
    <#
    .SYNOPSIS
        Settle the pairs Move-InUseFileAside returned once the engine has run.
        Returns counts: Moved, Restored (no replacement was written), Kept (still
        running; a later run deletes it).
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Moved)

    $pairs = @($Moved | Where-Object { $_ })
    $restored = 0
    $kept = 0
    foreach ($pair in $pairs) {
        switch (Resolve-SupersededFile -Original $pair.Original -Renamed $pair.Renamed) {
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
