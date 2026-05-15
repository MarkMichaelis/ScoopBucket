
Write-Host 'Installing and configuring PowerShell...'
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

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
Install-Module WinGet-Essentials -Repository PSGallery -Scope AllUsers
Install-Module Microsoft.PowerShell.ConsoleGuiTools -Repository PSGallery -Scope AllUsers
# PSCompletions powers the PSCompletions-backed tab completion for CLIs
# whose `<tool> completion` subcommand has no PowerShell output (bw,
# copilot, gcloud — see #73). Invoke-PackageInstall will also lazy-install
# this on first need, but having it baked into the PowerShell bundle
# means a freshly imaged box gets it before any individual CLI install
# is requested.
Install-PSCompletionsModule -Confirm:$false
choco install Pester

# Install Scott Hanselman's Windows Terminal Copilot CLI skill
# (sets tab title/color from inside Copilot CLI via !tab commands).
# Repo: https://github.com/shanselman/windows-terminal-copilot-skill
if (Get-Command git -ErrorAction Ignore) {
    $skillPath = Join-Path $env:USERPROFILE '.copilot\skills\windows-terminal'
    if (Test-Path (Join-Path $skillPath '.git')) {
        git -C $skillPath pull --quiet
    } else {
        New-Item -ItemType Directory -Path (Split-Path $skillPath -Parent) -Force | Out-Null
        git clone --quiet https://github.com/shanselman/windows-terminal-copilot-skill.git $skillPath
    }
    $importLine = 'Import-Module "$env:USERPROFILE\.copilot\skills\windows-terminal\WindowsTerminalSkill.psd1"'
    if (-not (Test-Path $PROFILE)) {
        New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    }
    if (-not (Select-String -Path $PROFILE -Pattern 'WindowsTerminalSkill\.psd1' -SimpleMatch -Quiet)) {
        Add-Content -Path $PROFILE -Value $importLine
    }
} else {
    Write-Warning 'git not found; skipping windows-terminal-copilot-skill install.'
}



