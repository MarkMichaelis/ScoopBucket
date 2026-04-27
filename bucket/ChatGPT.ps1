
. "$PSScriptRoot\Utils.ps1"

# OpenAI ChatGPT desktop is not in any package manager and its installer URL
# (https://chatgpt.com/download) is gated by a Cloudflare bot challenge that
# fingerprints at the TLS layer, so neither Invoke-WebRequest nor curl can
# fetch it. The pragmatic compromise: open the official download page in the
# user's browser, wait for the ChatGPT-*.exe installer to appear in Downloads,
# then run it silently. The installer is a Squirrel.Windows installer and
# supports `--silent` for unattended install.

Function Install-ChatGPT {
    Write-Host "Running $($MyInvocation.MyCommand.Name)..."

    if (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT\ChatGPT.exe')) {
        Write-Host 'ChatGPT desktop already installed; skipping.'
        return
    }

    $downloadsDir = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path $downloadsDir)) {
        New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
    }

    $existing = @{}
    Get-ChildItem -Path $downloadsDir -Filter 'ChatGPT*.exe' -ErrorAction SilentlyContinue |
        ForEach-Object { $existing[$_.FullName] = $_.LastWriteTimeUtc }

    Write-Host 'Opening https://chatgpt.com/download in your default browser. Click "Download for Windows" and save the installer to your Downloads folder.'
    Start-Process 'https://chatgpt.com/download' | Out-Null

    $timeoutSeconds = 300
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $installer = $null
    Write-Host "Waiting up to $timeoutSeconds seconds for ChatGPT-*.exe to appear in $downloadsDir ..."
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-ChildItem -Path $downloadsDir -Filter 'ChatGPT*.exe' -ErrorAction SilentlyContinue |
            Where-Object {
                # New file, or existing file with a newer LastWriteTime, and
                # not still being written (size stable for >2s).
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
        Write-Warning "ChatGPT installer was not found in $downloadsDir within $timeoutSeconds seconds. Aborting; install manually from https://chatgpt.com/download."
        return
    }

    Write-Host "Found installer: $($installer.FullName). Running silently..."
    $proc = Start-Process -FilePath $installer.FullName -ArgumentList '--silent' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "ChatGPT installer exited with code $($proc.ExitCode)."
    }
    else {
        Write-Host 'ChatGPT desktop installed.'
    }
}
Install-ChatGPT
