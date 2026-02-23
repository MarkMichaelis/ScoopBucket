#Requires -RunAsAdministrator
<#
.SYNOPSIS
    CI test harness that dynamically discovers and validates package installations.
.DESCRIPTION
    Parses all PS1 scripts in the bucket/ directory to discover package definitions,
    then attempts to install each package, reporting pass/fail/untested status.
    Results are written as JSON and as a GitHub Actions step summary.

    Supported discovery patterns:
    - Winget packages from hashtable blocks with WinGetID entries
    - Winget Microsoft Store packages (--source msstore) -> marked untested in CI
    - Chocolatey packages from piped arrays and standalone 'choco install' calls
    - Scoop packages from piped arrays
    - PowerShell modules from 'Install-Module' calls
    - Sideloaded apps (Add-AppxPackage) -> marked untested in CI

    Adding or removing a package in any bucket script automatically updates CI coverage.
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'  # Speed up web requests

# ============================================================================
# Results Tracking
# ============================================================================

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
        Name          = $Name
        PackageId     = $PackageId
        InstallerType = $InstallerType
        SourceScript  = $SourceScript
        Command       = $Command
        Status        = $Status
        ExitCode      = $ExitCode
        ErrorOutput   = $ErrorOutput
    })
    $icon = switch ($Status) { 'pass' { '✅' } 'fail' { '❌' } 'untested' { '⏭️' } }
    Write-Host "$icon [$InstallerType] $Name - $Status $(if ($ExitCode -ne 0) { "(exit $ExitCode)" })"
}

# ============================================================================
# Install Functions
# ============================================================================

