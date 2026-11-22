
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

# Google's dedicated Gemini app for Windows (launched 2026-09-10,
# gemini.google/desktop), published to winget by Google LLC as
# Google.GeminiDesktop. It replaces the "Google app for desktop" this script
# used to install by rebuilding an Omaha download URL from constants scraped
# out of search.google's JavaScript, with a browser-watch fallback that needed
# a manual Download click (#25, #26, #534). An existing Google app install is
# left in place: it is a separate product (search, Lens). Both apps default to
# Alt+Space.
#
# The winget manifest declares a nullsoft installer with Scope: user and no
# machine-scope variant, so Scope='user' is required. Without it the engine
# defaults to --scope machine and winget walks back through manifest versions
# to a machine-applicable one, silently installing a stale build (#433).

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Gemini'
        Installer   = 'winget'
        Id          = 'Google.GeminiDesktop'
        Scope       = 'user'
        CliCommands = @()
        Notes       = 'Gemini desktop app (gemini.google/desktop), winget Google.GeminiDesktop from Google LLC. User-scope nullsoft installer only. Replaces the Google app for desktop (#534).'
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'Gemini'
