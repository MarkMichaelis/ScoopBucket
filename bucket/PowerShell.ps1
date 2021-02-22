
Write-Host 'Installing and configuring PowerShell...'
. "$PSScriptRoot\Utils.ps1"

Update-Help -ErrorAction Ignore
if((Get-PSRepository PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy 'Trusted'
}
Install-Module PowershellGet -Repository PSGallery  # Updated to allow support for -AllowPrerelease
Install-Module Pscx -AllowClobber -AllowPrerelease  # Both Pscx and IntelliTect.File support Edit-File. 
                                                    # IntelliTect.File will get priority once if it appears first in the PSModulePath
                                                    # or it is installed after Pscx (if not using source code)

scoop install Pester



