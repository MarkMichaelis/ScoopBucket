function Export-PowerToysSettings {
    <#
    .SYNOPSIS
        Capture the live PowerToys settings into a scrubbed, committable snapshot.
    .DESCRIPTION
        Reads every *.json settings file under the PowerToys settings folder
        (skipping volatile logs / telemetry / update-state), neutralizes secret
        and machine-identity values (MouseWithoutBorders SecurityKey + identity,
        Advanced Paste AI provider keys), and returns a single snapshot object
        keyed by relative path. Everything the user wants to carry between
        machines -- which modules are enabled, every keyboard shortcut / hotkey,
        FancyZones layouts, Keyboard Manager remaps -- is preserved verbatim.

        A residual-secret guard runs before the snapshot is returned; if any
        sensitive value survived scrubbing the function throws rather than emit a
        snapshot that could leak a secret into a public repo.

        When -Path is supplied the snapshot is also written there as indented
        JSON (the form committed at bucket/os/MarkMichaelisPowerToysSettings.jsonc).
    .PARAMETER SettingsRoot
        Override the live settings folder (defaults to
        %LOCALAPPDATA%\Microsoft\PowerToys).
    .PARAMETER Path
        Optional file path to write the snapshot JSON to.
    .OUTPUTS
        PSCustomObject -- schema, generated, files (relativePath -> object).
    .EXAMPLE
        Export-PowerToysSettings -Path .\bucket\os\MarkMichaelisPowerToysSettings.jsonc
        Captures this machine's scrubbed settings to the committed snapshot file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$SettingsRoot = (Get-PowerToysSettingsPath),
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $SettingsRoot -PathType Container)) {
        throw "PowerToys settings folder not found: $SettingsRoot"
    }

    $files = [ordered]@{}
    $jsonFiles = Get-ChildItem -LiteralPath $SettingsRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue
    foreach ($file in $jsonFiles) {
        $rel = $file.FullName.Substring($SettingsRoot.Length).TrimStart('\', '/')
        if (Test-PowerToysPathExcluded -RelativePath $rel) { continue }
        try {
            $parsed = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Skipping unparseable settings file '$rel': $($_.Exception.Message)"
            continue
        }
        $files[($rel -replace '\\', '/')] = Get-PowerToysScrubbedObject -InputObject $parsed
    }

    $snapshot = [pscustomobject]@{
        schema    = 1
        generated = (Get-Date).ToString('o')
        files     = [pscustomobject]$files
    }

    $violations = Get-PowerToysSnapshotViolation -InputObject $snapshot.files
    if ($violations.Count -gt 0) {
        throw "Refusing to emit PowerToys snapshot; residual secrets detected:`n$($violations -join "`n")"
    }

    if ($Path) {
        if ($PSCmdlet.ShouldProcess($Path, 'Write PowerToys settings snapshot')) {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }

    return $snapshot
}
