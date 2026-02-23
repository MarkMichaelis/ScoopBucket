#Requires -RunAsAdministrator
<#
.SYNOPSIS
    CI test harness that validates package installations defined in the Scoop bucket.
.DESCRIPTION
    Iterates through all packages defined across the repository's install scripts,
    attempts to install each one, and reports pass/fail/untested status.
    Outputs results as JSON and writes a GitHub Actions step summary.
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'  # Speed up Invoke-WebRequest etc.

# Results collector
$script:Results = [System.Collections.ArrayList]::new()

function Add-Result {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$InstallerType,
        [string]$SourceScript,
        [string]$Command,
        [ValidateSet('pass','fail','untested')]
        [string]$Status,
        [int]$ExitCode = 0,
        [string]$ErrorOutput = ''
    )
    $null = $script:Results.Add([PSCustomObject]@{
        Name         = $Name
        PackageId    = $PackageId
        InstallerType = $InstallerType
        SourceScript = $SourceScript
        Command      = $Command
        Status       = $Status
        ExitCode     = $ExitCode
        ErrorOutput  = $ErrorOutput
    })
    $icon = switch ($Status) { 'pass' { '✅' } 'fail' { '❌' } 'untested' { '⏭️' } }
    Write-Host "$icon [$InstallerType] $Name — $Status $(if ($ExitCode -ne 0) { "(exit $ExitCode)" })"
}

function Install-WingetPackage {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$SourceScript,
        [string]$Scope = 'machine'
    )
    $cmd = "winget install --id $PackageId --scope $Scope --accept-package-agreements --accept-source-agreements --disable-interactivity --silent"
    try {
        Write-Host "Installing [winget] $Name ($PackageId)..."
        $output = cmd /c "$cmd 2>&1"
        $code = $LASTEXITCODE
        # winget exit code 0 = success, -1978335189 (0x8A150057) = already installed
        if ($code -eq 0 -or $code -eq -1978335189) {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'winget' `
                -SourceScript $SourceScript -Command $cmd -Status 'pass'
        } else {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'winget' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput ($output | Out-String)
        }
    } catch {
        Add-Result -Name $Name -PackageId $PackageId -InstallerType 'winget' `
            -SourceScript $SourceScript -Command $cmd -Status 'fail' `
            -ExitCode -1 -ErrorOutput $_.Exception.Message
    }
}

function Install-ChocoPackage {
    param(
        [string]$Name,
        [string]$SourceScript,
        [string]$AdditionalArgs = ''
    )
    $cmd = "choco install $Name -y --no-progress $AdditionalArgs"
    try {
        Write-Host "Installing [choco] $Name..."
        $output = cmd /c "$cmd 2>&1"
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Add-Result -Name $Name -PackageId $Name -InstallerType 'choco' `
                -SourceScript $SourceScript -Command $cmd -Status 'pass'
        } else {
            Add-Result -Name $Name -PackageId $Name -InstallerType 'choco' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput ($output | Out-String)
        }
    } catch {
        Add-Result -Name $Name -PackageId $Name -InstallerType 'choco' `
            -SourceScript $SourceScript -Command $cmd -Status 'fail' `
            -ExitCode -1 -ErrorOutput $_.Exception.Message
    }
}

function Install-ScoopPackage {
    param(
        [string]$Name,
        [string]$SourceScript
    )
    $cmd = "scoop install -g $Name"
    try {
        Write-Host "Installing [scoop] $Name..."
        $output = cmd /c "$cmd 2>&1"
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Add-Result -Name $Name -PackageId $Name -InstallerType 'scoop' `
                -SourceScript $SourceScript -Command $cmd -Status 'pass'
        } else {
            Add-Result -Name $Name -PackageId $Name -InstallerType 'scoop' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput ($output | Out-String)
        }
    } catch {
        Add-Result -Name $Name -PackageId $Name -InstallerType 'scoop' `
            -SourceScript $SourceScript -Command $cmd -Status 'fail' `
            -ExitCode -1 -ErrorOutput $_.Exception.Message
    }
}

function Install-PSModule {
    param(
        [string]$Name,
        [string]$SourceScript,
        [string]$AdditionalArgs = ''
    )
    $cmd = "Install-Module $Name -Force -AllowClobber -Scope AllUsers $AdditionalArgs"
    try {
        Write-Host "Installing [PS module] $Name..."
        Invoke-Expression $cmd
        Add-Result -Name $Name -PackageId $Name -InstallerType 'ps-module' `
            -SourceScript $SourceScript -Command $cmd -Status 'pass'
    } catch {
        Add-Result -Name $Name -PackageId $Name -InstallerType 'ps-module' `
            -SourceScript $SourceScript -Command $cmd -Status 'fail' `
            -ExitCode -1 -ErrorOutput $_.Exception.Message
    }
}

