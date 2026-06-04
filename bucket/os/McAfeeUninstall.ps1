
Write-Host "Uninstalling McAfee Applications..."

$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

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