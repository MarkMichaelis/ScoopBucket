Write-Host 'Installing and configuring Chocolatey...'

$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

Function Install-Chocolatey {
    
    if (-not (Test-Command choco)) {
        Write-Output "Installing Chocolatey..."
        Invoke-WebRequest https://chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression
    }
    Write-Output "Configuring Chocolatey..."
    choco feature enable -n allowglobalconfirmation
    choco feature enable -n allowEmptyChecksums
    choco feature enable -n allowEmptyChecksumsSecure

    #Set environment variables so the above options are true when directly calling Chocolatey functions/commands:
    [Environment]::SetEnvironmentVariable("ChocolateyAllowEmptyChecksums", $true, 'Machine')
    [Environment]::SetEnvironmentVariable("ChocolateyAllowEmptyChecksumsSecure", $true, 'Machine')
    [Environment]::SetEnvironmentVariable("ChocolateyToolsLocation", "$env:ChocolateyInstall\Tools", 'Machine')

    # TODO: Figure repository for API Key
    if (Test-Path C:\data\Profile\ChocolateyAPIKey.txt) {
        Get-Content C:\data\Profile\ChocolateyAPIKey.txt | Foreach-Object { choco setapikey $_ }
    }

    choco install chocolatey-core.extension -y

    choco install au -y # Automatic Chocolatey Package Update

    if (Test-Path C:\Dropbox\Profile\chocolatey.license.xml) {
        [string]$chocolateyLicenseFolder = (Join-Path "$env:ChocolateyInstall" 'License')
        if (-not (Test-Path $chocolateyLicenseFolder)) {
            New-Item -ItemType Directory -Path $chocolateyLicenseFolder -Force | Out-Null
        }
        $licenseLink = Join-Path $chocolateyLicenseFolder 'chocolatey.license.xml'
        if (-not (Test-Path $licenseLink)) {
            New-Item -ItemType SymbolicLink -Path $licenseLink -Target 'C:\Dropbox\Profile\chocolatey.license.xml' | Out-Null
        }
    }

    Import-ChocolateyModule

    # choco tab-completion via Chocolatey's own chocolateyProfile.psm1 (#278).
    # Importing that module registers choco's Register-ArgumentCompleter. There
    # is no `choco completion powershell` subcommand -- the completer ships with
    # Chocolatey itself. Import it for the current session and add an idempotent
    # import to the CurrentUserAllHosts profile so it loads in every host.
    # Best-effort.
    try {
        $chocoProfileModule = Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
        if (Test-Path $chocoProfileModule) {
            Import-Module $chocoProfileModule -ErrorAction Stop
            $allHostsProfile = $PROFILE.CurrentUserAllHosts
            if (-not (Test-Path $allHostsProfile)) {
                $profileDir = Split-Path -Parent $allHostsProfile
                if ($profileDir -and -not (Test-Path $profileDir)) {
                    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
                }
                New-Item -ItemType File -Path $allHostsProfile -Force | Out-Null
            }
            if (-not (Select-String -Path $allHostsProfile -Pattern 'Import-Module.*chocolateyProfile\.psm1' -Quiet)) {
                Add-Content -Path $allHostsProfile -Value 'Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"'
            }
        }
    } catch {
        Write-Warning "Skipping choco tab-completion activation: $($_.Exception.Message)"
    }
}
Install-Chocolatey
