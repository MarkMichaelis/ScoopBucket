
. "$PSScriptRoot\Utils.ps1"

# Google's "Google app for desktop" (which embeds Gemini and binds Alt+Space)
# is the only official Windows-native Gemini surface. Google does not publish
# a stable dl.google.com URL for it; the "Download app" button on
# https://search.google/google-app/desktop/ resolves the installer URL via
# JavaScript at click time. We therefore use the same browser-watch pattern as
# ChatGPT.ps1: open the official page, wait for the installer to land in
# Downloads, then launch it silently.
#
# The installer (`GoogleAppInstaller.exe`) is built on Google's Omaha /
# Google Update framework (the same one used for Chrome, Drive, Earth, etc.)
# which has supported `--silent --install` for 15+ years. We pass those
# switches and fall back to an interactive launch only if the silent run
# returns a non-zero exit code.

Function Install-Gemini {
    Write-Host "Running $($MyInvocation.MyCommand.Name)..."

    $installedMarker = Join-Path $env:LOCALAPPDATA 'Google\GoogleApp'
    if (Test-Path $installedMarker) {
        Write-Host 'Google app for desktop already installed; skipping.'
        return
    }

    $downloadsDir = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path $downloadsDir)) {
        New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
    }

    $existing = @{}
    Get-ChildItem -Path $downloadsDir -Filter 'GoogleApp*.exe' -ErrorAction SilentlyContinue |
        ForEach-Object { $existing[$_.FullName] = $_.LastWriteTimeUtc }

    Write-Host 'Opening https://search.google/google-app/desktop/ in your default browser. Click "Download app" and save the installer to your Downloads folder.'
    Start-Process 'https://search.google/google-app/desktop/' | Out-Null

    $timeoutSeconds = 300
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $installer = $null
    Write-Host "Waiting up to $timeoutSeconds seconds for GoogleApp*.exe to appear in $downloadsDir ..."
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-ChildItem -Path $downloadsDir -Filter 'GoogleApp*.exe' -ErrorAction SilentlyContinue |
            Where-Object {
                (-not $existing.ContainsKey($_.FullName)) -or ($_.LastWriteTimeUtc -gt $existing[$_.FullName])
            } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($candidate) {
            $size1 = $candidate.Length
            Start-Sleep -Seconds 2
            $candidate.Refresh()
            if ($candidate.Length -eq $size1 -and $candidate.Length -gt 0) {
                $installer = $candidate
                break
            }
        }
        Start-Sleep -Seconds 2
    }

    if (-not $installer) {
        Write-Warning "Google app installer was not found in $downloadsDir within $timeoutSeconds seconds. Aborting; install manually from https://search.google/google-app/desktop/."
        return
    }

    Write-Host "Found installer: $($installer.FullName). Running silently (--silent --install)..."
    $proc = Start-Process -FilePath $installer.FullName -ArgumentList '--silent','--install' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "Silent install exited with code $($proc.ExitCode). Re-launching interactively..."
        $proc = Start-Process -FilePath $installer.FullName -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Warning "Google app installer exited with code $($proc.ExitCode)."
            return
        }
    }
    Write-Host 'Google app for desktop installed.'
}
Install-Gemini