function Install-WingetPackage {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$SourceScript,
        [string]$Scope = 'machine'
    )
    $cmd = "winget install --id $PackageId --scope $Scope --accept-package-agreements --accept-source-agreements --disable-interactivity --silent"
    try {
        Write-Host "  Installing [winget] $Name ($PackageId)..."
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
        [string]$SourceScript
    )
    $cmd = "choco install $Name -y --no-progress"
    try {
        Write-Host "  Installing [choco] $Name..."
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
        Write-Host "  Installing [scoop] $Name..."
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
    $cmd = "Install-Module $Name -Force -AllowClobber -Scope AllUsers $AdditionalArgs".Trim()
    try {
        Write-Host "  Installing [PS module] $Name..."
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
# Dynamic Package Discovery
# ============================================================================

function Find-HashTableBlocks {
    <#
    .SYNOPSIS
        Finds all $Variable = @{ ... } blocks in a script, handling nested braces.
    .OUTPUTS
        Array of objects with VarName, Content (inner text), and EndIndex.
    #>
    param([string]$Content)

    $blocks = @()
    $pattern = '\$(\w+)\s*=\s*@\{'
    $regexMatches = [regex]::Matches($Content, $pattern)

    foreach ($m in $regexMatches) {
        $varName = $m.Groups[1].Value
        $startIdx = $m.Index + $m.Length
        $depth = 1
        $i = $startIdx

        while ($i -lt $Content.Length -and $depth -gt 0) {
            $ch = $Content[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') { $depth-- }
            $i++
        }

        if ($depth -eq 0) {
            $blocks += [PSCustomObject]@{
                VarName  = $varName
                Content  = $Content.Substring($startIdx, $i - $startIdx - 1)
                EndIndex = $i
            }
        }
    }

    return $blocks
}

function Get-IterationInstaller {
    <#
    .SYNOPSIS
        Determines how a hashtable variable's values are consumed (winget, winget-store, choco, etc.)
    .OUTPUTS
        PSCustomObject with InstallerType and Scope properties.
    #>
    param(
        [string]$VarName,
        [string]$Content
    )

    # Look for $VarName.Values | ... or $VarName.VAlues | ... (case-insensitive)
    $iterPattern = "(?i)\`$$([regex]::Escape($VarName))\.\w+\s*\|"
    $iterMatch = [regex]::Match($Content, $iterPattern)

    if (-not $iterMatch.Success) {
        return [PSCustomObject]@{ InstallerType = 'unknown'; Scope = 'machine' }
    }

    # Get text after the pipe (up to 500 chars) to find the install command
    $maxLen = [Math]::Min(500, $Content.Length - $iterMatch.Index)
    $afterPipe = $Content.Substring($iterMatch.Index, $maxLen)

    $installerType = 'unknown'
    $scope = 'machine'

    # Match only the FIRST winget/choco/scoop install line (not subsequent blocks)
    if ($afterPipe -match '(?m)winget\s+install([^\r\n]*)') {
        $installLine = $Matches[1]
        if ($installLine -match '--source\s+msstore') {
            $installerType = 'winget-store'
        } else {
            $installerType = 'winget'
        }
        if ($installLine -match '--scope\s+(\w+)') {
            $scope = $Matches[1]
        }
    } elseif ($afterPipe -match 'choco\s+install') {
        $installerType = 'choco'
    } elseif ($afterPipe -match 'scoop\s+install') {
        $installerType = 'scoop'
    }

    return [PSCustomObject]@{ InstallerType = $installerType; Scope = $scope }
}

function Get-PackagesFromScript {
    <#
    .SYNOPSIS
        Parses a single PS1 script to discover all package install definitions.
    .DESCRIPTION
        Extracts packages from six patterns:
        1. Winget hashtable blocks (entries with WinGetID)
        2. Piped string arrays → choco/scoop install
        3. Standalone choco install commands
        4. Standalone winget install commands (literal IDs)
        5. Install-Module commands
        6. Add-AppxPackage (sideload) commands
    #>
    param([string]$FilePath)

    $content = Get-Content $FilePath -Raw
    $lines = Get-Content $FilePath
    $scriptName = Split-Path $FilePath -Leaf
    $packages = [System.Collections.ArrayList]::new()
    $foundPackageIds = @{}  # Track to avoid duplicate entries within a script

    # --- 1. Winget hashtable blocks (packages with WinGetID) ---
    $hashBlocks = Find-HashTableBlocks -Content $content

    foreach ($block in $hashBlocks) {
        # Only process blocks containing WinGetID
        if ($block.Content -notmatch 'WinGetID') { continue }

        $iteration = Get-IterationInstaller -VarName $block.VarName -Content $content

        foreach ($entryLine in ($block.Content -split "`n")) {
            $trimmed = $entryLine.Trim()
            if ($trimmed -match '^\s*#') { continue }  # Skip commented-out entries

            if ($trimmed -match "WingetName='([^']+)'") {
                $wingetName = $Matches[1]
            } else { continue }

            if ($trimmed -match "WinGetID='([^']+)'") {
                $wingetId = $Matches[1]
            } else { continue }

            $key = "$($iteration.InstallerType):$wingetId"
            if ($foundPackageIds.ContainsKey($key)) { continue }
            $foundPackageIds[$key] = $true

            $null = $packages.Add([PSCustomObject]@{
                Name           = $wingetName
                PackageId      = $wingetId
                InstallerType  = $iteration.InstallerType
                SourceScript   = $scriptName
                Scope          = $iteration.Scope
                AdditionalArgs = ''
            })
        }
    }

    # --- 2. Piped arrays: 'pkg1','pkg2' | ForEach-Object { choco/scoop install } ---
    $pipedPattern = "(?ms)('(?:[^']+)'(?:\s*,\s*'[^']+')*)\s*\|\s*ForEach-Object\s*\{[^}]*?(choco|scoop)\s+install"
    $pipedMatches = [regex]::Matches($content, $pipedPattern)

    foreach ($m in $pipedMatches) {
        $pkgString = $m.Groups[1].Value
        $installer = $m.Groups[2].Value

        $pkgNames = [regex]::Matches($pkgString, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }

        foreach ($name in $pkgNames) {
            $key = "$($installer):$name"
            if ($foundPackageIds.ContainsKey($key)) { continue }
            $foundPackageIds[$key] = $true

            $null = $packages.Add([PSCustomObject]@{
                Name           = $name
                PackageId      = $name
                InstallerType  = $installer
                SourceScript   = $scriptName
                Scope          = ''
                AdditionalArgs = ''
            })
        }
    }

    # --- 3. Standalone choco install (not inside ForEach-Object with $_) ---
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\s*#') { continue }        # Skip comments
        if ($trimmed -match '\$_') { continue }           # Skip ForEach-Object body lines
        if ($trimmed -match '^\s*choco\s+install\s+(\w[\w.-]+)') {
            $pkgName = $Matches[1]
            $key = "choco:$pkgName"
            if ($foundPackageIds.ContainsKey($key)) { continue }
            $foundPackageIds[$key] = $true

            $null = $packages.Add([PSCustomObject]@{
                Name           = $pkgName
                PackageId      = $pkgName
                InstallerType  = 'choco'
                SourceScript   = $scriptName
                Scope          = ''
                AdditionalArgs = ''
            })
        }
    }

    # --- 4. Standalone winget install (literal Package.Id, not $_ references) ---
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\s*#') { continue }
        if ($trimmed -match '\$_') { continue }
        if ($trimmed -match '^\s*[Ww]inget\s+install\b(.*)') {
            $argsPart = $Matches[1]
            # Match a package ID pattern: Org.Package (must contain at least one dot)
            if ($argsPart -match '(?:--id\s+)?([A-Za-z][\w-]*\.[\w.-]+)') {
                $pkgId = $Matches[1]
                if ($pkgId -match '^--') { continue }  # Skip flags
                $key = "winget:$pkgId"
                if ($foundPackageIds.ContainsKey($key)) { continue }
                $foundPackageIds[$key] = $true

                $scope = 'machine'
                if ($argsPart -match '--scope\s+(\w+)') { $scope = $Matches[1] }

                $null = $packages.Add([PSCustomObject]@{
                    Name           = $pkgId
                    PackageId      = $pkgId
                    InstallerType  = 'winget'
                    SourceScript   = $scriptName
                    Scope          = $scope
                    AdditionalArgs = ''
                })
            }
        }
    }

    # --- 5. Install-Module commands ---
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\s*#') { continue }
        if ($trimmed -match '^\s*[Ii]nstall-[Mm]odule\s+(\w[\w.-]+)(.*)') {
            $modName = $Matches[1]
            $restArgs = $Matches[2]
            $key = "ps-module:$modName"
            if ($foundPackageIds.ContainsKey($key)) { continue }
            $foundPackageIds[$key] = $true

            # Preserve flags not already added by Install-PSModule (-Force -AllowClobber -Scope AllUsers)
            $additionalArgs = ''
            if ($restArgs -match '-AllowPrerelease') { $additionalArgs += ' -AllowPrerelease' }
            if ($restArgs -match '-Repository\s+(\S+)') { $additionalArgs += " -Repository $($Matches[1])" }

            $null = $packages.Add([PSCustomObject]@{
                Name           = $modName
                PackageId      = $modName
                InstallerType  = 'ps-module'
                SourceScript   = $scriptName
                Scope          = ''
                AdditionalArgs = $additionalArgs.Trim()
            })
        }
    }

    # --- 6. Sideload (Add-AppxPackage) ---
    $addAppxIdx = $content.IndexOf('Add-AppxPackage')
    if ($addAppxIdx -ge 0) {
        # Search backward from Add-AppxPackage for the nearest Write-Host "Installing ..."
        $lookBack = [Math]::Max(0, $addAppxIdx - 500)
        $beforeText = $content.Substring($lookBack, $addAppxIdx - $lookBack)
        $nameMatches = [regex]::Matches($beforeText, "Write-Host\s+[`"']Installing\s+([^.`"']+)")
        $appName = if ($nameMatches.Count -gt 0) {
            $nameMatches[$nameMatches.Count - 1].Groups[1].Value.Trim()
        } else { 'Unknown MSIX App' }

        # Extract download URL from nearby Invoke-WebRequest
        $nearbyText = $content.Substring([Math]::Max(0, $addAppxIdx - 300), [Math]::Min(600, $content.Length - [Math]::Max(0, $addAppxIdx - 300)))
        $urlPattern = "Invoke-WebRequest\s+-Uri\s+'([^']+)'"
        $urlMatch = [regex]::Match($nearbyText, $urlPattern)
        $appUrl = if ($urlMatch.Success) { $urlMatch.Groups[1].Value } else { 'unknown' }

        $key = "sideload:$appName"
        if (-not $foundPackageIds.ContainsKey($key)) {
            $foundPackageIds[$key] = $true
            $null = $packages.Add([PSCustomObject]@{
                Name           = $appName
                PackageId      = $appUrl
                InstallerType  = 'sideload'
                SourceScript   = $scriptName
                Scope          = ''
                AdditionalArgs = ''
            })
        }
    }

    return $packages.ToArray()
}

