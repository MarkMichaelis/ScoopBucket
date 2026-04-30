
. "$PSScriptRoot\Utils.ps1"

# OpenAI ships the official ChatGPT desktop app via the Microsoft Store
# (Publisher: OpenAI, ProductId: 9NT1R1C2HH7J). winget's `msstore` source
# is the cleanest fully-automated install path: signed by OpenAI, kept
# up-to-date by the Store, and survives Cloudflare's TLS fingerprinting
# of chatgpt.com (which blocks all PowerShell/.NET HTTP traffic at the
# JA3 layer regardless of header tuning -- only the Schannel-curl ALPN
# fingerprint gets through, and even then chatgpt.com/download/ is a
# JS-rendered SPA with no static .exe URL).

Function Install-ChatGPT {
    Write-Host "Running $($MyInvocation.MyCommand.Name)..."

    if (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT\ChatGPT.exe')) {
        Write-Host 'ChatGPT desktop already installed (squirrel/legacy); skipping.'
        return
    }
    if (Get-AppxPackage -Name 'OpenAI.ChatGPT-Desktop' -ErrorAction SilentlyContinue) {
        Write-Host 'ChatGPT desktop (MS Store) already installed; skipping.'
        return
    }

    if (-not (Test-Command -Name winget)) {
        Write-Warning 'winget is not installed; cannot fetch ChatGPT from the Microsoft Store. Install App Installer from the Store, then re-run.'
        return
    }

    $msStoreId = '9NT1R1C2HH7J'
    Write-Host "Installing ChatGPT from Microsoft Store (id: $msStoreId, publisher: OpenAI) via winget..."
    $args = @(
        'install', '--id', $msStoreId,
        '--exact',
        '--source', 'msstore',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--silent',
        '--disable-interactivity'
    )
    & winget @args
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget exited with code $LASTEXITCODE while installing ChatGPT (id $msStoreId). You may need to be signed in with a Microsoft account, or install manually from https://apps.microsoft.com/detail/$msStoreId."
        return
    }
    Write-Host 'ChatGPT desktop installed.'
}
Install-ChatGPT
