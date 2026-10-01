#requires -Version 7.0
<#
.SYNOPSIS
    Register (or remove) a scheduled task that runs this bucket's update,
    `Update-Package '*'`, after Windows Update installs updates.

.DESCRIPTION
    Trigger: Windows Update's "Installation Successful" event -- Event ID 19
    from provider Microsoft-Windows-WindowsUpdateClient. That event is written
    to the System log; the Microsoft-Windows-WindowsUpdateClient/Operational
    log carries only the scan/download events (IDs 25, 26, 41), so the task
    subscribes to System filtered by provider and ID.

    Debounce: the trigger waits 10 minutes, the task never starts a second
    instance while one is running (IgnoreNew), and the runner keeps a last-run
    marker so events that land during the delay or during a run do not cause
    another update. Event ID 19 also fires several times a day for Defender
    definition updates and Microsoft Store app updates; Task Scheduler's event
    XPath cannot filter on title substrings, so the runner skips (exit 0) when
    every update since its last check matches its exclusion list.

    Action: pwsh -NoProfile -NonInteractive runs
    Invoke-BucketUpdateAfterWindowsUpdate.ps1, which imports
    MarkMichaelis.ScoopBucket from the scoop bucket clone and runs the
    bucket-scoped `Update-Package '*'` (NOT -MachineWide). Output is appended
    to a size-capped log under %LOCALAPPDATA%.

    The runner is copied to an admin-owned folder under %ProgramData% rather
    than run from the scoop app dir or %LOCALAPPDATA%: the task runs with
    highest privileges, so the file it executes must not be writable by an
    unelevated process. Copying also makes the task independent of where this
    installer ran from (a scoop app version dir, or a repo checkout).

    Principal: the installing user, highest privileges, Interactive logon (no
    stored password). The trade-off: an event that fires while the user is
    logged off does not start the task. Because the runner considers every
    event since its last check, the next Windows Update event after logon
    (Defender definition updates arrive several times a day) picks up the
    missed update.

    Registering a highest-privilege task requires an elevated session, so the
    installer throws with an actionable message when it is not elevated rather
    than silently registering a limited task.

    Idempotent: re-running re-copies the runner and re-registers the task in
    place (Register-ScheduledTask -Force). Uninstalling an absent task is a
    no-op.

.PARAMETER Uninstall
    Remove the task and the staged runner instead of installing.

.PARAMETER TaskName
    Scheduled task name. Tests pass a throwaway name.

.PARAMETER TaskPath
    Scheduled task folder.

.PARAMETER InstallRoot
    Admin-owned folder the runner is copied to.

.PARAMETER LogRoot
    Folder for the runner's log and last-run marker; baked into the task's
    arguments.

.EXAMPLE
    sudo scoop install MarkMichaelis/UpdateBucketOnWindowsUpdate

.EXAMPLE
    .\UpdateBucketOnWindowsUpdate.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$TaskName = 'UpdateBucketOnWindowsUpdate',
    [string]$TaskPath = '\MarkMichaelis.ScoopBucket\',
    [string]$InstallRoot = (Join-Path $env:ProgramData 'MarkMichaelis.ScoopBucket\UpdateBucketOnWindowsUpdate'),
    [string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'MarkMichaelis.ScoopBucket\UpdateBucketOnWindowsUpdate')
)

$script:RunnerFileName = 'Invoke-BucketUpdateAfterWindowsUpdate.ps1'

function Test-IsElevated {
    <#
    .SYNOPSIS
        Whether this session holds an elevated (administrator) token.
        Wrapped so tests can mock it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsUpdateTaskSubscription {
    <#
    .SYNOPSIS
        The event-trigger query: Windows Update "Installation Successful"
        (provider Microsoft-Windows-WindowsUpdateClient, Event ID 19), which
        Windows writes to the System log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and EventID=19]]</Select></Query></QueryList>"
}

function Get-TaskPwshCandidate {
    <#
    .SYNOPSIS
        Stable pwsh.exe locations, in preference order. Deliberately excludes
        the Store's version-pinned WindowsApps\Microsoft.PowerShell_<ver>
        folder, which disappears on the next pwsh update; the per-user
        WindowsApps execution alias is stable across updates.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )
}

function Resolve-TaskPwshPath {
    <#
    .SYNOPSIS
        The pwsh.exe the task should launch: the first existing candidate, or
        the bare name (resolved on PATH when the task runs).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Candidate = (Get-TaskPwshCandidate))
    foreach ($path in $Candidate) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    return 'pwsh.exe'
}

