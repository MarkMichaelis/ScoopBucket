$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# OpenAI ships the official ChatGPT desktop app via the Microsoft Store
# (Publisher: OpenAI, ProductId: 9NT1R1C2HH7J). winget's `msstore` source
# is the cleanest fully-automated install path: signed by OpenAI, kept
# up-to-date by the Store, and survives Cloudflare's TLS fingerprinting
# of chatgpt.com (which blocks all PowerShell/.NET HTTP traffic at the
# JA3 layer regardless of header tuning -- only the Schannel-curl ALPN
# fingerprint gets through, and even then chatgpt.com/download/ is a
# JS-rendered SPA with no static .exe URL).

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'ChatGPT'
        Installer   = 'winget'
        Id          = '9NT1R1C2HH7J'
        Source      = 'msstore'
        CliCommands = @()
        VerifyScript = {
            [bool](Get-AppxPackage -Name 'OpenAI.ChatGPT-Desktop' -ErrorAction SilentlyContinue) -or
            (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT\ChatGPT.exe'))
        }
        Notes       = 'Official MS Store listing (publisher: OpenAI). chatgpt.com/download/ is JS-rendered SPA + JA3-fingerprinted.'
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'ChatGPT'