function Get-AllPackages {
    <#
    .SYNOPSIS
        Scans all PS1 scripts in the bucket directory and returns discovered packages.
    .DESCRIPTION
        Excludes Utils.ps1 (shared helpers) and *.Tests.ps1 (test files).
    #>
    param([string]$BucketPath)

    $allPackages = [System.Collections.ArrayList]::new()
    $scriptFiles = Get-ChildItem (Join-Path $BucketPath '*') -Include '*.ps1' -Exclude 'Utils.ps1', '*.Tests.ps1'

    foreach ($file in $scriptFiles) {
        Write-Host "  Scanning $($file.Name)..." -ForegroundColor DarkGray
        $pkgs = Get-PackagesFromScript -FilePath $file.FullName
        if (@($pkgs).Count -gt 0) {
            Write-Host "    Found $(@($pkgs).Count) package(s)" -ForegroundColor DarkGray
        }
        foreach ($pkg in $pkgs) {
            $null = $allPackages.Add($pkg)
        }
    }

    return $allPackages.ToArray()
}

# ============================================================================
# Main Execution
# ============================================================================

$repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } `
            else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$bucketPath = Join-Path $repoRoot 'bucket'

if (-not (Test-Path $bucketPath)) {
    Write-Error "Bucket directory not found at: $bucketPath"
    exit 1
}

# Set up PSGallery as trusted (needed for PS module installs)
Write-Host "`n========== Setting up PSGallery ==========" -ForegroundColor Cyan
if ((Get-PSRepository PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

# Discover packages
Write-Host "`n========== Discovering Packages ==========" -ForegroundColor Cyan
$packages = Get-AllPackages -BucketPath $bucketPath

$packageCount = $packages.Count
$scriptCount = ($packages | Select-Object -ExpandProperty SourceScript -Unique).Count
$installerGroups = $packages | Group-Object InstallerType | ForEach-Object { "$($_.Count) $($_.Name)" }

Write-Host "`nDiscovered $packageCount package(s) across $scriptCount script(s):" -ForegroundColor Green
Write-Host "  $($installerGroups -join ', ')" -ForegroundColor Green

# Display discovered packages for debugging
Write-Host "`n--- Discovered Package List ---" -ForegroundColor DarkGray
foreach ($pkg in $packages) {
    Write-Host "  [$($pkg.InstallerType)] $($pkg.Name) ($($pkg.PackageId)) <- $($pkg.SourceScript)" -ForegroundColor DarkGray
}
Write-Host "--- End Package List ---`n" -ForegroundColor DarkGray

# Execute installs grouped by source script
$grouped = $packages | Group-Object SourceScript | Sort-Object Name

foreach ($group in $grouped) {
    Write-Host "`n========== $($group.Name) ==========" -ForegroundColor Cyan

    foreach ($pkg in $group.Group) {
        switch ($pkg.InstallerType) {
            'winget' {
                Install-WingetPackage -Name $pkg.Name -PackageId $pkg.PackageId `
                    -SourceScript $pkg.SourceScript -Scope $pkg.Scope
            }
            'winget-store' {
                Skip-Package -Name $pkg.Name -PackageId $pkg.PackageId `
                    -InstallerType 'winget-store' -SourceScript $pkg.SourceScript `
                    -Reason 'Microsoft Store auth unavailable in CI'
            }
            'choco' {
                Install-ChocoPackage -Name $pkg.Name -SourceScript $pkg.SourceScript
            }
            'scoop' {
                Install-ScoopPackage -Name $pkg.Name -SourceScript $pkg.SourceScript
            }
            'ps-module' {
                Install-PSModule -Name $pkg.Name -SourceScript $pkg.SourceScript `
                    -AdditionalArgs $pkg.AdditionalArgs
            }
            'sideload' {
                Skip-Package -Name $pkg.Name -PackageId $pkg.PackageId `
                    -InstallerType 'sideload' -SourceScript $pkg.SourceScript `
                    -Reason 'MSIX sideload not reliable in CI'
            }
            default {
                Write-Warning "Unknown installer type '$($pkg.InstallerType)' for $($pkg.Name) in $($pkg.SourceScript)"
            }
        }
    }
}

# ============================================================================
# Results Summary
# ============================================================================

Write-Host "`n========== RESULTS SUMMARY ==========" -ForegroundColor Cyan

$passed   = @($script:Results | Where-Object Status -eq 'pass').Count
$failed   = @($script:Results | Where-Object Status -eq 'fail').Count
$untested = @($script:Results | Where-Object Status -eq 'untested').Count
$total    = $script:Results.Count

Write-Host "Total: $total | Passed: $passed | Failed: $failed | Untested: $untested"

# Write JSON results file
$resultsPath = Join-Path (if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { $repoRoot }) 'test-results.json'
$script:Results | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8
Write-Host "Results written to: $resultsPath"

# Set output for downstream steps
if ($env:GITHUB_OUTPUT) {
    "has_failures=$($failed -gt 0 ? 'true' : 'false')" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}

# Write GitHub Actions step summary
if ($env:GITHUB_STEP_SUMMARY) {
    $summary = @"
# Package Install Validation Results

> Packages were **dynamically discovered** from bucket scripts - no hardcoded list.

| Status | Count |
|--------|-------|
| Passed | $passed |
| Failed | $failed |
| Untested | $untested |
| **Total** | **$total** |

## Detailed Results

| Status | Package | Installer | Source Script | Exit Code |
|--------|---------|-----------|---------------|-----------|
"@
    foreach ($r in ($script:Results | Sort-Object Status, Name)) {
        $icon = switch ($r.Status) { 'pass' { 'PASS' } 'fail' { 'FAIL' } 'untested' { 'SKIP' } }
        $summary += "`n| $icon | $($r.Name) | $($r.InstallerType) | $($r.SourceScript) | $($r.ExitCode) |"
    }

    if ($failed -gt 0) {
        $summary += "`n`n## Failure Details`n"
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
    Write-Host "`n$failed package(s) failed to install." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll testable packages installed successfully." -ForegroundColor Green
    exit 0
}
