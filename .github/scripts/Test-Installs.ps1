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
# CI Skip List — packages that cannot install on a headless Windows Server
# ============================================================================
# Key = PackageId (winget) or package name (choco).  These are marked 'untested'
# instead of 'fail' so the build stays green while still documenting coverage gaps.
#
# Reasons a package ends up here:
#   - winget "No applicable installer found" — only user-scope MSIX/APPX available
#   - Chocolatey package delisted / no longer in the community repo
#   - Requires GUI session, license activation, or interactive prompts

$script:CISkipPackages = @{
    # winget: user-scope-only MSIX apps (no machine-scope MSI/EXE installer)
    'Pushbullet.Pushbullet'         = 'User-scope MSIX only — no machine installer; no msstore/scoop/choco alternative (#8)'
    # choco: delisted or CI-incompatible
    'Office365ProPlus'              = 'Requires GUI session and license activation (exit 17004)'
    # scoop: browser-watch installers requiring interactive Download click
    'MarkMichaelis/Gemini'          = 'Browser-watch installer requires interactive Download click; see #25, #26'
}

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
    # Surface captured installer stdout/stderr for failures so post-mortem
    # doesn't require a special re-run to learn the real cause.  Wrapped in a
    # GitHub Actions log group so the workflow log stays readable.
    if ($Status -eq 'fail' -and -not [string]::IsNullOrWhiteSpace($ErrorOutput)) {
        # Format the exit code as unsigned hex.  Cannot use ([uint32]($ExitCode -band 0xFFFFFFFF))
        # because PowerShell's 0xFFFFFFFF literal is int (-1), so -band preserves the
        # signed value and the [uint32] cast then fails on any negative exit code (e.g.
        # winget's -1978335184).  BitConverter reinterprets the int32 bit pattern as uint32.
        # Wrapped in try/catch so a formatting bug here can never abort the install loop
        # (which is exactly what bit us before the fix).
        try {
            $hex = '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$ExitCode), 0)
        } catch {
            $hex = "(hex-format-failed: $($_.Exception.Message))"
        }
        Write-Host "::group::[$InstallerType] $Name failure output (exit $ExitCode / $hex)"
        Write-Host $ErrorOutput
        Write-Host "::endgroup::"
    }
}

# ============================================================================
# Install Functions
# ============================================================================

# Per-package timeout (seconds) to prevent one hung install from consuming the
# entire CI budget.  Scoop gets a longer window because Visual Studio installs
# are legitimately large.
$script:DefaultTimeoutSec  = 900   # 15 minutes — winget / choco / ps-module
$script:ScoopTimeoutSec    = 2400  # 40 minutes — scoop (covers VS installs)

function Invoke-WithTimeout {
    <#
    .SYNOPSIS
        Runs an external command with a timeout.  Returns a hashtable with
        ExitCode, Output, and TimedOut.
    #>
    param(
        [string]$Command,
        [int]$TimeoutSeconds = $script:DefaultTimeoutSec
    )
    $stdOutFile = [System.IO.Path]::GetTempFileName()
    $stdErrFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process cmd -ArgumentList "/c $Command" `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdOutFile `
            -RedirectStandardError  $stdErrFile
        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            # Kill the process tree
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            $partialOut = if (Test-Path $stdOutFile) { Get-Content $stdOutFile -Raw } else { '' }
            return @{ ExitCode = -1; Output = "$partialOut`n[TIMEOUT after ${TimeoutSeconds}s]"; TimedOut = $true }
        }
        $out = if (Test-Path $stdOutFile) { Get-Content $stdOutFile -Raw } else { '' }
        $err = if (Test-Path $stdErrFile) { Get-Content $stdErrFile -Raw } else { '' }
        return @{ ExitCode = $proc.ExitCode; Output = "$out`n$err".Trim(); TimedOut = $false }
    } finally {
        Remove-Item $stdOutFile, $stdErrFile -ErrorAction SilentlyContinue
    }
}

function Test-IsTransientWingetFailure {
    <#
    .SYNOPSIS
        Classifies winget install failures as transient (retryable) or not.
    .DESCRIPTION
        Recognises HTTP 502 / "Bad gateway" download failures (hresult
        0x801901F6 / -2145844746) and similar CDN-side hiccups that recover
        on retry.  Add other known transient codes here as we encounter them.
    #>
    param(
        [int]$ExitCode,
        [string]$Output
    )
    # 0x801901F6 = -2145844746 (HTTP 502 Bad gateway during download)
    $transientCodes = @(-2145844746)
    if ($transientCodes -contains $ExitCode) { return $true }
    if ($Output -match '0x801901f6|Bad gateway|Download request status is not success') { return $true }
    return $false
}

