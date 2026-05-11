
# TODO: Generalize
$UserBucket = "MarkMichaelis"

if(!$env:SCOOP -and (test-path "$env:ProgramData\scoop\apps\scoop\current")) {
    $env:SCOOP = "$env:ProgramData\scoop"
}

if($env:SCOOP) {
    $currentScoopDirectory = "$env:SCOOP\apps\scoop\current"
    # Internal scoop helpers used by the `scoop` wrapper below
    # (parse_app, Find-BucketDirectory, search_bucket). Their locations have
    # shifted across scoop versions, so dot-source defensively.
    foreach ($rel in @(
            'lib\core.ps1',
            'lib\buckets.ps1',
            'lib\manifest.ps1',
            'libexec\scoop-search.ps1'
        )) {
        $p = Join-Path $currentScoopDirectory $rel
        if (Test-Path $p) {
            . $p > $null 2>&1
        }
    }
}
else {
    Write-Warning '$env:SCOOP not found.'
}

Function Test-Command {
    [CmdletBinding()]
    param(
        [string]$command
    )
    return [bool](get-command $command -ErrorAction Ignore)
}

# TODO: Consider writing as a filter.
Function Test-ChocolateyPackageInstalled {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageName
    )

    $installed = choco list $PackageName --local-only --no-progress | Where-Object {
        # Alternate filter
        #choco list  -localonly | Where-Object { ($_ -notmatch 'Chocolatey v[0-9\.]') -and $_ -notmatch '\d+ packages installed\.' }
        $_ -match "$PackageName\s.*"
    }
    Write-Output (@($installed).Count -gt 0)
}

Function Test-ScoopPackageInstalled {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageName
    )

    $scoopOutput = scoop export $PackageName
    $installed = $scoopOutput | Where-Object {
        # Alternate filter
        #choco list  -localonly | Where-Object { ($_ -notmatch 'Chocolatey v[0-9\.]') -and $_ -notmatch '\d+ packages installed\.' }
        $_ -match "\s*$PackageName\s.*"
    }
    Write-Output (@($installed).Count -gt 0)
}

