
#region MarkMichaelis.ScoopBucket bundle module import (scoop-portable; see README)
$scoopBucketModule = 'MarkMichaelis.ScoopBucket'
$scoopBucketPsd1 = Join-Path $PSScriptRoot "..\..\module\$scoopBucketModule\$scoopBucketModule.psd1"
if (-not (Test-Path $scoopBucketPsd1)) {
    $scoopBucketRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $PSScriptRoot '..\..\..' }
    $scoopBucketFound = Get-ChildItem -Path (Join-Path $scoopBucketRoot "buckets\*\module\$scoopBucketModule\$scoopBucketModule.psd1") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($scoopBucketFound) { $scoopBucketPsd1 = $scoopBucketFound.FullName }
}
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module $scoopBucketModule -Force }
#endregion MarkMichaelis.ScoopBucket bundle module import

# Google's "Google app for desktop" (which embeds Gemini and binds Alt+Space)
# is the only official Windows-native Gemini surface. Google does not publish
# the install URL as static HTML; the "Download the app" button on
# https://search.google/google-app/desktop/ runs JavaScript that calls
# `_GU_buildDlPath(...)` (Google's Omaha download-tag builder, served from
# tools.google.com/tools/dlpage/res/c/gu-util.js) with hardcoded constants
# extracted from the page's main.min.js bundle:
#
#     appguid     = {06A8089E-0B65-445D-B5C4-10B0D1B540F2}
#     appname     = "Google App"
#     needsadmin  = "False"
#     ap          = "ga"
#     baseUrl     = https://dl.google.com
#     suffix      = /windows-google-app/GoogleAppInstaller.exe
#
# See the source of `kn()` in https://search.google/static/js/main.min.js .
# We reproduce the URL build server-side so the entire install can run with
# no browser, no Playwright, and no user interaction. If Google ever rotates
# these constants and the direct fetch fails, we fall back to the legacy
# browser-watch pattern (open the page, wait for the user to click Download,
# watch ~/Downloads/GoogleApp*.exe).
#
# The installer is the standard Omaha bootstrapper (same family as Chrome,
# Drive, Earth) which has supported `--silent --install` for 15+ years. We
# pass those switches and fall back to interactive only if silent fails.

Function Get-GeminiInstallerUrl {
    [OutputType([string])]
    [CmdletBinding()]
    param()

    $appguid    = '{06A8089E-0B65-445D-B5C4-10B0D1B540F2}'
    $appname    = 'Google App'
    $needsadmin = 'False'
    $ap         = '&ap=ga'
    $iid        = '{00000000-0000-0000-0000-000000000000}'
    $lang       = 'en'
    $browser    = '5'
    $usagestats = '0'
    $suffix     = '/windows-google-app/GoogleAppInstaller.exe'
    $baseUrl    = 'https://dl.google.com'

    # Reproduce GU_BuildTag(): appguid first, then customParams, then iid+lang+browser+usagestats,
    # then appname+needsadmin. appname is URL-encoded with the same character set as the JS does.
    $encName = [uri]::EscapeDataString($appname) -replace "'", '%27' `
                                                  -replace '\(', '%28' `
                                                  -replace '\)', '%29' `
                                                  -replace '~',  '%7E' `
                                                  -replace '!',  '%21' `
                                                  -replace '\*', '%2A'
    $tag = "appguid=$appguid$ap&iid=$iid&lang=$lang&browser=$browser&usagestats=$usagestats&appname=$encName&needsadmin=$needsadmin"
    $encTag = [uri]::EscapeDataString($tag)
    return "$baseUrl/tag/s/$encTag$suffix"
}

Function Install-GeminiDirect {
    [OutputType([System.IO.FileInfo])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $url = Get-GeminiInstallerUrl
    Write-Host "Downloading Google app installer from dl.google.com ..."
    # curl.exe is the most reliable HTTPS client on Windows for Google's CDN
    # (matches the bytes the browser would send). PowerShell's Invoke-WebRequest
    # also works against dl.google.com but curl avoids any TLS-fingerprint risk.
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    & curl.exe -sSL -A $ua -o $DestinationPath $url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $DestinationPath) -or (Get-Item $DestinationPath).Length -lt 100000) {
        if (Test-Path $DestinationPath) { Remove-Item -Force $DestinationPath -ErrorAction SilentlyContinue }
        throw "Direct download from dl.google.com failed (curl exit $LASTEXITCODE)."
    }
    return Get-Item $DestinationPath
}

Function Install-GeminiBrowserWatch {
    [OutputType([System.IO.FileInfo])]
    [CmdletBinding()]
    param()

    $downloadsDir = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path $downloadsDir)) {
        New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
    }

    $existing = @{}
    Get-ChildItem -Path $downloadsDir -Filter 'GoogleApp*.exe' -ErrorAction SilentlyContinue |
        ForEach-Object { $existing[$_.FullName] = $_.LastWriteTimeUtc }

    Write-Host 'Direct download failed. Falling back to browser-watch.'
    Write-Host 'Opening https://search.google/google-app/desktop/ in your default browser. Click "Download the app" and save to your Downloads folder.'
    Start-Process 'https://search.google/google-app/desktop/' | Out-Null

    $timeoutSeconds = 300
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
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
                return $candidate
            }
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

Function Install-Gemini {
    Write-Host "Running $($MyInvocation.MyCommand.Name)..."

    # The browser-watch fallback (and Google's Cloudflare-fronted CDN) requires
    # an interactive user to click "Download the app" and complete the install.
    # In headless CI there is no such user, so the install hangs until the job
    # times out (see issues #25, #26). Early-exit cleanly so the bundle records
    # this package as 'untested' rather than failing the whole CI run.
    if ($env:CI -or $env:GITHUB_ACTIONS -eq 'true') {
        Write-Host 'Gemini install requires interactive download — skipping in CI.'
        return
    }

    $installedMarker = Join-Path $env:LOCALAPPDATA 'Google\Google\latest\google.exe'
    if (Test-Path $installedMarker) {
        Write-Host 'Google app for desktop already installed; skipping.'
        return
    }

    $installer = $null
    $tempPath = Join-Path $env:TEMP "GoogleAppInstaller-$([guid]::NewGuid().ToString('N')).exe"
    try {
        $installer = Install-GeminiDirect -DestinationPath $tempPath
    }
    catch {
        Write-Warning $_.Exception.Message
        $installer = Install-GeminiBrowserWatch
    }

    if (-not $installer) {
        Write-Warning "Google app installer was not obtained. Aborting; install manually from https://search.google/google-app/desktop/."
        return
    }

    Write-Host "Found installer: $($installer.FullName) ($([math]::Round($installer.Length/1MB,1)) MB). Running silently (--silent --install)..."
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

    # Clean up direct-download temp file (browser-watch leaves it in Downloads, which we don't touch)
    if ($installer.FullName -like "$env:TEMP*") {
        Remove-Item -Force $installer.FullName -ErrorAction SilentlyContinue
    }
}
Install-Gemini
