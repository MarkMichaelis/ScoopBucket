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


Function Resolve-GhAliasFile {
    # Returns the path to the gh-aliases.yml shipped alongside this script, or
    # $null when it is missing. Scoop downloads both files into the same app
    # dir (see GitConfigGitHubCli.json), and a repo checkout has them as
    # siblings too, so $PSScriptRoot resolves it in both layouts.
    [CmdletBinding()]
    param()
    $yml = Join-Path $PSScriptRoot 'gh-aliases.yml'
    if (Test-Path -LiteralPath $yml -PathType Leaf) { return $yml }
    return $null
}

Function Invoke-GitConfigGitHubCli {
    # Applies this bucket's per-user `gh` aliases. gh keeps aliases in
    # %APPDATA%\GitHub CLI\config.yml -- per-user state, so this runs
    # unelevated and is deliberately NOT machine-scoped like the CLI install
    # itself (`winget install --scope machine GitHub.cli` in GitConfigure.ps1).
    if (-not (Get-Command gh -ErrorAction Ignore)) {
        Write-Warning "gh not found. Skipping GitHub CLI alias configuration."
        return
    }

    $yml = Resolve-GhAliasFile
    if (-not $yml) {
        Write-Warning "gh-aliases.yml not found alongside GitConfigGitHubCli.ps1. Skipping GitHub CLI alias configuration."
        return
    }

    # `gh alias import` over `gh alias set`: the expansions are POSIX shell
    # one-liners dense with single quotes and `$`, and handing gh a file on
    # disk sidesteps PowerShell native-argument quoting entirely. --clobber
    # makes re-runs idempotent by overwriting same-named aliases rather than
    # failing on the second install.
    $output = & gh alias import $yml --clobber 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gh alias import failed (exit $LASTEXITCODE): $output"
        return
    }

    $names = @(
        Get-Content -LiteralPath $yml |
            Where-Object { $_ -match '^(?<name>[A-Za-z0-9_-]+):' } |
            ForEach-Object { $Matches.name }
    )
    Write-Host "GitHub CLI aliases configured: $($names -join ', ')"
}
Invoke-GitConfigGitHubCli