function choco {
    $installArgs = Get-InstallArgs @args
    if(
        ($installArgs.Action -eq 'install') `
        -and ($installArgs.Options -notcontains '-f') `
        -and ($installArgs.Options -notcontains '--force') `
        -and (Test-ChocolateyPackageInstalled $installArgs.Arg1)
        ) {
        Write-Warning "$($installArgs.Arg1) is already installed."
    }
    else {
        choco.exe @args
    }
}

 
function Get-LocalBucket {
    <#
    .SYNOPSIS
        List all local buckets.
    #>

    $bucketsdir = (Join-Path $env:scoop buckets)
    if($bucketsdir -ne (Split-Path (Find-BucketDirectory).Trim('bucket') -Parent)) {
        Write-Warning 'Bucket direcotry doesn''t match Find-BucketDirectory location.'
    }
    $buckets = (Get-ChildItem $bucketsdir -Directory).Name
    if($UserBucket) {
        $buckets = ,$UserBucket + ($buckets | Where-Object { $_ -ne $UserBucket })
    }
    Write-Output $buckets
}

<#
.SYNOPSIS
# Parse out the arguments used on a command

.DESCRIPTION
# Given a command, parse out the original arguments into options, "actions", and 
# additional argumenst for the action.  The assumption
# is that the first argument is the commad, e.g. choco install.  The remaining 
# arguments are arguments for the command, e.g. choco install 'VisualStudio'.  All
# original arguments beginning with a dash ('-'), are parsed as options
# to the action.

.EXAMPLE
choco install VisualStudio -y --force

.NOTES
The class should work for both scoop and chocolatey (choco), or any other
command broken into <original command> <subcommand> <arguments> <options>.
#>
class InstallArgs {
    # The complete list of original arguments, including actions and options.
    [string[]]$OriginalArgs
    # All original arguments that begin with a dash.
    [string[]]$Options
    # All the original arguments that didn't begin with a dash.
    [string[]]$SubCommands
    # The first original argument that is not an option.
    [string]$Action
    # The first SubCommand that isn't an action (in other words the second subcommand)
    [string]$Arg1

    InstallArgs([string[]]$OriginalArgs) {
        [string[]]$localSubCommands = $OriginalArgs | Where-Object { $_ -notlike '-*'}
        $this.OriginalArgs = $OriginalArgs
        $this.Options = $OriginalArgs | Where-Object { $_ -like '-*'};
        $this.SubCommands = $localSubCommands 
        $this.Action =  $localSubCommands | Select-Object -First 1;
        $this.Arg1 = $localSubCommands | Select-Object -Skip 1 | Select-Object -First 1
    }
}


function Get-InstallArgs {
    return [InstallArgs]::new($args)
}

function scoop {
    [InstallArgs]$scoopArgs = Get-InstallArgs @args
    $localArgs = $scoopArgs.OriginalArgs
    $cmd = $scoopArgs.Action
    $options = $scoopArgs.Options
    $arg1 = $scoopArgs.Arg1

    switch ($cmd) {
        'install' {  
            #Make the $UserBucket the priority.
            $null, $bucket, $null = parse_app $arg1
            if(-not $bucket) {
                scoop search $arg1 -PSCustomObject | Where-Object {
                    $_.name -match "^$args$" 
                } | Where-Object { 
                        $_.Bucket -eq $UserBucket 
                } | ForEach-Object {
                    $index = [array]::indexof($localArgs,$_.name)
                    $localArgs[$index] = "$UserBucket/$arg1"
                } 
            }
            scoop.ps1 @localArgs
        }
        'search' {
            if($options -contains '-PSCustomObject') {
                Get-LocalBucket | ForEach-Object {
                    $bucket = $_
                    search_bucket $_ $arg1 | ForEach-Object {
                        $_['Bucket'] = $bucket 
                        Write-Output ([PSCustomObject]$_)
                    }
                }
            }
            else {
                scoop.ps1 @args
            }
        }
        Default {
            scoop.ps1 @args   
        }
    }   
}

Function Get-Program {
    [CmdletBinding()] param([string] $Filter = "*") 

    $ProgramRegistryKeys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "Microsoft.PowerShell.Core\Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Uninstall"

    # REview for 32/64 Bit
    # http://gallery.technet.microsoft.com/scriptcenter/PowerShell-Installed-70d0c0f4

    $ProgramRegistryKeys | Get-ChildItem | Get-ItemProperty | 
    Select-Object  *, @{Name = "Name"; Expression = { 
            if ( ($_ | Get-Member "DisplayName") -and $_.DisplayName) {
                #Consider $_.PSObject.Properties.Match("DisplayName") as it may be faster
                $_.DisplayName
            } 
            else { 
                $_.PSChildName 
            } 
        }
    } | Where-Object { ($_.Name -Like $Filter) -or ($_.PSChildName -Like $Filter) } 
}

Function Import-ChocolateyModule {
    if (test-path env:ChocolateyInstall) {
        Import-Module (Resolve-Path -Path "$env:ChocolateyInstall\*\chocolateyInstaller.psm1").Path
        if (Test-Path Function:\Write-Host) {
            Remove-Item Function:Write-Host # Chocolatey overwrites Write-Host.  This call removes the override.  It should still occur within Chocolatey.
            # Note that this is necessary otherwise Write-Host attempts to write to the chocolatey log file in Program Data and doesn't have
            # permission outside of an admin prompt.
        }
        $env:ChocolateyAllowEmptyChecksumsSecure = $true
        $env:ChocolateyAllowEmptyChecksums = $true
        $env:ChocolateyPackageFolder = "$env:ChocolateyInstall\Lib"
        Set-PackageSource -Name chocolatey -ProviderName Chocolatey -Trusted -Force
    }
    else {
        throw "Chocolatey is not installed"
    }
}


if (!(Test-Path function:Install-WebDownload)) {
    Function Install-WebDownloadOfZip {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string] $PackageName,
            [Parameter(Mandatory)][alias("Uri")][string] $url,
            $UnzipLocation = "$env:ChocolateyInstall\lib\$PackageName"
        )

        Import-ChocolateyModule

        # See Chocolatey's Get-CheckSumValid.ps1 for more info.
        $originalChocolateyAllowEmptyChecksums = $env:ChocolateyAllowEmptyChecksums
        $originalChocolateyAllowEmptyChecksumsSecure = $env:ChocolateyAllowEmptyChecksumsSecure
        try {
            # Needed because Chocolatey is not setting up context.
            if (!(test-path variable:\helpersPath)) {
                $setHelpersPath = $true
                $global:helpersPath = $env:ChocolateyInstall
            }

            $env:ChocolateyAllowEmptyChecksums = 'true'
            $env:ChocolateyAllowEmptyChecksumsSecure = 'true'
            Install-ChocolateyZipPackage -packageName $PackageName -url $url -unzipLocation $UnzipLocation -specificFolder ''
            Get-ChildItem $UnzipLocation *.exe | ForEach-Object { Install-BinFile -name TrayIt -path $_.FullName }
        }
        finally {
            if ($setHelpersPath) {
                remove-item variable:\global:helpersPath
            }
            $env:ChocolateyAllowEmptyChecksums = $originalChocolateyAllowEmptyChecksums
            $env:ChocolateyAllowEmptyChecksumsSecure = $originalChocolateyAllowEmptyChecksumsSecure
        }
    }


    Function Install-WebDownload {
        [CmdletBinding()] param(
            [Parameter(Mandatory)][alias("Uri")][string] $url,
            [Parameter(Mandatory)][string] $PackageName,
            [Parameter(ParameterSetName = "CommandLine")] [string] $arguments = $null,
            [Parameter(ParameterSetName = "ScriptBlock")][ScriptBlock] $postDownloadScriptBlock,
            [Parameter(ParameterSetName = "UnattendedSilentSwitchFinder",
                HelpMessage = "Lookup the unattended silent switch for the setup program.")][switch]$ussf,
            [string] $installFileName = [System.Management.Automation.WildcardPattern]::Escape((Split-Path $url -Leaf)),
            [switch]$forceDownload )

        #TODO Switch to Get-ChocolateyWebFile and use Invoke-WebRequest as fallback.
        $tempPath = Get-TempPath

        if ([IO.Path]::GetExtension($InstallFileName) -eq ".zip") {
            Install-WebDownloadOfZip -Uri $url -packageName $PackageName
        }
        else {
            $installFileName = Join-Path $tempPath $installFileName

            if ($forceDownload -OR ($installFileName -eq "Setup.exe") -OR !(Test-Path $installFileName) ) {
                Invoke-WebRequest $url -OutFile $installFileName
            }

            if ($ussf) {
                ussf $installFileName
            }
            else {
                If ( ([string]::IsNullOrWhiteSpace($PsCmdlet.ParameterSetName)) -or ($PsCmdlet.ParameterSetName -eq "CommandLine") ) {
                    $postDownloadScriptBlock = [ScriptBlock] {
                        $process = Start-Process $installFileName $arguments -PassThru -wait
                        return $process.ExitCode
                    }
                }
            }
            Write-Output (Invoke-Command $postDownloadScriptBlock)
        }
    }
}

<#
.SYNOPSIS
    Install a Scoop manifest from a working-copy path with its url[] entries
    rewritten to point at the local bucket directory.

.DESCRIPTION
    Solves the local-test problem: a bucket manifest's url[] entries point at
    raw.githubusercontent.com/.../master/bucket/..., so a plain
    `scoop install <local.json>` would fetch master, not the working copy.
    This helper rewrites those URLs to file:// URIs anchored at $LocalBucketRoot,
    writes the rewritten manifest to $env:TEMP, and runs scoop install against
    the temp manifest. Cleans up in a finally block.

.PARAMETER ManifestPath
    Absolute path to the source manifest (.json) in the working copy.

.PARAMETER ManifestName
    Bucket-relative manifest name (e.g. 'AIAgents'). Resolves to
    `$env:SCOOPBUCKET_LOCAL_REPO\bucket\<name>.json`. Mutually exclusive
    with -ManifestPath. Useful for nested invocations from bundle scripts
    (see Install-BucketApp).

.PARAMETER LocalBucketRoot
    Directory to substitute for the GitHub-master bucket URL. Defaults to the
    parent directory of $ManifestPath (i.e., bucket/ itself).

.PARAMETER BucketName
    Name of the scoop bucket to temporarily repoint at the working copy so
    that fully-qualified manifest references inside installer scripts (e.g.
    `scoop install MarkMichaelis/Claude` from AIAgents.ps1) resolve against
    the local repo. The original bucket source is captured before the swap
    and restored in `finally`. Defaults to 'MarkMichaelis'. Pass $null to
    skip the swap entirely.

.EXAMPLE
    Install-LocalManifest -ManifestPath "$PSScriptRoot\McAfeeUninstall.json"
#>
Function Install-LocalManifest {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)][string]$ManifestPath,
        [Parameter(Mandatory, ParameterSetName = 'Name')][string]$ManifestName,
        [string]$LocalBucketRoot,
        [AllowNull()][string]$BucketName = 'MarkMichaelis'
    )

    if ($PSCmdlet.ParameterSetName -eq 'Name') {
        if (-not $env:SCOOPBUCKET_LOCAL_REPO) {
            throw "Install-LocalManifest -ManifestName requires `$env:SCOOPBUCKET_LOCAL_REPO to be set."
        }
        $ManifestPath = Join-Path $env:SCOOPBUCKET_LOCAL_REPO "bucket\$ManifestName.json"
    }

    if (-not (Test-Path $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }
    if (-not $LocalBucketRoot) {
        $LocalBucketRoot = Split-Path -Parent $ManifestPath
    }

    # Resolve to absolute paths so the regex substitution produces a valid
    # file:// URI. [Uri]::AbsoluteUri returns empty for relative paths.
    $ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
    $LocalBucketRoot = (Resolve-Path -LiteralPath $LocalBucketRoot).Path
    $repoRoot = Split-Path -Parent $LocalBucketRoot

    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.url) {
        $manifest.url = @(
            $manifest.url | ForEach-Object {
                $rewritten = $_ -replace `
                    'https://raw\.githubusercontent\.com/MarkMichaelis/ScoopBucket/master/bucket', `
                    $LocalBucketRoot
                ([Uri]$rewritten).AbsoluteUri
            }
        )
    }

    # Capture original bucket source so we can restore it after the install.
    # If the bucket isn't currently registered, $originalSource stays $null
    # and we'll just remove the temp bucket on cleanup.
    $bucketSwapped = $false
    $originalSource = $null
    if ($BucketName) {
        $bucketDir = Join-Path $env:USERPROFILE "scoop\buckets\$BucketName"
        $localUrl = ([Uri]$repoRoot).AbsoluteUri
        if (Test-Path $bucketDir) {
            # Pre-register safe.directory to dodge git's "dubious ownership"
            # error which otherwise blanks out the remote URL lookup.
            $safeDir = ($bucketDir -replace '\\','/')
            $null = git config --global --add safe.directory $safeDir 2>&1
            try {
                $gitOut = git -C $bucketDir config --get remote.origin.url 2>$null
                if ($gitOut) { $originalSource = $gitOut.Trim() }
            } catch { }
        }
        # Only swap if the bucket isn't already pointing at the working copy
        # (avoids pointless rm/add cycles on repeat calls).
        $alreadyLocal = $originalSource -and (
            $originalSource -eq $localUrl -or
            $originalSource.TrimEnd('/','\') -eq $repoRoot.TrimEnd('/','\')
        )
        if (-not $alreadyLocal) {
            if (Test-Path $bucketDir) {
                $null = scoop.ps1 bucket rm $BucketName 2>&1
            }
            # scoop bucket add requires a git URL, not a raw path. Convert to
            # a file:// URI (scoop's "not a valid Git URL" warnings are noisy
            # but harmless — the file:// URL itself succeeds).
            $null = scoop.ps1 bucket add $BucketName $localUrl 2>&1
            $bucketSwapped = $true
            # safe.directory needs to cover the freshly-cloned dir as well.
            $null = git config --global --add safe.directory $safeDir 2>&1
        }
    }

    $tempManifest = Join-Path $env:TEMP (Split-Path -Leaf $ManifestPath)
    $appName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
    $previousLocalRepo = $env:SCOOPBUCKET_LOCAL_REPO
    try {
        # Expose the working-copy repo root to nested invocations
        # (Install-BucketApp called from installer.script) so they can
        # build per-app temp manifests instead of `scoop install
        # MarkMichaelis/<App>` against the (un-mutated) cloned bucket.
        $env:SCOOPBUCKET_LOCAL_REPO = $repoRoot
        scoop.ps1 hold scoop | Out-Null
        # Pre-clean: if a prior failed install left scoop in a wedged state,
        # `scoop install` will try to purge it mid-run and then fail with an
        # "empty Uri" error inside Get-InstallationHelper. Uninstall up-front.
        $null = scoop.ps1 uninstall $appName 2>&1
        $manifest | ConvertTo-Json -Depth 20 | Out-File -FilePath $tempManifest -Encoding UTF8
        scoop.ps1 install $tempManifest
    }
    finally {
        Remove-Item -Force -Path $tempManifest -ErrorAction Ignore
        scoop.ps1 unhold scoop | Out-Null
        if ($previousLocalRepo) {
            $env:SCOOPBUCKET_LOCAL_REPO = $previousLocalRepo
        } else {
            Remove-Item Env:\SCOOPBUCKET_LOCAL_REPO -ErrorAction Ignore
        }
        if ($bucketSwapped) {
            $null = scoop.ps1 bucket rm $BucketName 2>&1
            if ($originalSource) {
                $null = scoop.ps1 bucket add $BucketName $originalSource 2>&1
            }
        }
    }
}