function Install-WingetPackage {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$SourceScript,
        [string]$Scope = 'machine'
    )
    # winget only accepts 'user' or 'machine' for --scope. The declarative
    # schema uses 'global' (the new default) as a synonym for machine-wide;
    # map both 'global' and the legacy 'machine' to winget's 'machine'.
    # Anything not 'user' falls back to 'machine'.
    $effectiveScope = if ($Scope -eq 'user') { 'user' } else { 'machine' }
    $cmd = "winget install --id $PackageId --scope $effectiveScope --accept-package-agreements --accept-source-agreements --disable-interactivity --silent"
    try {
        Write-Host "  Installing [winget] $Name ($PackageId)..."
        $maxAttempts = 3
        $result = $null
        $code = 0
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $result = Invoke-WithTimeout -Command $cmd -TimeoutSeconds $script:DefaultTimeoutSec
            $code = $result.ExitCode
            # Timeouts are NOT transient — fail fast.
            if ($result.TimedOut) { break }
            # winget exit code 0 = success, -1978335189 (0x8A150057) = already installed
            if ($code -eq 0 -or $code -eq -1978335189) { break }
            if ($attempt -lt $maxAttempts -and (Test-IsTransientWingetFailure -ExitCode $code -Output $result.Output)) {
                $delay = [int](10 * [Math]::Pow(3, $attempt - 1))
                Write-Host "  Retry $attempt/$maxAttempts for [winget] $Name (transient: exit $code); sleeping ${delay}s..."
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }
        if ($result.TimedOut) {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'winget' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput $result.Output
        }
        elseif ($code -eq 0 -or $code -eq -1978335189) {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'winget' `
                -SourceScript $SourceScript -Command $cmd -Status 'pass'
        } else {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'winget' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput $result.Output
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
        [string]$PackageId,
        [string]$SourceScript
    )
    if (-not $PackageId) { $PackageId = $Name }
    $cmd = "choco install $PackageId -y --no-progress"
    try {
        Write-Host "  Installing [choco] $Name..."
        $result = Invoke-WithTimeout -Command $cmd -TimeoutSeconds $script:DefaultTimeoutSec
        $code = $result.ExitCode
        if ($result.TimedOut) {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'choco' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput $result.Output
        } elseif ($code -eq 0) {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'choco' `
                -SourceScript $SourceScript -Command $cmd -Status 'pass'
        } else {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'choco' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput $result.Output
        }
    } catch {
        Add-Result -Name $Name -PackageId $PackageId -InstallerType 'choco' `
            -SourceScript $SourceScript -Command $cmd -Status 'fail' `
            -ExitCode -1 -ErrorOutput $_.Exception.Message
    }
}

