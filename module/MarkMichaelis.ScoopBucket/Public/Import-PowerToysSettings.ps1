function Import-PowerToysSettings {
    <#
    .SYNOPSIS
        Apply a committed PowerToys settings snapshot to this machine.
    .DESCRIPTION
        Restores the scrubbed snapshot produced by Export-PowerToysSettings so a
        freshly installed PowerToys picks up the same enabled modules, keyboard
        shortcuts, FancyZones layouts, and Keyboard Manager remaps. PowerToys is
        stopped first (so it does not overwrite the files as they are written)
        and relaunched afterward unless -NoRestart is given.

        Designed to run as the PowerToys package ConfigScript: with no
        arguments it reads the snapshot committed at
        bucket/os/MarkMichaelisPowerToysSettings.jsonc and writes into
        %LOCALAPPDATA%\Microsoft\PowerToys. Honours -WhatIf.

        The committed snapshot lives in the bucket (not inside the module), so
        the ConfigScript in ClientBasePackages.ps1 passes an explicit
        -SnapshotPath resolved from its own $PSScriptRoot; the default below
        resolves the same file when the module is imported directly from the
        repo.

        Secret/identity values were neutralized at capture time, so after a
        restore MouseWithoutBorders must be re-paired (its SecurityKey is
        intentionally absent from the committed snapshot).
    .PARAMETER SnapshotPath
        Path to the snapshot JSON (defaults to the module's bundled snapshot).
    .PARAMETER SettingsRoot
        Override the live settings folder (defaults to
        %LOCALAPPDATA%\Microsoft\PowerToys).
    .PARAMETER NoRestart
        Do not relaunch PowerToys after applying the snapshot.
    .OUTPUTS
        PSCustomObject -- SettingsRoot, SnapshotPath, FileCount, Files.
    .EXAMPLE
        Import-PowerToysSettings
        Restores the bundled snapshot into the live PowerToys settings folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$SnapshotPath = (Join-Path $PSScriptRoot '..\..\..\bucket\os\MarkMichaelisPowerToysSettings.jsonc'),
        [string]$SettingsRoot = (Get-PowerToysSettingsPath),
        [switch]$NoRestart
    )

    if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) {
        throw "PowerToys settings snapshot not found: $SnapshotPath"
    }

    $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    $writeSet = ConvertTo-PowerToysWriteSet -Snapshot $snapshot -SettingsRoot $SettingsRoot

    Stop-PowerToysProcess

    $written = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $writeSet) {
        if ($PSCmdlet.ShouldProcess($entry.FullPath, 'Apply PowerToys setting')) {
            $dir = Split-Path -Parent $entry.FullPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Set-Content -LiteralPath $entry.FullPath -Value $entry.Json -Encoding UTF8
            $written.Add($entry.RelativePath)
        }
    }

    if (-not $NoRestart) { Start-PowerToysProcess }

    return [pscustomobject]@{
        SettingsRoot = $SettingsRoot
        SnapshotPath = $SnapshotPath
        FileCount    = $written.Count
        Files        = $written.ToArray()
    }
}