<#
.SYNOPSIS
    Install a MarkMichaelis bucket app, preferring a working-copy manifest
    when running under Install-LocalManifest.

.DESCRIPTION
    Bundle scripts (AIAgents.ps1, ClientBasePackages.ps1, etc.) call this
    helper instead of `scoop install MarkMichaelis/<App>`. When the outer
    install was started via Install-LocalManifest, the env var
    SCOOPBUCKET_LOCAL_REPO points at the working-copy repo root. In that
    case we recurse through Install-LocalManifest -ManifestName so the
    nested install also resolves unpushed `.ps1` files from the working
    copy — without ever mutating the cloned MarkMichaelis bucket dir.

    In production (env var unset) we fall back to the regular
    `scoop install MarkMichaelis/<App>` path.

.PARAMETER Name
    Bare app/manifest name (e.g. 'Claude'). Do NOT include the
    'MarkMichaelis/' prefix.
#>
function Install-BucketApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if ($env:SCOOPBUCKET_LOCAL_REPO -and
        (Test-Path (Join-Path $env:SCOOPBUCKET_LOCAL_REPO "bucket\$Name.json"))) {
        Install-LocalManifest -ManifestName $Name
    } else {
        scoop install "MarkMichaelis/$Name"
    }
}

# ============================================================================
# PowerShell tab-completion registration for installed CLI tools.
#
# Two-tier strategy per CLI:
#   1. Native — emit the verbatim output of `<cli> completion powershell`
#      (or the curated equivalent in $script:CliCompletionNativeMap) into
#      a sentinel-delimited block in the AllUsersAllHosts profile.
#   2. PSCompletions fallback — emit `Import-Module PSCompletions` (once)
#      and call `psc add <cli>` at registration time so PSCompletions's
#      own storage retains the binding for future sessions.
#   3. Skip — no native command and no PSCompletions catalog entry.
#
# Persistence: the registration code is embedded directly in
# `$PSHOME\Profile.ps1` (AllUsersAllHosts), so every PowerShell host for
# every user picks it up on startup. Per-CLI sentinel blocks
# (`# ScoopBucket:CliCompletion:<cli>:BEGIN v1` / `:END`) give
# idempotent per-CLI replace/append semantics.
#
# All state-changing operations honour SupportsShouldProcess; the public
# Completions.ps1 entry point propagates -WhatIf / -Confirm.
# ============================================================================

