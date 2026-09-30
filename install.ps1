<#
.SYNOPSIS
    Bootstrap a machine: install Chocolatey and Scoop, register this bucket,
    and install the OS base packages bundle.

.DESCRIPTION
    Intended to be run directly from the repo:

        iex (irm https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/install.ps1)

    Engine presence is probed with Test-EngineInstalled, which deliberately
    ignores PowerShell functions and aliases. The MarkMichaelis.ScoopBucket
    module exports `scoop` and `choco` wrapper FUNCTIONS, and Get-Command's
    module auto-discovery finds them through PSModulePath even in a shell
    that never imported the module -- so a bare `Get-Command scoop` reports
    "installed" on a machine with no scoop at all and the bootstrap silently
    skips the install (issue #432).

    The script is self-contained on purpose: it runs before the module (and
    therefore before Update-PathFromRegistry / PathUtilities.ps1) exists on
    the machine, so the few helpers it needs are duplicated here.
#>

if ((Get-ExecutionPolicy) -eq 'Restricted') {
  Set-ExecutionPolicy Bypass -Scope Process -Force
}

#region Helpers

function Test-EngineInstalled {
  <#
  .SYNOPSIS
      Is the named package engine installed as a real executable/script?
  .DESCRIPTION
      Restricted to Application / ExternalScript on purpose: a Function or
      Alias (notably this repo's own `scoop` / `choco` wrappers) must never
      satisfy an "is the engine installed?" probe. See issue #432.
  .EXAMPLE
      if (-not (Test-EngineInstalled 'scoop')) { ... }
  #>
  [OutputType([bool])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
  )
  [bool](Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction Ignore)
}

function Select-EngineCommandPath {
  <#
  .SYNOPSIS
      Pick which resolved command to invoke for an engine.
  .DESCRIPTION
      Pure: operates on already-resolved command objects. Prefers an
      ExternalScript (scoop.ps1) over a native shim (scoop.cmd) so the
      engine keeps emitting objects instead of text -- `scoop bucket list`
      and `scoop list` are consumed as objects below. Returns $null when
      nothing resolved.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Candidate
  )
  if (-not $Candidate) { return $null }
  $ordered = @($Candidate | Where-Object { $_.CommandType -eq 'ExternalScript' }) +
  @($Candidate | Where-Object { $_.CommandType -ne 'ExternalScript' })
  $ordered | Select-Object -First 1 -ExpandProperty Source
}

function Resolve-EnginePath {
  <#
  .SYNOPSIS
      Resolve an engine's real executable/script path, or $null.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
  )
  Select-EngineCommandPath -Candidate @(
    Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction Ignore
  )
}

function Get-RequiredEnginePath {
  <#
  .SYNOPSIS
      Resolve an engine's real executable/script path or throw.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
  )
  $path = Resolve-EnginePath -Name $Name
  if (-not $path) {
    throw "'$Name' is not installed or not on PATH; cannot continue. Open a new shell and re-run."
  }
  $path
}

function Resolve-ScoopRoot {
  <#
  .SYNOPSIS
      Compute the scoop root from the SCOOP value and ProgramData path.
  .DESCRIPTION
      Intentionally NOT the module's same-named Resolve-ScoopRoot: this one
      is pure (both inputs are passed in) and does no discovery, because
      the bootstrap runs before the module exists. Do not dot-source both
      into one session.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter()][AllowNull()][AllowEmptyString()][string]$ScoopEnvValue,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProgramDataPath
  )
  if ($ScoopEnvValue) { return $ScoopEnvValue }
  Join-Path $ProgramDataPath 'scoop'
}

function Get-ScoopInstallState {
  <#
  .SYNOPSIS
      Classify scoop as Installed, Unlinked, Orphaned, or Missing.
  .DESCRIPTION
      Pure: all filesystem/command facts are passed in.

      Orphaned is the state seen in the wild -- a populated root (leftover
      apps\ and shims\) with NO apps\scoop. The upstream installer hard-
      fails there with Deny-Install "'<dir>' exists and is not empty", so
      the root must be moved aside before installing.

      Unlinked keeps that destructive path away from a working install:
      apps\scoop is present but the command does not resolve (a shell whose
      $env:Path predates the install, a damaged shim). Moving that root
      aside would relocate every global app, persist\ and bucket, so the
      only safe response is to refresh PATH and report.

      The app-dir probe is deliberately apps\scoop rather than the module's
      apps\scoop\current: a false negative here costs a moved root, so the
      broader check is the conservative one.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][bool]$CommandFound,
    [Parameter(Mandatory)][bool]$AppDirExists,
    [Parameter(Mandatory)][bool]$RootExists,
    [Parameter(Mandatory)][bool]$RootIsEmpty
  )
  if ($AppDirExists) {
    return $(if ($CommandFound) { 'Installed' } else { 'Unlinked' })
  }
  if ($RootExists -and -not $RootIsEmpty) { return 'Orphaned' }
  'Missing'
}

