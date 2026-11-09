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

# OpenAI ships the official ChatGPT desktop app via the Microsoft Store
# (Publisher: OpenAI, ProductId: 9PLM9XGG6VKS). winget's `msstore` source
# is the cleanest fully-automated install path: signed by OpenAI, kept
# up-to-date by the Store, and survives Cloudflare's TLS fingerprinting
# of chatgpt.com (which blocks all PowerShell/.NET HTTP traffic at the
# JA3 layer regardless of header tuning -- only the Schannel-curl ALPN
# fingerprint gets through, and even then chatgpt.com/download/ is a
# JS-rendered SPA with no static .exe URL).
#
# 9PLM9XGG6VKS is the current app (Chat, Work and Codex in one), package
# family OpenAI.Codex_2p2nqsd0c76g0 -- the same identity the winget
# community package OpenAI.ChatGPT installs from OpenAI's CDN. The previous
# listing, 9NT1R1C2HH7J (package OpenAI.ChatGPT-Desktop), is now "ChatGPT
# Classic" and retires 2027-01-30 (#511). It is a separate Appx package, so
# installing this one leaves Classic in place; VerifyScript deliberately
# ignores Classic so a machine that only has it does not read as migrated.

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'ChatGPT'
        Installer   = 'winget'
        Id          = '9PLM9XGG6VKS'
        Source      = 'msstore'
        CliCommands = @()
        VerifyScript = {
            [bool](Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
        }
        Notes       = 'Official MS Store listing (publisher: OpenAI), package OpenAI.Codex. Replaces ChatGPT Classic (9NT1R1C2HH7J), retiring 2027-01-30 (#511). chatgpt.com/download/ is JS-rendered SPA + JA3-fingerprinted.'
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'ChatGPT'