# Curated native-completion map. Each entry is the command this helper runs
# to emit PowerShell registration source for the CLI. Add tools here as
# they prove out — blind probing of unknown CLIs is intentionally avoided.
$script:CliCompletionNativeMap = @{
    'gh'      = { gh completion -s powershell 2>$null }
    'rg'      = { rg --generate complete-powershell 2>$null }
    'bw'      = { bw completion --shell powershell 2>$null }
    'docker'  = { docker completion powershell 2>$null }
    'copilot' = { copilot completion powershell 2>$null }
    'gcloud'  = { gcloud --quiet --help-format=ps1 2>$null }  # gcloud ships its own; if this fails the CLI registers itself on shell init
    'scoop'   = $null  # scoop-completion module handles this separately; treated as PSCompletions fallback
}

# Sentinel patterns. Bumping the trailing version invalidates older blocks
# on the next force-refresh.
$script:CompletionSentinelVersion = 'v1'

function Test-IsElevated {
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    if (-not $IsWindows -and ($PSVersionTable.PSEdition -eq 'Core')) {
        # Non-Windows: assume elevated if running as root.
        return ((whoami) -eq 'root')
    }
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CompletionProfilePath {
    <#
    .SYNOPSIS
        Return the AllUsersAllHosts profile path. Throws if not writable;
        emits Write-Information and returns $null if the host has no
        AllUsersAllHosts profile (rare; tracked as a separate issue).
    .PARAMETER OverridePath
        Test hook: bypass $PROFILE.AllUsersAllHosts and admin checks.
        Used by Pester to redirect the helper to a sandbox file.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([string]$OverridePath)

    if ($OverridePath) { return $OverridePath }

    $target = $PROFILE.AllUsersAllHosts
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Information "Host has no AllUsersAllHosts profile path; completion registration skipped. Filed as follow-up." -InformationAction Continue
        return $null
    }
    if (-not (Test-IsElevated)) {
        throw "Completion registration requires an elevated PowerShell session (target: $target). Re-run from an Administrator prompt."
    }
    # Probe writability by ensuring the parent exists and we can open the
    # file for append. Don't actually write anything.
    $dir = Split-Path -Parent $target
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        catch { throw "Cannot create AllUsersAllHosts profile directory '$dir': $($_.Exception.Message)" }
    }
    try {
        $fs = [System.IO.File]::Open($target, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        $fs.Dispose()
    } catch {
        throw "AllUsersAllHosts profile '$target' is not writable: $($_.Exception.Message). Re-run elevated."
    }
    return $target
}

