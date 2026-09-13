# Read-mutate-write helpers shared by the tool configuration imports
# (Import-WindowsTerminalSettings, Import-ClaudeCodeSettings; #412). Each writer
# returns $true only when it actually changed the file, so re-runs are no-ops and
# callers can report what changed. All honour -WhatIf.

function Read-JsonSettingsFile {
    # The file as an ordered hashtable; an empty one when the file is missing or blank.
    # Comments (JSONC) are accepted. Invalid JSON throws rather than being overwritten.
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [ordered]@{} }
    $text = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return [ordered]@{} }
    , ($text | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Write-JsonSettingsFile {
    # Writes $Settings as JSON unless the file already holds the same content
    # (compared semantically, so formatting-only differences never trigger a write).
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [string]$Action = 'Write settings'
    )

    $json = $Settings | ConvertTo-Json -Depth 100
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = Read-JsonSettingsFile -Path $Path
        if (($current | ConvertTo-Json -Depth 100 -Compress) -eq ($Settings | ConvertTo-Json -Depth 100 -Compress)) { return $false }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return $false }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $true
}

function Copy-FileIfChanged {
    # Copies $Source to $Destination unless the destination already has the same text.
    # -LfLineEndings writes LF only (bash rejects CRLF scripts, and a Windows checkout
    # may have converted the committed file to CRLF).
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$LfLineEndings
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Source file not found: $Source" }
    $text = [System.IO.File]::ReadAllText($Source)
    if ($LfLineEndings) { $text = $text -replace "`r`n", "`n" }
    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and [System.IO.File]::ReadAllText($Destination) -ceq $text) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Destination, "Install $(Split-Path -Leaf $Source)")) { return $false }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    [System.IO.File]::WriteAllText($Destination, $text, [System.Text.UTF8Encoding]::new($false))
    $true
}

function Add-LinesIfMissing {
    # Appends $Lines to $Path (creating it) unless the file already contains $Match.
    # Uses the file's existing line ending, or LF with -LfLineEndings (bash files).
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Match,
        [Parameter(Mandatory)][string[]]$Lines,
        [switch]$LfLineEndings
    )

    $current = if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::ReadAllText($Path) } else { '' }
    if ($current.Contains($Match)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, "Add $Match")) { return $false }
    $newline = if ($LfLineEndings) { "`n" } elseif ($current.Contains("`r`n") -or -not $current) { "`r`n" } else { "`n" }
    $prefix = if ($current -and -not $current.EndsWith("`n")) { $newline } else { '' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::AppendAllText($Path, $prefix + ($Lines -join $newline) + $newline, [System.Text.UTF8Encoding]::new($false))
    $true
}

function Get-WindowsTerminalSettingsPath {
    # Settings file of the installed Windows Terminal: the Store/winget package, then
    # Preview, then an unpackaged (e.g. Scoop) install. Falls back to the stable
    # package path so a Terminal that has never been launched gets settings there.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($found) { $found } else { $candidates[0] }
}