function Install-ScoopPackage {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$SourceScript
    )
    if (-not $PackageId) { $PackageId = $Name }
    $cmd = "scoop install -g $PackageId"
    try {
        Write-Host "  Installing [scoop] $Name..."
        $result = Invoke-WithTimeout -Command $cmd -TimeoutSeconds $script:ScoopTimeoutSec
        $code = $result.ExitCode
        if ($result.TimedOut) {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'scoop' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput $result.Output
        } elseif ($code -eq 0) {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'scoop' `
                -SourceScript $SourceScript -Command $cmd -Status 'pass'
        } else {
            Add-Result -Name $Name -PackageId $PackageId -InstallerType 'scoop' `
                -SourceScript $SourceScript -Command $cmd -Status 'fail' `
                -ExitCode $code -ErrorOutput $result.Output
        }
    } catch {
        Add-Result -Name $Name -PackageId $PackageId -InstallerType 'scoop' `
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

    # --- 4b. Standalone scoop install (e.g. `scoop install ffmpeg`,
    #         `scoop install extras/sysinternals`).  Bare-positional, NOT
    #         inside a `... | ForEach-Object` pipeline (handled by --- 2 ---).
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\s*#') { continue }
        if ($trimmed -match '\$_') { continue }
        if ($trimmed -match '^\s*scoop\s+install\s+(?:-g\s+)?([A-Za-z0-9][\w\-/.]*)\s*$') {
            $pkgName = $Matches[1]
            $key = "scoop:$pkgName"
            if ($foundPackageIds.ContainsKey($key)) { continue }
            $foundPackageIds[$key] = $true

            $null = $packages.Add([PSCustomObject]@{
                Name           = $pkgName
                PackageId      = $pkgName
                InstallerType  = 'scoop'
                SourceScript   = $scriptName
                Scope          = ''
                AdditionalArgs = ''
            })
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
        Source 0: declarative [Package] arrays via the MarkMichaelis.ScoopBucket module.
        Source 1: text-parsing legacy bundles that have not yet been migrated.
        Excludes Utils.ps1 (shared helpers) and *.Tests.ps1 (test files).
    #>
    param([string]$BucketPath)

    $allPackages = [System.Collections.ArrayList]::new()
    $declarativeBundles = @{}

    # --- Source 0: declarative bundles via Get-Package -----------------------
    try {
        $modulePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $modulePath) {
            Import-Module $modulePath -Force -ErrorAction Stop
            foreach ($p in (Get-Package -BucketPath $BucketPath -ErrorAction Stop)) {
                $declarativeBundles[$p.Bundle] = $true
                $installerType = switch ($p.Installer) {
                    'winget'     { if ($p.Source -eq 'msstore') { 'winget-store' } else { 'winget' } }
                    'scoop'      { 'scoop' }
                    'choco'      { 'choco' }
                    'npmGlobal'  { 'npm' }
                    'dotnetTool' { 'dotnetTool' }
                    'custom'     { 'custom' }
                    default      { $p.Installer }
                }
                $null = $allPackages.Add([pscustomobject]@{
                    Name           = $p.Name
                    PackageId      = $p.Id
                    InstallerType  = $installerType
                    Scope          = if ($p.Scope) { $p.Scope } else { 'machine' }
                    SourceScript   = "$($p.Bundle).ps1"
                    AdditionalArgs = ''
                })
            }
        }
    } catch {
        Write-Warning "Get-Package discovery failed: $($_.Exception.Message). Falling back to text parsing for all bundles."
    }

    # --- Source 1: legacy text-parsing for bundles not yet migrated ---------
    $scriptFiles = Get-ChildItem (Join-Path $BucketPath '*') -Include '*.ps1' -Exclude 'Utils.ps1', '*.Tests.ps1' |
        Where-Object {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            -not $declarativeBundles.ContainsKey($stem)
        }

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

# Ensure Save-Artifact is available for the results-writing steps below
# (the declarative Get-Package import above is inside a try/catch, so we
# also import unconditionally here).
$modulePath = Join-Path $repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
Import-Module $modulePath -Force -ErrorAction Stop

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

try {
foreach ($group in $grouped) {
    Write-Host "`n========== $($group.Name) ==========" -ForegroundColor Cyan

    foreach ($pkg in $group.Group) {
        # Check the CI skip list before attempting install
        $skipKey = if ($pkg.InstallerType -eq 'choco') { $pkg.Name } else { $pkg.PackageId }
        if ($script:CISkipPackages.ContainsKey($skipKey)) {
            Skip-Package -Name $pkg.Name -PackageId $pkg.PackageId `
                -InstallerType $pkg.InstallerType -SourceScript $pkg.SourceScript `
                -Reason $script:CISkipPackages[$skipKey]
            continue
        }

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
                Install-ChocoPackage -Name $pkg.Name -PackageId $pkg.PackageId -SourceScript $pkg.SourceScript
            }
            'scoop' {
                Install-ScoopPackage -Name $pkg.Name -PackageId $pkg.PackageId -SourceScript $pkg.SourceScript
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
# Post-Install Verification — scope & location checks
# ============================================================================
Write-Host "`n========== Post-Install Verification ==========" -ForegroundColor Cyan

function Test-Verification {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Test
    )
    try {
        $result = & $Test
        if ($result) {
            Add-Result -Name $Name -PackageId $Name -InstallerType 'verification' `
                -SourceScript 'Test-Installs.ps1' -Command $Description -Status 'pass'
        } else {
            Add-Result -Name $Name -PackageId $Name -InstallerType 'verification' `
                -SourceScript 'Test-Installs.ps1' -Command $Description -Status 'fail' `
                -ErrorOutput "Verification returned false: $Description"
        }
    } catch {
        Add-Result -Name $Name -PackageId $Name -InstallerType 'verification' `
            -SourceScript 'Test-Installs.ps1' -Command $Description -Status 'fail' `
            -ExitCode -1 -ErrorOutput $_.Exception.Message
    }
}

function Get-PackagesNeedingVerification {
    <#
    .SYNOPSIS
        Returns the subset of $Packages of the given InstallerType whose
        install step succeeded (Status='pass') in $Results.
    .DESCRIPTION
        Post-install verification should only run when the install actually
        succeeded.  Packages that were skipped via CISkipPackages, or whose
        install failed upstream, already have an 'untested'/'fail' row in the
        results — running a second verification check just produces a duplicate
        failure (and a duplicate auto-filed CI issue) for the same root cause.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages,
        [Parameter(Mandatory)][string]$InstallerType,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results
    )
    $passedNames = @{}
    foreach ($r in $Results) {
        if ($r.InstallerType -eq $InstallerType -and $r.Status -eq 'pass') {
            $passedNames[$r.Name] = $true
        }
    }
    @($Packages | Where-Object {
        $_.InstallerType -eq $InstallerType -and $passedNames.ContainsKey($_.Name)
    })
}

function Get-ScoopAppLeaf {
    <#
    .SYNOPSIS
        Returns the leaf application directory name for a scoop package
        identifier, stripping any bucket prefix (e.g. 'extras/beyondcompare'
        -> 'beyondcompare').  Scoop installs apps under apps/<leaf> without
        the bucket prefix, so verification paths must use the leaf name.
    #>
    param([Parameter(Mandatory)][string]$Name)
    ($Name -split '/')[ -1 ]
}

function Add-VerificationSkipped {
    <#
    .SYNOPSIS
        Records an 'untested' verification row for a package whose install was
        skipped or failed, so the gap is still visible in the results table
        without filing a duplicate failure issue.
    #>
    param(
        [string]$Name,
        [string]$Reason
    )
    Add-Result -Name $Name -PackageId $Name -InstallerType 'verification' `
        -SourceScript 'Test-Installs.ps1' `
        -Command "SKIPPED: $Reason" -Status 'untested'
}

# --- Scoop global installs (derived from discovered packages) ---
# Only verify packages whose install actually passed.  Skipped/failed installs
# already have a row in $script:Results — running a second 'Test-Path' check
# would just produce a duplicate failure for the same upstream cause.
$scoopPackages = @($packages | Where-Object InstallerType -eq 'scoop')
if ($scoopPackages.Count -gt 0) {
    Write-Host "Verifying scoop packages are installed globally..." -ForegroundColor Gray
    $scoopToVerify = Get-PackagesNeedingVerification -Packages $scoopPackages `
        -InstallerType 'scoop' -Results @($script:Results)
    $scoopVerifyNames = @{}
    foreach ($p in $scoopToVerify) { $scoopVerifyNames[$p.Name] = $true }
    foreach ($pkg in $scoopPackages) {
        if (-not $scoopVerifyNames.ContainsKey($pkg.Name)) {
            Add-VerificationSkipped -Name "scoop-global:$($pkg.Name)" `
                -Reason "Install was skipped or failed; verification not attempted"
            continue
        }
        $leaf = Get-ScoopAppLeaf -Name $pkg.PackageId
        # Authoritative probe: ask scoop itself whether it tracks the
        # app. `scoop list <leaf>` returns a row when the app is in
        # scoop's installed database, at either scope, regardless of
        # whether the manifest's installer actually creates a real
        # apps\<leaf>\current junction. (Several MarkMichaelis bucket
        # manifests are no-op "phantom" packages whose URL is a 0-byte
        # `blank` file and whose installer only emits a Write-Warning;
        # those legitimately appear in scoop's list but never produce a
        # populated apps dir.)
        Test-Verification -Name "scoop-global:$($pkg.Name)" `
            -Description "Scoop should track '$($pkg.Name)' via 'scoop list $leaf'" `
            -Test ([scriptblock]::Create(@"
                `$out = (& scoop list '$leaf' 2>`$null | Out-String)
                # A real row starts with the leaf name followed by
                # whitespace and a version column; the empty-list
                # header ('Installed apps:') has no such row.
                `$out -match "(?im)^\s*$([regex]::Escape($leaf))\s+\S+"
"@))
    }
}

# --- Winget installs (spot-check via 'winget list') ---
# Only verify packages that actually passed installation (skip CI-skipped and failed).
# Uses 'winget list --id' which is the authoritative way to check if winget
# considers a package installed, regardless of install scope or registry layout.
$passedWinget = @($script:Results | Where-Object { $_.Status -eq 'pass' -and $_.InstallerType -eq 'winget' })
if ($passedWinget.Count -gt 0) {
    Write-Host "Verifying winget installs via 'winget list' (spot-check)..." -ForegroundColor Gray
    # Spot-check up to 5 winget packages that passed
    $spotCheck = $passedWinget | Select-Object -First 5
    foreach ($r in $spotCheck) {
        $pkgId = ($packages | Where-Object { $_.Name -eq $r.Name -and $_.InstallerType -eq 'winget' } | Select-Object -First 1).PackageId
        if (-not $pkgId) { continue }
        Test-Verification -Name "winget-installed:$($r.Name)" `
            -Description "Winget package '$($r.Name)' ($pkgId) should appear in 'winget list'" `
            -Test ([scriptblock]::Create(@"
                `$output = cmd /c 'winget list --id $pkgId --accept-source-agreements --disable-interactivity 2>&1'
                `$output -match [regex]::Escape('$pkgId')
"@))
    }
}

# --- PowerShell modules installed to AllUsers (derived from discovered packages) ---
# Same reasoning as scoop-global above: only verify modules that installed
# successfully.  Failed/skipped installs would otherwise generate a duplicate
# verification failure issue.
$psModulePackages = @($packages | Where-Object InstallerType -eq 'ps-module')
if ($psModulePackages.Count -gt 0) {
    Write-Host "Verifying PowerShell modules are installed to AllUsers scope..." -ForegroundColor Gray
    $psModulesToVerify = Get-PackagesNeedingVerification -Packages $psModulePackages `
        -InstallerType 'ps-module' -Results @($script:Results)
    $psVerifyNames = @{}
    foreach ($p in $psModulesToVerify) { $psVerifyNames[$p.Name] = $true }
    foreach ($pkg in $psModulePackages) {
        $modName = $pkg.Name
        if (-not $psVerifyNames.ContainsKey($modName)) {
            Add-VerificationSkipped -Name "ps-module-scope:$modName" `
                -Reason "Install was skipped or failed; verification not attempted"
            continue
        }
        Test-Verification -Name "ps-module-scope:$modName" `
            -Description "Module '$modName' should be installed under Program Files (AllUsers scope)" `
            -Test ([scriptblock]::Create(@"
                `$mod = Get-Module -ListAvailable -Name '$modName' -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not `$mod) { return `$false }
                `$mod.ModuleBase -like "`$env:ProgramFiles*"
"@))
    }
}

# --- Chocolatey feature verification ---
# Note: choco 'feature enable' commands set features in the choco config file,
# NOT as machine environment variables.  Verify via 'choco feature list' instead.
Write-Host "Verifying Chocolatey features are enabled..." -ForegroundColor Gray
$chocoFeatures = @('allowGlobalConfirmation', 'allowEmptyChecksums')
foreach ($feat in $chocoFeatures) {
    Test-Verification -Name "choco-feature:$feat" `
        -Description "Chocolatey feature '$feat' should be enabled" `
        -Test ([scriptblock]::Create(@"
            `$output = cmd /c 'choco feature list --limit-output 2>&1'
            `$output -match '${feat}\|Enabled'
"@))
}

# --- MarkMichaelis bucket is present ---
Write-Host "Verifying MarkMichaelis scoop bucket is present..." -ForegroundColor Gray
Test-Verification -Name "scoop-bucket:MarkMichaelis" `
    -Description "Scoop bucket 'MarkMichaelis' should be present in bucket list" `
    -Test {
        $buckets = scoop bucket list 2>&1 | Out-String
        $buckets -match 'MarkMichaelis'
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

# Write JSON results file via the module's Save-Artifact helper
# (rotating snapshot + stable latest.json under
# $env:TEMP\ScoopBucket\test-results\).
$resultsPath = Save-Artifact -Kind 'test-results' -Data $script:Results -Depth 5
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

} finally {
    # ========================================================================
    # Ensure results are ALWAYS written, even if the script is interrupted or
    # cancelled mid-run.  The try block starts just before the install loop.
    # ========================================================================
    Write-Host "`n========== Writing partial results (finally block) ==========" -ForegroundColor Yellow
    if ($script:Results.Count -gt 0) {
        try {
            $partialPath = Save-Artifact -Kind 'test-results' -Data $script:Results -Depth 5
            Write-Host "Partial results written to: $partialPath"
        } catch {
            Write-Warning "Save-Artifact failed in finally block: $($_.Exception.Message)"
        }
    }
    if ($env:GITHUB_OUTPUT -and -not (Select-String -Path $env:GITHUB_OUTPUT -Pattern 'has_failures' -Quiet -ErrorAction SilentlyContinue)) {
        $anyFail = @($script:Results | Where-Object Status -eq 'fail').Count -gt 0
        "has_failures=$($anyFail ? 'true' : 'false')" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    }
}