function Resolve-CliCompletionSource {
    <#
    .SYNOPSIS
        For a given CLI, return a hashtable describing how to register
        completion: @{ Source='Native'|'PSCompletions'|'Skipped';
                       Code=<powershell text or $null>;
                       PSCompletionsName=<name or $null> }.
    .DESCRIPTION
        Native curated map → PSCompletions catalog probe → Skipped.
        Catalog probe uses `psc list` if the module is loaded;
        otherwise treats every unknown CLI as a candidate (PSCompletions
        will simply error at registration time if it has no definition).
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cli)

    # Strategy 1: native curated map.
    if ($script:CliCompletionNativeMap.ContainsKey($Cli)) {
        $sb = $script:CliCompletionNativeMap[$Cli]
        if ($sb) {
            # Capture native output. If the CLI isn't installed, the
            # subshell errors and we fall through; we still emit a
            # guarded block so the profile re-evaluates on shell start.
            $native = $null
            try { $native = & $sb 2>$null | Out-String } catch { }
            if ($native -and $native.Trim()) {
                # Wrap with Get-Command guard so the profile is safe even
                # when the CLI later gets uninstalled.
                $guarded = "if (Get-Command $Cli -ErrorAction SilentlyContinue) {`r`n$native}"
                return @{ Source = 'Native'; Code = $guarded; PSCompletionsName = $null }
            }
        }
    }

    # Strategy 2: PSCompletions fallback.
    $pscModule = Get-Module -ListAvailable -Name PSCompletions | Select-Object -First 1
    if ($pscModule) {
        # Best-effort: try to add the completion now. If PSCompletions
        # has no definition for this CLI, the add call surfaces an error
        # which we suppress and treat as "skipped".
        try {
            Import-Module PSCompletions -ErrorAction Stop
            $listOutput = & psc list 2>$null | Out-String
            if ($listOutput -match "(?im)^\s*$([regex]::Escape($Cli))(\s|$)") {
                $code = "if (Get-Command psc -ErrorAction SilentlyContinue) {`r`n    Import-Module PSCompletions -ErrorAction SilentlyContinue`r`n}"
                return @{ Source = 'PSCompletions'; Code = $code; PSCompletionsName = $Cli }
            }
        } catch { }
    }

    return @{ Source = 'Skipped'; Code = $null; PSCompletionsName = $null }
}

