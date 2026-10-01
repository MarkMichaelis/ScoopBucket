#requires -Version 7.0
<#
.SYNOPSIS
    Run this bucket's update (`Update-Package '*'`) after Windows Update has
    installed updates. Executed by the scheduled task that
    UpdateBucketOnWindowsUpdate.ps1 registers.

.DESCRIPTION
    1. Rotates the log when it exceeds -MaxLogBytes (one .1 generation kept).
    2. Reads the last-run marker and lists the Windows Update "Installation
       Successful" events (System log, provider
       Microsoft-Windows-WindowsUpdateClient, ID 19) since then.
    3. Records the new marker BEFORE updating, so a burst of events that
       triggers the task again later sees nothing new and skips. The flip
       side: a failed update is not retried automatically; the next
       qualifying Windows update (or a manual -Force run) retries it. If the
       event check itself fails, the marker is left alone and the run exits 1.
    4. Skips (exit 0) when every event's update title matches
       -ExcludeTitlePattern -- by default Defender definition updates and
       Microsoft Store app updates, which install several times a day.
       Otherwise runs the bucket-scoped `Update-Package '*'` (NOT
       -MachineWide), appending every output stream to the log.
    5. Exits 1 when the update throws or any package reports Status
       'Failed', so Task Scheduler's Last Run Result shows the failure.

    Non-interactive: Update-Package's ShouldProcess impact (Medium) is below
    the default ConfirmPreference (High), and it never prompts.

.PARAMETER LogRoot
    Folder for UpdateBucketOnWindowsUpdate.log and the last-run marker.

.PARAMETER ExcludeTitlePattern
    Regex patterns; an installed update whose title matches any of them does
    not by itself trigger a bucket update.

.PARAMETER MaxLogBytes
    Rotate the log once it grows past this size.

.PARAMETER Force
    Run the update even when no qualifying Windows update was installed.

.EXAMPLE
    & "$env:ProgramData\MarkMichaelis.ScoopBucket\UpdateBucketOnWindowsUpdate\Invoke-BucketUpdateAfterWindowsUpdate.ps1" -Force
    Runs the bucket update now, logging as the task would.
#>
[CmdletBinding()]
param(
    [string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'MarkMichaelis.ScoopBucket\UpdateBucketOnWindowsUpdate'),
    [string[]]$ExcludeTitlePattern,
    [long]$MaxLogBytes = 1MB,
    [switch]$Force
)

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

$script:LogFileName = 'UpdateBucketOnWindowsUpdate.log'
$script:MarkerFileName = 'last-run.txt'

function Get-BucketUpdateExcludeTitlePattern {
    <#
    .SYNOPSIS
        Default update titles that do not warrant a bucket update on their own.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @(
        # "Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version ...)"
        'Security Intelligence Update'
        # Store app updates: "<12-char Store product id>-<Package.Name>", e.g. 9WZDNCRFJBH4-Microsoft.Windows.Photos
        '^9[A-Z0-9]{11}-'
    )
}

function Get-WindowsUpdateInstalledEvent {
    <#
    .SYNOPSIS
        Windows Update "Installation Successful" events since a point in time,
        projected to TimeCreated + Title. Empty when there are none.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$Since)
    $filter = @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
        Id           = 19
        StartTime    = $Since
    }
    Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            TimeCreated = $_.TimeCreated
            Title       = if ($_.Properties.Count -gt 0) { [string]$_.Properties[0].Value } else { '' }
        }
    }
}

function Select-QualifyingWindowsUpdateEvent {
    <#
    .SYNOPSIS
        Events newer than -Since whose title matches none of the exclusions.
        Pure.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$UpdateEvent,
        [Parameter(Mandatory)][datetime]$Since,
        [AllowEmptyCollection()][string[]]$ExcludeTitlePattern = (Get-BucketUpdateExcludeTitlePattern)
    )
    foreach ($evt in $UpdateEvent) {
        if ($null -eq $evt -or $evt.TimeCreated -le $Since) { continue }
        $excluded = $false
        foreach ($pattern in $ExcludeTitlePattern) {
            if ($evt.Title -match $pattern) { $excluded = $true; break }
        }
        if (-not $excluded) { $evt }
    }
}

function Get-BucketUpdateLastRun {
    <#
    .SYNOPSIS
        The last-run marker, or Now minus DefaultLookback when it is missing
        or unreadable (first run: consider the past day's updates).
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$Now = (Get-Date),
        [timespan]$DefaultLookback = ([timespan]::FromDays(1))
    )
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
        $parsed = [datetime]::MinValue
        if ($raw -and [datetime]::TryParse($raw.Trim(), [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            return $parsed
        }
    }
    return $Now - $DefaultLookback
}

function Set-BucketUpdateLastRun {
    <#
    .SYNOPSIS
        Record the last-run marker (round-trip ISO 8601).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$At = (Get-Date)
    )
    Set-Content -LiteralPath $Path -Value $At.ToString('o') -NoNewline
}

