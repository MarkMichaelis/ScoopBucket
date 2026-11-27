#requires -Version 7.0
# See OSBasePackages.ps1: stops scoop recording a failed install (#504).

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

# PowerShell (#563): the PowerShell editions and their module set-up, shown as
# one group inside OS Base, which installs it. Each item is a manifest of
# this bucket that runs developer\PowerShellSetup.ps1 under that edition.

$Packages = [Package[]]@(
    # PowerShell 7, the default pwsh.
    [Package]@{ Name = 'PowerShellCore'; Installer = 'scoop'; Id = 'MarkMichaelis/PowerShellCore' }
    # Installs side by side with PowerShellCore; making it the default pwsh
    # is #570.
    [Package]@{ Name = 'PowerShellCorePreview'; Installer = 'scoop'; Id = 'MarkMichaelis/PowerShellCorePreview'; Default = $false }
    # Windows ships PowerShell 5.1; this sets up its modules and profile.
    [Package]@{ Name = 'Windows PowerShell 5.1 modules'; Installer = 'scoop'; Id = 'MarkMichaelis/PowerShellWindows'; Default = $false }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'PowerShell'
