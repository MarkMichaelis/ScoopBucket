
Write-Host "Uninstalling McAfee Applications..."

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

Function Uninstall-McAfeeApplications {
    Get-Program 'McAfee*' | ForEach-Object {
        try {
            Write-Host "Uninstalling $($_.Name)..."
            $UninstallCmd = $_.UninstallString
            # String up to and including the .exe
            $UninstallExecutible = $UninstallCmd.substring(0, $UninstallCmd.IndexOf(".exe") + 4 )
            # Any parts after the .exe		
            $UninstallArguments = $UninstallCmd.substring($UninstallCmd.IndexOf(".exe") + 4 )
            $parms = @{
                "FilePath" = "$UninstallExecutible";
                "Wait"     = $true;
                "PassThru" = $true;
            }
            if (-not [string]::IsNullOrWhiteSpace($UninstallArguments)) {
                $parms.Add("ArgumentList", "$UninstallArguments")
            }
            Start-Process @parms
        }
        catch {
            Write-Error "Error occurred: $_"
        }
    }
}
Uninstall-McAfeeApplications