function Limit-BucketUpdateLog {
    <#
    .SYNOPSIS
        Rotate the log to <log>.1 (replacing any older .1) once it exceeds
        MaxBytes, capping the log's disk use at roughly twice MaxBytes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaxBytes
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt $MaxBytes) {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
}

function Write-BucketUpdateLog {
    <#
    .SYNOPSIS
        Append a timestamped line to the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Message
    )
    Add-Content -LiteralPath $Path -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message)
}

function ConvertTo-BucketUpdateLogText {
    <#
    .SYNOPSIS
        Render one item from the update's merged output streams as log text,
        prefixed by stream so warnings and errors stand out.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Item)
    switch ($Item) {
        { $_ -is [System.Management.Automation.WarningRecord] } { return "WARNING: $($_.Message)" }
        { $_ -is [System.Management.Automation.ErrorRecord] } { return "ERROR: $($_.Exception.Message)" }
        { $_ -is [System.Management.Automation.VerboseRecord] } { return "VERBOSE: $($_.Message)" }
        { $_ -is [System.Management.Automation.InformationRecord] } { return [string]$_.MessageData }
        default { return ($Item | Out-String).TrimEnd() }
    }
}

function Invoke-BucketUpdateAfterWindowsUpdate {
    <#
    .SYNOPSIS
        Check for qualifying Windows updates and, if any, run the bucket
        update. Returns the process exit code (0 success/skip, 1 failure).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$LogRoot,
        [AllowEmptyCollection()][string[]]$ExcludeTitlePattern = (Get-BucketUpdateExcludeTitlePattern),
        [long]$MaxLogBytes = 1MB,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $LogRoot)) {
        New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
    }
    $log = Join-Path $LogRoot $script:LogFileName
    $marker = Join-Path $LogRoot $script:MarkerFileName
    Limit-BucketUpdateLog -Path $log -MaxBytes $MaxLogBytes

    $now = Get-Date
    try {
        $since = Get-BucketUpdateLastRun -Path $marker -Now $now
        $qualifying = @(Select-QualifyingWindowsUpdateEvent -UpdateEvent @(Get-WindowsUpdateInstalledEvent -Since $since) -Since $since -ExcludeTitlePattern $ExcludeTitlePattern)
    } catch {
        # Leave the marker alone so the next trigger re-examines these events.
        Write-BucketUpdateLog -Path $log -Message "ERROR: checking for installed Windows updates failed: $($_.Exception.Message)"
        return 1
    }
    # Record the check before updating: later triggers from the same burst
    # (or events that arrived during the trigger delay) then see nothing new.
    Set-BucketUpdateLastRun -Path $marker -At $now

    if ($qualifying.Count -eq 0 -and -not $Force) {
        Write-BucketUpdateLog -Path $log -Message "No qualifying Windows updates installed since $($since.ToString('o')); skipped the bucket update."
        return 0
    }

    $reason = if ($qualifying.Count -gt 0) { "Windows Update installed: $(($qualifying | ForEach-Object Title) -join '; ')" } else { 'Forced run (-Force).' }
    Write-BucketUpdateLog -Path $log -Message "===== Bucket update starting. $reason"

    $results = [System.Collections.Generic.List[object]]::new()
    $exitCode = 0
    try {
        & { Update-Package -Name '*' } *>&1 | ForEach-Object {
            if ($_ -and $_.PSObject.TypeNames -contains 'PackageResult') {
                $results.Add($_)
            } else {
                $text = ConvertTo-BucketUpdateLogText -Item $_
                if ($text) { Add-Content -LiteralPath $log -Value $text }
            }
        }
    } catch {
        Write-BucketUpdateLog -Path $log -Message "ERROR: Update-Package threw: $($_.Exception.Message)"
        $exitCode = 1
    }

    if ($results.Count -gt 0) {
        Add-Content -LiteralPath $log -Value (($results | Format-Table Status, Name, Installer, VersionFrom, VersionTo, Reason -AutoSize | Out-String -Width 200).TrimEnd())
    }
    $failed = @($results | Where-Object Status -eq 'Failed')
    if ($failed.Count -gt 0) {
        Write-BucketUpdateLog -Path $log -Message "ERROR: $($failed.Count) package update(s) failed: $(($failed | ForEach-Object Name) -join ', ')"
        $exitCode = 1
    }
    Write-BucketUpdateLog -Path $log -Message "===== Bucket update finished (exit $exitCode)."
    return $exitCode
}

# Main orchestration: runs only when invoked (not when dot-sourced by tests).
if ($MyInvocation.InvocationName -ne '.') {
    $runArgs = @{ LogRoot = $LogRoot; MaxLogBytes = $MaxLogBytes; Force = $Force }
    if ($PSBoundParameters.ContainsKey('ExcludeTitlePattern')) { $runArgs['ExcludeTitlePattern'] = $ExcludeTitlePattern }
    exit (Invoke-BucketUpdateAfterWindowsUpdate @runArgs)
}