function Get-ScoopRootBackupPath {
  <#
  .SYNOPSIS
      Sibling path an orphaned scoop root is moved to.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Root,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Timestamp
  )
  "$($Root.TrimEnd('\', '/')).orphaned-$Timestamp"
}

function Merge-PathValue {
  <#
  .SYNOPSIS
      Combine the Machine and User PATH values, de-duped, order preserved.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter()][AllowNull()][AllowEmptyString()][string]$MachinePath,
    [Parameter()][AllowNull()][AllowEmptyString()][string]$UserPath
  )
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $unique = foreach ($part in ((@($MachinePath, $UserPath) -join ';') -split ';')) {
    if ($part -and $seen.Add($part)) { $part }
  }
  $unique -join ';'
}

function Update-PathFromRegistry {
  <#
  .SYNOPSIS
      Refresh $env:Path from the Machine + User registry hives.
  .DESCRIPTION
      An installer that drops a new shim folder onto Machine PATH leaves
      this process with the stale cached value, so a freshly installed
      engine is not resolvable until PATH is re-read. Mirrors the module's
      Update-PathFromRegistry, which is not available during bootstrap.
  #>
  [CmdletBinding()]
  param()
  try {
    $merged = Merge-PathValue `
      -MachinePath ([Environment]::GetEnvironmentVariable('Path', 'Machine')) `
      -UserPath ([Environment]::GetEnvironmentVariable('Path', 'User'))
    # Never blank PATH: the Machine/User hives are Windows-only, and an
    # empty merge would leave the rest of the run with nothing to resolve.
    if ($merged) { $env:Path = $merged }
  } catch {
    Write-Warning "Could not refresh PATH from the registry: $($_.Exception.Message)"
  }
}