function Read-CompletionProfileContent {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { return (Get-Content -Path $Path -Raw -Encoding UTF8) }
    return ''
}

function Set-CompletionProfileBlock {
    <#
    .SYNOPSIS
        Insert or replace a sentinel-delimited completion block for $Cli
        in the profile $Content. Returns the new content. Idempotent:
        identical inputs produce byte-identical output.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Block,
        [switch]$Force
    )
    $ver = $script:CompletionSentinelVersion
    $begin = "# ScoopBucket:CliCompletion:$Cli`:BEGIN $ver"
    $end   = "# ScoopBucket:CliCompletion:$Cli`:END"
    $pattern = "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:BEGIN \w+.*?^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:END\r?\n?"
    $newBlock = "$begin`r`n$Block`r`n$end`r`n"
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        if (-not $Force) { return $Content }  # preserve existing
        # String-concat (not regex Replace) so the new block can contain
        # unescaped $ / \ without being interpreted as substitution syntax.
        $before = $Content.Substring(0, $match.Index)
        $after  = $Content.Substring($match.Index + $match.Length)
        return $before + $newBlock + $after
    }
    # Append. Normalise trailing newlines to exactly one before the new block.
    $trimmed = $Content.TrimEnd("`r","`n")
    if ($trimmed) { return "$trimmed`r`n`r`n$newBlock" }
    return $newBlock
}

