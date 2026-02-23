
Write-Host 'Installing and configuring PowerShell...'
. "$PSScriptRoot\Utils.ps1"

Update-Help -ErrorAction Ignore
if((Get-PSRepository PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy 'Trusted'
}
Install-Module PowershellGet -Repository PSGallery -Scope AllUsers  # Updated to allow support for -AllowPrerelease
Install-Module Pscx -AllowClobber -AllowPrerelease -Scope AllUsers  # Both Pscx and IntelliTect.File support Edit-File. 
                                                                    # IntelliTect.File will get priority once if it appears first in the PSModulePath
                                                                    # or it is installed after Pscx (if not using source code)
Install-Module ZLocation -Repository PSGallery -Scope AllUsers
Install-Module PSReadLine -Force -Scope AllUsers   # Update the version of PSReadline
Install-Module Microsoft.PowerShell.SecretManagement -Scope AllUsers
choco install Pester