function New-WindowsUpdateTaskDefinition {
    <#
    .SYNOPSIS
        Build the task's action, trigger, settings and principal. Creates
        client-side objects only; registers nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][string]$LogRoot,
        [string]$PwshPath = (Resolve-TaskPwshPath),
        [string]$UserId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    )

    # A path ending in '\' right before the closing quote would escape the
    # quote under Windows command-line parsing, so trim trailing separators.
    $RunnerPath = [IO.Path]::TrimEndingDirectorySeparator($RunnerPath)
    $LogRoot = [IO.Path]::TrimEndingDirectorySeparator($LogRoot)
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RunnerPath`" -LogRoot `"$LogRoot`""
    $action = New-ScheduledTaskAction -Execute $PwshPath -Argument $arguments

    # New-ScheduledTaskTrigger has no event-subscription form; build the CIM
    # trigger directly.
    $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
    $trigger.Subscription = Get-WindowsUpdateTaskSubscription
    $trigger.Delay = 'PT10M'
    $trigger.Enabled = $true

    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RunOnlyIfNetworkAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest

    return @{
        Action      = $action
        Trigger     = $trigger
        Settings    = $settings
        Principal   = $principal
        Description = "Runs MarkMichaelis.ScoopBucket's Update-Package '*' after Windows Update installs updates. Log: $LogRoot. Managed by the UpdateBucketOnWindowsUpdate scoop package."
    }
}

function Set-RunnerFolderAcl {
    <#
    .SYNOPSIS
        Give the runner folder an explicit, non-inherited ACL: SYSTEM and
        Administrators full control, Users read & execute, owner
        Administrators. The task runs the folder's script with highest
        privileges, so standard users must not be able to change it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagate = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($sid in $system, $admins) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inherit, $propagate, $allow))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'ReadAndExecute', $inherit, $propagate, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Install-UpdateBucketOnWindowsUpdate {
    <#
    .SYNOPSIS
        Stage the runner and register (or update in place) the task.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskName = 'UpdateBucketOnWindowsUpdate',
        [string]$TaskPath = '\MarkMichaelis.ScoopBucket\',
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$LogRoot,
        [string]$SourceRunner = (Join-Path $PSScriptRoot $script:RunnerFileName)
    )

    if (-not (Test-IsElevated)) {
        throw "Registering the '$TaskName' task with highest privileges requires an elevated session. Re-run from an elevated shell, e.g. 'sudo scoop install MarkMichaelis/UpdateBucketOnWindowsUpdate' (or 'sudo scoop update UpdateBucketOnWindowsUpdate --force')."
    }
    if (-not (Test-Path -LiteralPath $SourceRunner -PathType Leaf)) {
        throw "Runner script not found next to the installer: $SourceRunner"
    }

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }
    # Lock the folder down BEFORE staging, then replace (not overwrite) the
    # runner, so neither a folder nor a file pre-created by an unelevated
    # process keeps an ACL that would let it rewrite what the task runs.
    Set-RunnerFolderAcl -Path $InstallRoot
    $runner = Join-Path $InstallRoot $script:RunnerFileName
    if (Test-Path -LiteralPath $runner) { Remove-Item -LiteralPath $runner -Force }
    Copy-Item -LiteralPath $SourceRunner -Destination $runner

    $definition = New-WindowsUpdateTaskDefinition -RunnerPath $runner -LogRoot $LogRoot
    $task = Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Force @definition
    Write-Host "Registered scheduled task '$TaskPath$TaskName': runs Update-Package '*' after Windows Update installs updates. Log: $(Join-Path $LogRoot 'UpdateBucketOnWindowsUpdate.log')"
    return $task
}

function Uninstall-UpdateBucketOnWindowsUpdate {
    <#
    .SYNOPSIS
        Remove the task and the staged runner. No-op when already gone. The
        log folder is left in place as a record of past runs.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskName = 'UpdateBucketOnWindowsUpdate',
        [string]$TaskPath = '\MarkMichaelis.ScoopBucket\',
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    $staged = Test-Path -LiteralPath $InstallRoot
    # The staged folder is ACL-locked to administrators, so removing it needs
    # elevation even when the task itself is already gone.
    if (($existing -or $staged) -and -not (Test-IsElevated)) {
        throw "Removing the '$TaskPath$TaskName' task and its staged runner ($InstallRoot) requires an elevated session. Re-run elevated, e.g. 'sudo scoop uninstall UpdateBucketOnWindowsUpdate'."
    }
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        Write-Host "Removed scheduled task '$TaskPath$TaskName'."
    }
    if ($staged) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }
}

# Main orchestration: runs only when invoked (not when dot-sourced by tests).
if ($MyInvocation.InvocationName -ne '.') {
    if ($Uninstall) {
        Uninstall-UpdateBucketOnWindowsUpdate -TaskName $TaskName -TaskPath $TaskPath -InstallRoot $InstallRoot
    } else {
        Install-UpdateBucketOnWindowsUpdate -TaskName $TaskName -TaskPath $TaskPath -InstallRoot $InstallRoot -LogRoot $LogRoot | Out-Null
    }
}
