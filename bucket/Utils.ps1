
# TODO: Generalize
$UserBucket = "MarkMichaelis"

if(!$env:SCOOP -and (test-path "$env:ProgramData\scoop\apps\scoop\current")) {
    $env:SCOOP = "$env:ProgramData\scoop"
}

if($env:SCOOP) {
    $currentScoopDirectory = "$env:SCOOP\apps\scoop\current"
    . (Join-Path $currentScoopDirectory 'libexec\scoop-search.ps1') > $null
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$LocalBucketRoot = (Split-Path -Parent $ManifestPath),
        [AllowNull()][string]$BucketName = 'MarkMichaelis'
    )

    if (-not (Test-Path $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }

    # Resolve to absolute paths so the regex substitution produces a valid
    # file:// URI. [Uri]::AbsoluteUri returns empty for relative paths.
    $ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
    if (-not $PSBoundParameters.ContainsKey('LocalBucketRoot')) {
        $LocalBucketRoot = Split-Path -Parent $ManifestPath
    } else {
        $LocalBucketRoot = (Resolve-Path -LiteralPath $LocalBucketRoot).Path
    }
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

            # Rewrite url[] entries in every manifest in the cloned bucket so
            # that nested `scoop install MarkMichaelis/<App>` calls (e.g. from
            # AIAgents.ps1's installer script) also resolve unpushed .ps1 files
            # from the working copy. Modifies the clone only.
            $clonedBucketDir = Join-Path $bucketDir 'bucket'
            if (Test-Path $clonedBucketDir) {
                Get-ChildItem $clonedBucketDir -Filter '*.json' | ForEach-Object {
                    try {
                        $sub = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    } catch { return }
                    if (-not $sub.url) { return }
                    $changed = $false
                    $sub.url = @(
                        $sub.url | ForEach-Object {
                            $r = $_ -replace `
                                'https://raw\.githubusercontent\.com/MarkMichaelis/ScoopBucket/master/bucket', `
                                $LocalBucketRoot
                            if ($r -ne $_) { $changed = $true }
                            ([Uri]$r).AbsoluteUri
                        }
                    )
                    if ($changed) {
                        $sub | ConvertTo-Json -Depth 20 | Set-Content -Path $_.FullName -Encoding UTF8
                    }
                }
            }
        }
    }

    $tempManifest = Join-Path $env:TEMP (Split-Path -Leaf $ManifestPath)
    $appName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
    try {
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
        if ($bucketSwapped) {
            $null = scoop.ps1 bucket rm $BucketName 2>&1
            if ($originalSource) {
                $null = scoop.ps1 bucket add $BucketName $originalSource 2>&1
            }
        }
    }
}