function Register-CliCompletion {
    <#
    .SYNOPSIS
        Register PowerShell tab-completion for a single CLI by embedding
        a sentinel-delimited block in the AllUsersAllHosts profile.
    .DESCRIPTION
        Native curated commands preferred; PSCompletions fallback. Idempotent.
        Honours -WhatIf / -Confirm via SupportsShouldProcess. Requires admin
        (throws otherwise) unless -ProfilePath overrides.
    .PARAMETER Cli
        Bare command name (e.g. 'gh').
    .PARAMETER Force
        Overwrite an existing block for the same CLI. Without -Force,
        existing blocks are preserved (no-op for already-registered CLIs).
    .PARAMETER ProfilePath
        Test hook: write to this file instead of AllUsersAllHosts.
        Bypasses the elevation check.
    .OUTPUTS
        PSCustomObject with Cli, Source (Native/PSCompletions/Skipped),
        Action (Added/Replaced/Preserved/Skipped/WhatIf), and ProfilePath.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [switch]$Force,
        [string]$ProfilePath
    )

    $target = Get-CompletionProfilePath -OverridePath $ProfilePath
    if (-not $target) {
        return [pscustomobject]@{
            Cli = $Cli; Source = 'Skipped'; Action = 'Skipped'; ProfilePath = $null
            Reason = 'No AllUsersAllHosts profile path available on this host.'
        }
    }

    $resolved = Resolve-CliCompletionSource -Cli $Cli
    if ($resolved.Source -eq 'Skipped') {
        return [pscustomobject]@{
            Cli = $Cli; Source = 'Skipped'; Action = 'Skipped'; ProfilePath = $target
            Reason = "No native completion command in curated map and PSCompletions has no definition for '$Cli'."
        }
    }

    # If PSCompletions, ask the module to add the binding now (idempotent
    # via -Force in PSCompletions's storage).
    if ($resolved.Source -eq 'PSCompletions') {
        $pscAction = "psc add $Cli" + ($(if ($Force) { ' (re-add)' } else { '' }))
        if ($PSCmdlet.ShouldProcess($Cli, $pscAction)) {
            try {
                Import-Module PSCompletions -ErrorAction Stop
                # `psc add` doesn't expose a -Force switch; re-running it
                # against an already-added CLI is a benign no-op, so a
                # single unconditional call covers both Force and no-Force
                # semantics for the PSCompletions side. The sentinel
                # block in the profile still respects -Force for replace
                # vs preserve.
                & psc add $Cli 2>$null | Out-Null
            } catch {
                Write-Warning "psc add $Cli failed: $($_.Exception.Message)"
            }
        }
    }

    $content = Read-CompletionProfileContent -Path $target
    $ver     = $script:CompletionSentinelVersion
    $pattern = "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:BEGIN \w+"
    $existed = [regex]::IsMatch($content, $pattern)
    if ($existed -and -not $Force) {
        return [pscustomobject]@{
            Cli = $Cli; Source = $resolved.Source; Action = 'Preserved'
            ProfilePath = $target; Reason = 'Existing block preserved; pass -Force to overwrite.'
        }
    }

    $shouldProcessAction = if ($existed) { "Replace completion block for '$Cli' ($($resolved.Source))" }
                           else         { "Add completion block for '$Cli' ($($resolved.Source))" }
    if (-not $PSCmdlet.ShouldProcess($target, $shouldProcessAction)) {
        return [pscustomobject]@{
            Cli = $Cli; Source = $resolved.Source; Action = 'WhatIf'
            ProfilePath = $target; Reason = '-WhatIf or -Confirm declined.'
        }
    }

    $newContent = Set-CompletionProfileBlock -Content $content -Cli $Cli -Block $resolved.Code -Force:$true
    # Atomic write: temp file + Move-Item ensures we never leave the
    # profile half-written on failure.
    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $newContent, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $target -Force

    return [pscustomobject]@{
        Cli = $Cli; Source = $resolved.Source
        Action = $(if ($existed) { 'Replaced' } else { 'Added' })
        ProfilePath = $target; Reason = $null
    }
}