function Test-DirectoryEmpty {
  <#
  .SYNOPSIS
      Is the path missing or an empty directory?
  .DESCRIPTION
      Fails closed: a directory that cannot be enumerated (access denied)
      is reported as NOT empty. Reading the empty result of a failed
      enumeration as "empty" would walk a populated, locked-down scoop root
      straight past the orphan handling.
  #>
  [OutputType([bool])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $true }
  $enumerationError = $null
  $entries = @(Get-ChildItem -LiteralPath $Path -Force `
      -ErrorAction SilentlyContinue -ErrorVariable enumerationError)
  if ($enumerationError) {
    Write-Warning "Could not enumerate '$Path' ($($enumerationError[0].Exception.Message)); treating it as non-empty."
    return $false
  }
  -not $entries.Count
}

function Move-OrphanedScoopRoot {
  <#
  .SYNOPSIS
      Move an orphaned scoop root to a timestamped sibling path.
  .DESCRIPTION
      Returns $true only when the root is actually out of the way, so the
      caller can skip the install rather than run the upstream installer
      against a still-populated root (Deny-Install).
  #>
  [OutputType([bool])]
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Root
  )
  $backup = Get-ScoopRootBackupPath -Root $Root -Timestamp (Get-Date -Format 'yyyyMMdd-HHmmss')
  Write-Warning "'$Root' exists but has no apps\scoop; moving it to '$backup' so the installer can proceed."
  if (-not $PSCmdlet.ShouldProcess($Root, "Move orphaned scoop root to '$backup'")) { return $false }
  try {
    Move-Item -LiteralPath $Root -Destination $backup -Force -ErrorAction Stop
  } catch {
    throw "Could not move '$Root' aside to '$backup': $($_.Exception.Message). Close anything running out of that directory, re-run elevated, and try again."
  }
  $true
}

function Install-ScoopEngine {
  <#
  .SYNOPSIS
      Install scoop into $Root, moving an orphaned root aside first.
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Root,
    [Parameter(Mandatory)][ValidateSet('Installed', 'Unlinked', 'Orphaned', 'Missing')][string]$State
  )
  if ($State -eq 'Installed') { return }
  if ($State -eq 'Unlinked') {
    # apps\scoop is present: scoop IS installed, only unreachable from this
    # process. Never move or reinstall -- that would relocate a working
    # install, global apps and persist\ included.
    Write-Warning "scoop is installed at '$Root' but does not resolve on PATH; refreshing PATH instead of reinstalling."
    Update-PathFromRegistry
    return
  }
  # A root that was not moved aside must not be handed to the installer.
  if ($State -eq 'Orphaned' -and -not (Move-OrphanedScoopRoot -Root $Root)) { return }
  if (-not $PSCmdlet.ShouldProcess($Root, 'Install scoop')) { return }
  $env:SCOOP = $Root
  [Environment]::SetEnvironmentVariable('SCOOP', $env:SCOOP, 'Machine')
  Invoke-Expression "& {$(Invoke-RestMethod get.scoop.sh)} -RunAsAdmin"
  Update-PathFromRegistry
}

function Add-ScoopBucket {
  <#
  .SYNOPSIS
      Register a scoop bucket if it is not registered already.
  .PARAMETER ScoopPath
      Path to the real scoop executable/script, from Get-RequiredEnginePath.
      Passed in rather than invoking the bare name, which would enter the
      module's `scoop` wrapper function (issue #432).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
    [Parameter()][string]$Url,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScoopPath
  )

  # Git is required when adding an additional scoop bucket.
  if (-not (Test-EngineInstalled 'git')) {
    & (Get-RequiredEnginePath 'choco') install git -y --params '/GitOnlyOnPath /NoAutoCrlf /NoShellHereIntegration'
    Update-PathFromRegistry
    $env:Path = "$env:Path;$env:ProgramFiles\Git\cmd\"
  }

  if ((& $ScoopPath bucket list).Name -notcontains $Name) {
    $bucketArgs = @('bucket', 'add', $Name)
    if ($Url) { $bucketArgs += $Url }
    Write-Host "scoop $($bucketArgs -join ' ')"
    & $ScoopPath @bucketArgs
  } else {
    Write-Information -MessageData "Scoopbucket $Name is already added."
  }
}

#endregion Helpers

#Install Chocolatey
if (-not (Test-EngineInstalled 'choco')) {
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
  Update-PathFromRegistry
}

#Install Scoop
# Re-read PATH before probing: a shell opened before scoop landed on Machine
# PATH carries a stale $env:Path, and a false "scoop is missing" here is what
# would misclassify a working install.
Update-PathFromRegistry
$scoopRoot = Resolve-ScoopRoot -ScoopEnvValue $env:SCOOP -ProgramDataPath $env:ProgramData
$scoopState = Get-ScoopInstallState `
  -CommandFound (Test-EngineInstalled 'scoop') `
  -AppDirExists ([bool](Test-Path -LiteralPath (Join-Path $scoopRoot 'apps\scoop'))) `
  -RootExists ([bool](Test-Path -LiteralPath $scoopRoot)) `
  -RootIsEmpty (Test-DirectoryEmpty -Path $scoopRoot)
Install-ScoopEngine -Root $scoopRoot -State $scoopState

# Resolve the real scoop once and invoke it by path from here on: the bare
# name would enter the module's `scoop` wrapper function.
$scoopPath = Get-RequiredEnginePath 'scoop'

Add-ScoopBucket -Name 'MarkMichaelis' -Url 'https://github.com/MarkMichaelis/ScoopBucket' -ScoopPath $scoopPath
Add-ScoopBucket -Name 'extras' -ScoopPath $scoopPath

<#'McAfeeUninstall',#> 'OSBasePackages' | ForEach-Object {
  $app = $_
  # Check if app is already installed globally. `scoop list` has NO `-g`
  # flag -- it's `scoop list [query]`. A row with Info='Global install' is
  # how scoop signals scope; treat its presence as the "installed" probe.
  $installed = @(& $scoopPath list $app 2>$null | Where-Object { $_.Name -eq $app -and ($_.Info -as [string]) -match 'Global' }).Count -gt 0

  if ($installed) {
    Write-Host "'$app' is already installed. Checking for updates..." -ForegroundColor Green
    & $scoopPath update $app --global
  } else {
    Write-Host "Installing $app..." -ForegroundColor Cyan
    & $scoopPath install -g $app
  }
}