function Skip-Package {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$InstallerType,
        [string]$SourceScript,
        [string]$Reason = 'Not available in CI environment'
    )
    Add-Result -Name $Name -PackageId $PackageId -InstallerType $InstallerType `
        -SourceScript $SourceScript -Command "SKIPPED: $Reason" -Status 'untested'
}

# ============================================================================
# Set up PSGallery as trusted (needed for PS module installs)
# ============================================================================
Write-Host "`n========== Setting up PSGallery ==========" -ForegroundColor Cyan
if ((Get-PSRepository PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

# ============================================================================
# OSBasePackages — winget
# ============================================================================
Write-Host "`n========== OSBasePackages (winget) ==========" -ForegroundColor Cyan

$OSBaseWinget = @(
    @{ Name='Windows Terminal';    Id='Microsoft.WindowsTerminal' }
    @{ Name='7-Zip';              Id='7Zip.7Zip' }
    @{ Name='Everything';         Id='voidtools.Everything' }
    @{ Name='Everything Cli';     Id='voidtools.Everything.Cli' }
    @{ Name='Google Chrome';      Id='Google.Chrome' }
    @{ Name='Process Explorer';   Id='Microsoft.Sysinternals.ProcessExplorer' }
    @{ Name='SysInternals';       Id='Microsoft.SysInternals' }
    @{ Name='WinDirStat';         Id='WinDirStat.WinDirStat' }
    @{ Name='USSF';               Id='WindowsPostInstallWizard.UniversalSilentSwitchFinder' }
    @{ Name='bat';                Id='sharkdp.bat' }
    @{ Name='Ripgrep';            Id='BurntSushi.ripgrep.MSVC' }
    @{ Name='fzf';                Id='junegunn.fzf' }
    @{ Name='FFmpeg';             Id='Gyan.FFmpeg' }
)
foreach ($pkg in $OSBaseWinget) {
    Install-WingetPackage -Name $pkg.Name -PackageId $pkg.Id -SourceScript 'OSBasePackages.ps1'
}

# ============================================================================
# ClientBasePackages — choco
# ============================================================================
Write-Host "`n========== ClientBasePackages (choco) ==========" -ForegroundColor Cyan

$ClientBaseChoco = @('foxitreader', 'exiftool', 'dbxcli', 'geosetter')
foreach ($pkg in $ClientBaseChoco) {
    Install-ChocoPackage -Name $pkg -SourceScript 'ClientBasePackages.ps1'
}

# ============================================================================
# ClientBasePackages — winget
# ============================================================================
Write-Host "`n========== ClientBasePackages (winget) ==========" -ForegroundColor Cyan

$ClientBaseWinget = @(
    @{ Name='Amazon Kindle';  Id='Amazon.Kindle' }
    @{ Name='calibre';        Id='calibre.calibre' }
    @{ Name='Claude';         Id='Anthropic.Claude' }
    @{ Name='SoX';            Id='ChrisBagwell.SoX' }
    @{ Name='eSpeak NG';      Id='eSpeak-NG.eSpeak-NG' }
    @{ Name='Dropbox';        Id='Dropbox.Dropbox' }
    @{ Name='Notion';         Id='Notion.Notion' }
    @{ Name='Pushbullet';     Id='Pushbullet.Pushbullet' }
    @{ Name='Signal';         Id='OpenWhisperSystems.Signal' }
    @{ Name='Snagit';         Id='TechSmith.Snagit.2024' }
    @{ Name='Spotify';        Id='Spotify.Spotify' }
    @{ Name='Todoist';        Id='Doist.Todoist' }
    @{ Name='Zoom';           Id='Zoom.Zoom.EXE' }
)
foreach ($pkg in $ClientBaseWinget) {
    Install-WingetPackage -Name $pkg.Name -PackageId $pkg.Id -SourceScript 'ClientBasePackages.ps1'
}

# ============================================================================
# ClientBasePackages — Microsoft Store (UNTESTED in CI)
# ============================================================================
Write-Host "`n========== ClientBasePackages (msstore — skipped) ==========" -ForegroundColor Cyan

$ClientBaseMSStore = @(
    @{ Name='ChatGPT';        Id='9NT1R1C2HH7J' }
    @{ Name='VPN Unlimited';  Id='9NRQBLR605RG' }
    @{ Name='Grammarly';      Id='XPDDXX9QW8N9D7' }
    @{ Name='WhatsApp';       Id='9NKSQGP7F2NH' }
)
foreach ($pkg in $ClientBaseMSStore) {
    Skip-Package -Name $pkg.Name -PackageId $pkg.Id -InstallerType 'winget-store' `
        -SourceScript 'ClientBasePackages.ps1' -Reason 'Microsoft Store auth unavailable in CI'
}

# ============================================================================
# ClientBasePackages — Sideload (UNTESTED in CI)
# ============================================================================
Write-Host "`n========== ClientBasePackages (sideload — skipped) ==========" -ForegroundColor Cyan

Skip-Package -Name 'Readwise Reader' -PackageId 'readwise.io/msix' -InstallerType 'sideload' `
    -SourceScript 'ClientBasePackages.ps1' -Reason 'MSIX sideload not reliable in CI'

# ============================================================================
# DeveloperBasePackages — choco
# ============================================================================
Write-Host "`n========== DeveloperBasePackages (choco) ==========" -ForegroundColor Cyan

Install-ChocoPackage -Name 'nodejs' -SourceScript 'DeveloperBasePackages.ps1'

# ============================================================================
# DeveloperBasePackages — scoop
# ============================================================================
Write-Host "`n========== DeveloperBasePackages (scoop) ==========" -ForegroundColor Cyan

$DevBaseScoop = @('dotnet', 'VisualStudio2026Enterprise')
foreach ($pkg in $DevBaseScoop) {
    Install-ScoopPackage -Name $pkg -SourceScript 'DeveloperBasePackages.ps1'
}

# ============================================================================
# DeveloperBasePackages — winget
# ============================================================================
Write-Host "`n========== DeveloperBasePackages (winget) ==========" -ForegroundColor Cyan

$DevBaseWinget = @(
    @{ Name='Visual Studio Code'; Id='Microsoft.VisualStudioCode' }
    @{ Name='Copilot CLI';        Id='GitHub.Copilot' }
    @{ Name='Python';             Id='Python.Python.3.14' }
    @{ Name='Beyond Compare';     Id='ScooterSoftware.BeyondCompare.4' }
)
foreach ($pkg in $DevBaseWinget) {
    Install-WingetPackage -Name $pkg.Name -PackageId $pkg.Id -SourceScript 'DeveloperBasePackages.ps1'
}

# ============================================================================
# GitConfigure — choco
# ============================================================================
Write-Host "`n========== GitConfigure (choco) ==========" -ForegroundColor Cyan

$GitConfigChoco = @('git', 'git-credential-manager-for-windows', 'gitextensions', 'gitkraken')
foreach ($pkg in $GitConfigChoco) {
    Install-ChocoPackage -Name $pkg -SourceScript 'GitConfigure.ps1'
}

# ============================================================================
# GitConfigure — winget
# ============================================================================
Write-Host "`n========== GitConfigure (winget) ==========" -ForegroundColor Cyan

$GitConfigWinget = @(
    @{ Name='GitKraken CLI'; Id='GitKraken.cli' }
    @{ Name='GitHub CLI';    Id='GitHub.cli' }
)
foreach ($pkg in $GitConfigWinget) {
    Install-WingetPackage -Name $pkg.Name -PackageId $pkg.Id -SourceScript 'GitConfigure.ps1'
}

# ============================================================================
# MicrosoftOffice365 — choco
# ============================================================================
Write-Host "`n========== MicrosoftOffice365 (choco) ==========" -ForegroundColor Cyan

$Office365Choco = @('Office365ProPlus', 'Microsoft-Teams')
foreach ($pkg in $Office365Choco) {
    Install-ChocoPackage -Name $pkg -SourceScript 'MicrosoftOffice365.ps1'
}

# ============================================================================
# Chocolatey — choco
# ============================================================================
Write-Host "`n========== Chocolatey extensions (choco) ==========" -ForegroundColor Cyan

$ChocoExtensions = @('chocolatey-core.extension', 'au')
foreach ($pkg in $ChocoExtensions) {
    Install-ChocoPackage -Name $pkg -SourceScript 'Chocolatey.ps1'
}

# ============================================================================
# PowerShell — modules
# ============================================================================
Write-Host "`n========== PowerShell modules ==========" -ForegroundColor Cyan

$PSModules = @(
    @{ Name='PowershellGet';    Args='-Repository PSGallery' }
    @{ Name='Pscx';             Args='-AllowClobber -AllowPrerelease' }
    @{ Name='ZLocation';        Args='-Repository PSGallery' }
    @{ Name='PSReadLine';       Args='' }
    @{ Name='Microsoft.PowerShell.SecretManagement'; Args='' }
    @{ Name='posh-git';         Args='' }
)
foreach ($mod in $PSModules) {
    Install-PSModule -Name $mod.Name -SourceScript 'PowerShell.ps1' -AdditionalArgs $mod.Args
}

# ============================================================================
# PowerShell — Pester via choco
# ============================================================================
Write-Host "`n========== Pester (choco) ==========" -ForegroundColor Cyan
Install-ChocoPackage -Name 'Pester' -SourceScript 'PowerShell.ps1'

# ============================================================================
# Results Summary
# ============================================================================
Write-Host "`n========== RESULTS SUMMARY ==========" -ForegroundColor Cyan

$passed   = ($script:Results | Where-Object Status -eq 'pass').Count
$failed   = ($script:Results | Where-Object Status -eq 'fail').Count
$untested = ($script:Results | Where-Object Status -eq 'untested').Count
$total    = $script:Results.Count

Write-Host "Total: $total | Passed: $passed | Failed: $failed | Untested: $untested"

# Write JSON results file
$resultsPath = Join-Path $env:GITHUB_WORKSPACE 'test-results.json'
$script:Results | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8
Write-Host "Results written to: $resultsPath"

# Set output for downstream steps
if ($env:GITHUB_OUTPUT) {
    "has_failures=$($failed -gt 0 ? 'true' : 'false')" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}

# Write GitHub Actions step summary
if ($env:GITHUB_STEP_SUMMARY) {
    $summary = @"
# 📦 Package Install Validation Results

| Status | Count |
|--------|-------|
| ✅ Passed | $passed |
| ❌ Failed | $failed |
| ⏭️ Untested | $untested |
| **Total** | **$total** |

## Detailed Results

| Status | Package | Installer | Source Script | Exit Code |
|--------|---------|-----------|---------------|-----------|
"@
    foreach ($r in ($script:Results | Sort-Object Status, Name)) {
        $icon = switch ($r.Status) { 'pass' { '✅' } 'fail' { '❌' } 'untested' { '⏭️' } }
        $summary += "`n| $icon | $($r.Name) | $($r.InstallerType) | $($r.SourceScript) | $($r.ExitCode) |"
    }

    if ($failed -gt 0) {
        $summary += "`n`n## ❌ Failure Details`n"
        foreach ($r in ($script:Results | Where-Object Status -eq 'fail')) {
            $errorSnippet = if ($r.ErrorOutput.Length -gt 500) { $r.ErrorOutput.Substring(0, 500) + '...' } else { $r.ErrorOutput }
            $summary += @"

### $($r.Name) ($($r.InstallerType))
- **ID:** $($r.PackageId)
- **Command:** ``$($r.Command)``
- **Exit Code:** $($r.ExitCode)
- **Error:**
``````
$errorSnippet
``````

"@
        }
    }

    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding UTF8
}

# Exit with failure if any packages failed
if ($failed -gt 0) {
    Write-Host "`n❌ $failed package(s) failed to install." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n✅ All testable packages installed successfully." -ForegroundColor Green
    exit 0
}