function Install-PSCompletionsModule {
    <#
    .SYNOPSIS
        Idempotently ensure the PSCompletions PowerShell module is installed
        at AllUsers scope. Skip if already present.
    .PARAMETER Force
        Pass -Force to Install-Module for an unconditional refresh.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([switch]$Force)

    if (-not $Force -and (Get-Module -ListAvailable -Name PSCompletions)) {
        Write-Verbose 'PSCompletions module already installed; skipping.'
        return
    }
    if ($PSCmdlet.ShouldProcess('PSCompletions module', "Install-Module -Scope AllUsers$(if ($Force) { ' -Force' })")) {
        try {
            $params = @{ Name = 'PSCompletions'; Scope = 'AllUsers'; AllowClobber = $true; ErrorAction = 'Stop' }
            if ($Force) { $params['Force'] = $true }
            Install-Module @params
        } catch {
            Write-Warning "Install-Module PSCompletions failed: $($_.Exception.Message). PSCompletions fallback will be unavailable."
        }
    }
}

function Register-AllCliCompletions {
    <#
    .SYNOPSIS
        Enumerate every CLI on the machine (Get-Command -CommandType Application,
        de-duped by base name) and call Register-CliCompletion for each.
    .DESCRIPTION
        Idempotent. Default behaviour: only register CLIs that don't already
        have a profile block. Pass -Force to overwrite existing blocks.
        Returns the per-CLI result objects for the summary table.
    .PARAMETER Force
        Forwarded to Register-CliCompletion. Default $false (no -Force flag).
    .PARAMETER ProfilePath
        Test hook for Pester: redirect writes to a sandbox file.
    .PARAMETER Names
        Test hook: bypass Get-Command enumeration and use this list instead.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [switch]$Force,
        [string]$ProfilePath,
        [string[]]$Names
    )

    if (-not $Names) {
        $Names = Get-Command -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name -Unique |
            ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } |
            Sort-Object -Unique
    }

    $results = foreach ($n in $Names) {
        # Forward both Force and the parent's ShouldProcess preferences so
        # -WhatIf / -Confirm propagate through.
        Register-CliCompletion -Cli $n -Force:$Force -ProfilePath $ProfilePath `
            -WhatIf:$WhatIfPreference -Confirm:$false
    }

    # Summary
    $byAction = $results | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host "Completion registration summary: $($byAction -join ', ')"
    return @($results)
}
