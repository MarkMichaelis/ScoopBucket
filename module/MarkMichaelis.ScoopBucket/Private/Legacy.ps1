# Legacy helpers migrated from bucket/Utils.ps1.
#
# Top-level setup (resolving $env:SCOOP and dot-sourcing scoop's internal
# libraries) is wrapped in Initialize-ScoopEnvironment and invoked from
# MarkMichaelis.ScoopBucket.psm1 on module load. Other helpers are plain functions and
# the public ones are listed in MarkMichaelis.ScoopBucket.psd1's FunctionsToExport.
#
# Resolve-ScoopRoot, Test-IsElevated, Add-MachinePath and
# Update-PathFromRegistry live in PathUtilities.ps1 (not duplicated here).

# TODO: Generalize past hard-coded bucket owner.
$script:UserBucket = 'MarkMichaelis'

# Idempotency guard for Initialize-ScoopEnvironment. Stays $false until the
# three lightweight scoop libs (core / buckets / manifest) successfully
# dot-source. A failed init leaves the guard $false so callers can retry
# after the underlying scoop install is repaired.
$script:ScoopEnvironmentInitialized = $false

function Initialize-ScoopEnvironment {
    <#
    .SYNOPSIS
        Resolve $env:SCOOP defensively and dot-source scoop's lightweight
        internal libraries (`parse_app`, `Find-BucketDirectory`) into MODULE
        scope. Idempotent: re-entry is a cheap no-op once the guard flips.

        Invoked once with the dot-source operator from .psm1 so the inner
        `. $p` calls land in module scope (parse_app / Find-BucketDirectory
        are then resolvable by `scoop` / `Get-LocalBucket` wrappers). A
        plain (non-dot-sourced) call would land the inner functions in
        THIS function's local scope where they would evaporate on return.

        scoop-search.ps1 is intentionally excluded: its dot-source costs
        ~1.8s (it pulls in versions.ps1 + download.ps1) and is only needed
        by the `scoop search -PSCustomObject` branch. That branch lazily
        loads it via Initialize-ScoopSearchEnvironment on demand.

        On failure (e.g. a scoop lib missing or throwing), the guard is
        NOT flipped, so a later retry after the underlying install is
        repaired will run the dot-source again.
    #>
    [CmdletBinding()]
    param()

    if ($script:ScoopEnvironmentInitialized) { return }

    $resolved = Resolve-ScoopRoot
    if (-not $resolved) {
        Write-Verbose '$env:SCOOP not found and no scoop install detected; legacy scoop helpers will degrade.'
        return
    }
    $env:SCOOP = $resolved
    $currentScoopDirectory = "$env:SCOOP\apps\scoop\current"
    $required = @(
        'lib\core.ps1',
        'lib\buckets.ps1',
        'lib\manifest.ps1'
    )
    $missing = @()
    foreach ($rel in $required) {
        $p = Join-Path $currentScoopDirectory $rel
        if (Test-Path $p) {
            # *>$null suppresses every stream so library banners don't
            # leak into callers.
            . $p *>$null
        } else {
            $missing += $rel
        }
    }
    if ($missing.Count -gt 0) {
        # Leave the guard $false so a retry after the scoop install is
        # repaired re-attempts the dot-source (matches the throw-path
        # contract). Missing libs are not the same as a broken scoop and
        # may be transient (e.g. mid-install), so warn rather than throw.
        Write-Verbose "Initialize-ScoopEnvironment: missing scoop libs under '$currentScoopDirectory' ($($missing -join ', ')); guard left false for retry."
        return
    }
    # Only set the guard after every required file dot-sourced cleanly;
    # any throw above propagates and leaves the guard false
    # (retry-friendly).
    $script:ScoopEnvironmentInitialized = $true
}

function Initialize-ScoopSearchEnvironment {
    <#
    .SYNOPSIS
        Lazy loader for scoop-search.ps1. Dot-sources scoop-search.ps1
        (which itself pulls in lib\versions.ps1 + lib\download.ps1, ~1.8s
        total) into the CALLER's scope.

        Always invoked with the dot-source operator from the `scoop`
        wrapper's `search -PSCustomObject` branch so that `search_bucket`
        becomes resolvable for the remainder of that invocation. Each
        call re-loads (no module-scope guard) because we deliberately
        avoid permanently polluting module scope with the heavy
        scoop-search dependencies; sessions that never search never pay
        the cost.
    #>
    [CmdletBinding()]
    param()

    $resolved = Resolve-ScoopRoot
    if (-not $resolved) {
        Write-Verbose '$env:SCOOP not found; scoop-search lazy init skipped.'
        return
    }
    $p = Join-Path $resolved 'apps\scoop\current\libexec\scoop-search.ps1'
    if (Test-Path $p) {
        . $p *>$null
    }
}

function Test-Command {
    [CmdletBinding()]
    param([string]$command)
    return [bool](Get-Command $command -ErrorAction Ignore)
}

function Test-ChocolateyPackageInstalled {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageName)

    $installed = choco list $PackageName --local-only --no-progress | Where-Object {
        $_ -match "$PackageName\s.*"
    }
    Write-Output (@($installed).Count -gt 0)
}

function Test-ScoopPackageInstalled {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageName)

    $scoopOutput = scoop export $PackageName
    $installed = $scoopOutput | Where-Object {
        $_ -match "\s*$PackageName\s.*"
    }
    Write-Output (@($installed).Count -gt 0)
}

function choco {
    $installArgs = Get-InstallArgs @args
    if (
        ($installArgs.Action -eq 'install') `
        -and ($installArgs.Options -notcontains '-f') `
        -and ($installArgs.Options -notcontains '--force') `
        -and (Test-ChocolateyPackageInstalled $installArgs.Arg1)
    ) {
        Write-Warning "$($installArgs.Arg1) is already installed."
    } else {
        choco.exe @args
    }
}

function Get-LocalBucket {
    <#
    .SYNOPSIS
        List all local scoop buckets, with $script:UserBucket first.
    #>
    $bucketsdir = (Join-Path $env:SCOOP buckets)
    try {
        if ($bucketsdir -ne (Split-Path (Find-BucketDirectory).Trim('bucket') -Parent)) {
            Write-Warning 'Bucket directory does not match Find-BucketDirectory location.'
        }
    } catch {
        Write-Verbose "Find-BucketDirectory unavailable: $($_.Exception.Message)"
    }
    $buckets = (Get-ChildItem $bucketsdir -Directory).Name
    if ($script:UserBucket) {
        $buckets = , $script:UserBucket + ($buckets | Where-Object { $_ -ne $script:UserBucket })
    }
    Write-Output $buckets
}

<#
.SYNOPSIS
    Parse the arguments used on a command into options + sub-commands.
.DESCRIPTION
    Given a command, parse the original arguments into options, sub-commands,
    and the first non-option argument. Used by the `choco` and `scoop`
    wrappers to decide whether to short-circuit (e.g. skip a re-install when
    the package is already installed and no -f / --force option was given).
#>
class InstallArgs {
    [string[]]$OriginalArgs
    [string[]]$Options
    [string[]]$SubCommands
    [string]$Action
    [string]$Arg1

    InstallArgs([string[]]$OriginalArgs) {
        [string[]]$localSubCommands = $OriginalArgs | Where-Object { $_ -notlike '-*' }
        $this.OriginalArgs = $OriginalArgs
        $this.Options = $OriginalArgs | Where-Object { $_ -like '-*' }
        $this.SubCommands = $localSubCommands
        $this.Action = $localSubCommands | Select-Object -First 1
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
            # Make $script:UserBucket the priority.
            $null, $bucket, $null = parse_app $arg1
            if (-not $bucket) {
                scoop search $arg1 -PSCustomObject | Where-Object {
                    $_.name -match "^$args$"
                } | Where-Object {
                    $_.Bucket -eq $script:UserBucket
                } | ForEach-Object {
                    $index = [array]::indexof($localArgs, $_.name)
                    $localArgs[$index] = "$script:UserBucket/$arg1"
                }
            }
            scoop.ps1 @localArgs
        }
        'search' {
            if ($options -contains '-PSCustomObject') {
                # Dot-source scoop-search.ps1 into THIS function scope on
                # every call. It is excluded from the eager init because
                # it transitively pulls in versions.ps1 + download.ps1
                # (~1.8s) -- sessions that never `scoop search
                # -PSCustomObject` should not pay that cost on import.
                . Initialize-ScoopSearchEnvironment
                Get-LocalBucket | ForEach-Object {
                    $bucket = $_
                    search_bucket $_ $arg1 | ForEach-Object {
                        $_['Bucket'] = $bucket
                        Write-Output ([PSCustomObject]$_)
                    }
                }
            } else {
                scoop.ps1 @args
            }
        }
        Default {
            scoop.ps1 @args
        }
    }
}

function Get-Program {
    [CmdletBinding()]
    param([string]$Filter = '*')

    $ProgramRegistryKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'Microsoft.PowerShell.Core\Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Uninstall'

    $ProgramRegistryKeys | Get-ChildItem | Get-ItemProperty |
        Select-Object *, @{Name = 'Name'; Expression = {
                if (($_ | Get-Member 'DisplayName') -and $_.DisplayName) {
                    $_.DisplayName
                } else {
                    $_.PSChildName
                }
            }
        } | Where-Object { ($_.Name -Like $Filter) -or ($_.PSChildName -Like $Filter) }
}

function Import-ChocolateyModule {
    if (Test-Path env:ChocolateyInstall) {
        Import-Module (Resolve-Path -Path "$env:ChocolateyInstall\*\chocolateyInstaller.psm1").Path
        if (Test-Path Function:\Write-Host) {
            Remove-Item Function:Write-Host
        }
        $env:ChocolateyAllowEmptyChecksumsSecure = $true
        $env:ChocolateyAllowEmptyChecksums = $true
        $env:ChocolateyPackageFolder = "$env:ChocolateyInstall\Lib"
        Set-PackageSource -Name chocolatey -ProviderName Chocolatey -Trusted -Force
    } else {
        throw 'Chocolatey is not installed'
    }
}

function Install-WebDownloadOfZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][Alias('Uri')][string]$url,
        $UnzipLocation = "$env:ChocolateyInstall\lib\$PackageName"
    )

    Import-ChocolateyModule

    $originalChocolateyAllowEmptyChecksums = $env:ChocolateyAllowEmptyChecksums
    $originalChocolateyAllowEmptyChecksumsSecure = $env:ChocolateyAllowEmptyChecksumsSecure
    try {
        if (-not (Test-Path variable:\helpersPath)) {
            $setHelpersPath = $true
            $global:helpersPath = $env:ChocolateyInstall
        }
        $env:ChocolateyAllowEmptyChecksums = 'true'
        $env:ChocolateyAllowEmptyChecksumsSecure = 'true'
        Install-ChocolateyZipPackage -packageName $PackageName -url $url -unzipLocation $UnzipLocation -specificFolder ''
        Get-ChildItem $UnzipLocation *.exe | ForEach-Object { Install-BinFile -name TrayIt -path $_.FullName }
    } finally {
        if ($setHelpersPath) {
            Remove-Item variable:\global:helpersPath
        }
        $env:ChocolateyAllowEmptyChecksums = $originalChocolateyAllowEmptyChecksums
        $env:ChocolateyAllowEmptyChecksumsSecure = $originalChocolateyAllowEmptyChecksumsSecure
    }
}

function Install-WebDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('Uri')][string]$url,
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(ParameterSetName = 'CommandLine')][string]$arguments = $null,
        [Parameter(ParameterSetName = 'ScriptBlock')][ScriptBlock]$postDownloadScriptBlock,
        [Parameter(ParameterSetName = 'UnattendedSilentSwitchFinder',
            HelpMessage = 'Lookup the unattended silent switch for the setup program.')][switch]$ussf,
        [string]$installFileName = [System.Management.Automation.WildcardPattern]::Escape((Split-Path $url -Leaf)),
        [switch]$forceDownload
    )

    $tempPath = Get-TempPath

    if ([IO.Path]::GetExtension($installFileName) -eq '.zip') {
        Install-WebDownloadOfZip -Uri $url -packageName $PackageName
    } else {
        $installFileName = Join-Path $tempPath $installFileName

        if ($forceDownload -or ($installFileName -eq 'Setup.exe') -or -not (Test-Path $installFileName)) {
            Invoke-WebRequest $url -OutFile $installFileName
        }

        if ($ussf) {
            ussf $installFileName
        } else {
            if ([string]::IsNullOrWhiteSpace($PsCmdlet.ParameterSetName) -or ($PsCmdlet.ParameterSetName -eq 'CommandLine')) {
                $postDownloadScriptBlock = [ScriptBlock] {
                    $process = Start-Process $installFileName $arguments -PassThru -wait
                    return $process.ExitCode
                }
            }
        }
        Write-Output (Invoke-Command $postDownloadScriptBlock)
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
#>
function Install-LocalManifest {
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

    $bucketSwapped = $false
    $originalSource = $null
    if ($BucketName) {
        $bucketDir = Join-Path $env:USERPROFILE "scoop\buckets\$BucketName"
        $localUrl = ([Uri]$repoRoot).AbsoluteUri
        if (Test-Path $bucketDir) {
            $safeDir = ($bucketDir -replace '\\', '/')
            $null = git config --global --add safe.directory $safeDir 2>&1
            try {
                $gitOut = git -C $bucketDir config --get remote.origin.url 2>$null
                if ($gitOut) { $originalSource = $gitOut.Trim() }
            } catch { }
        }
        $alreadyLocal = $originalSource -and (
            $originalSource -eq $localUrl -or
            $originalSource.TrimEnd('/', '\') -eq $repoRoot.TrimEnd('/', '\')
        )
        if (-not $alreadyLocal) {
            if (Test-Path $bucketDir) {
                $null = scoop.ps1 bucket rm $BucketName 2>&1
            }
            $null = scoop.ps1 bucket add $BucketName $localUrl 2>&1
            $bucketSwapped = $true
            $null = git config --global --add safe.directory $safeDir 2>&1
        }
    }

    $tempManifest = Join-Path $env:TEMP (Split-Path -Leaf $ManifestPath)
    $appName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
    $previousLocalRepo = $env:SCOOPBUCKET_LOCAL_REPO
    try {
        $env:SCOOPBUCKET_LOCAL_REPO = $repoRoot
        scoop.ps1 hold scoop | Out-Null
        $null = scoop.ps1 uninstall $appName 2>&1
        $manifest | ConvertTo-Json -Depth 20 | Out-File -FilePath $tempManifest -Encoding UTF8
        scoop.ps1 install $tempManifest
        $scoopInstallExit = $LASTEXITCODE
        if ($scoopInstallExit -eq 0 -and $BucketName) {
            Update-LocalManifestInstallMetadata -AppName $appName -BucketName $BucketName -ErrorAction SilentlyContinue
        }
    } finally {
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
    Repair an app's ~/scoop/apps/<App>/current/install.json and manifest.json
    after a working-copy `Install-LocalManifest` install.
.DESCRIPTION
    `Install-LocalManifest` runs `scoop install <temp manifest>` to test a
    working-copy manifest before pushing. Scoop records the install with an
    empty `bucket` field (the install came from a file path, not a registered
    bucket) and caches the rewritten `url[]` entries pointing at the local
    working-copy directory. Net effect: `scoop update <App>` errors with
    "couldn't find manifest for '<App>'", and the cached manifest's url[]
    no longer matches master.

    This helper:
      * Sets install.json.bucket = $BucketName so `scoop update` resolves.
      * Restores canonical https://raw.githubusercontent.com/.../master/...
        URLs in the cached manifest.json so future re-installs/updates fetch
        from the bucket, not the local file path.

    Both ~/scoop/apps/<App>/current/{install,manifest}.json and (if the
    version directory exists separately) ~/scoop/apps/<App>/<version>/{install,manifest}.json
    are patched defensively. `current` is normally a junction to the
    version directory so patching one effectively patches both; we touch
    both explicitly in case a Scoop release ever changes that.

    All file writes are wrapped in try/catch: install.json is an internal
    Scoop record (no public schema contract), so any failure should be
    non-fatal — `scoop update` will keep returning the original error and
    the user can fall back to `scoop install MarkMichaelis/<App>` to relink.

    See issue #62.
#>
function Update-LocalManifestInstallMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$BucketName,
        [string]$ScoopRoot
    )

    if (-not $ScoopRoot) {
        $ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    }
    $appRoot = Join-Path $ScoopRoot "apps\$AppName"
    if (-not (Test-Path $appRoot)) {
        Write-Verbose "Update-LocalManifestInstallMetadata: $appRoot does not exist; nothing to patch."
        return
    }

    # Collect candidate dirs: current/, plus any version-named sibling
    # directories so we hit both the junction target and the original
    # version dir on the off chance they aren't the same inode.
    $dirs = [System.Collections.Generic.List[string]]::new()
    $currentDir = Join-Path $appRoot 'current'
    if (Test-Path $currentDir) { $null = $dirs.Add($currentDir) }
    Get-ChildItem -Path $appRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'current' } |
        ForEach-Object { $null = $dirs.Add($_.FullName) }

    foreach ($dir in $dirs) {
        $installJsonPath = Join-Path $dir 'install.json'
        if (Test-Path $installJsonPath) {
            try {
                $installJson = Get-Content -LiteralPath $installJsonPath -Raw -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop
                if ($installJson.PSObject.Properties.Name -contains 'bucket') {
                    $installJson.bucket = $BucketName
                } else {
                    $installJson | Add-Member -NotePropertyName 'bucket' -NotePropertyValue $BucketName -Force
                }
                $installJson | ConvertTo-Json -Depth 20 |
                    Out-File -LiteralPath $installJsonPath -Encoding UTF8 -ErrorAction Stop
                Write-Verbose "Patched bucket field in $installJsonPath -> $BucketName"
            } catch {
                Write-Warning "Update-LocalManifestInstallMetadata: failed to patch '$installJsonPath': $($_.Exception.Message)"
            }
        }

        $manifestJsonPath = Join-Path $dir 'manifest.json'
        if (Test-Path $manifestJsonPath) {
            try {
                $manifestJson = Get-Content -LiteralPath $manifestJsonPath -Raw -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop
                if ($manifestJson.url) {
                    $canonicalPrefix = "https://raw.githubusercontent.com/$BucketName/ScoopBucket/master/bucket"
                    $manifestJson.url = @(
                        $manifestJson.url | ForEach-Object {
                            # Strip any file:// or local path prefix and rebuild against canonical master URL.
                            $leaf = [System.IO.Path]::GetFileName(([Uri]$_).LocalPath)
                            if (-not $leaf) { $leaf = [System.IO.Path]::GetFileName($_) }
                            "$canonicalPrefix/$leaf"
                        }
                    )
                    $manifestJson | ConvertTo-Json -Depth 20 |
                        Out-File -LiteralPath $manifestJsonPath -Encoding UTF8 -ErrorAction Stop
                    Write-Verbose "Restored canonical url[] in $manifestJsonPath"
                }
            } catch {
                Write-Warning "Update-LocalManifestInstallMetadata: failed to patch '$manifestJsonPath': $($_.Exception.Message)"
            }
        }
    }
}

<#
.SYNOPSIS
    Install a MarkMichaelis bucket app, preferring a working-copy manifest
    when running under Install-LocalManifest.
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
# ============================================================================

$script:CompletionSentinelVersion = 'v1'

function Get-CompletionProfilePath {
    [OutputType([string])]
    [CmdletBinding()]
    param([string]$OverridePath)

    if ($OverridePath) { return $OverridePath }

    $target = $PROFILE.AllUsersAllHosts
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Information 'Host has no AllUsersAllHosts profile path; completion registration skipped.' -InformationAction Continue
        return $null
    }
    if (-not (Test-IsElevated)) {
        throw "Completion registration requires an elevated PowerShell session (target: $target). Re-run from an Administrator prompt."
    }
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
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [scriptblock]$NativeCommand
    )

    if ($NativeCommand) {
        $native = $null
        try { $native = & $NativeCommand 2>$null | Out-String } catch { }
        if ($native -and $native.Trim()) {
            $guarded = "if (Get-Command $Cli -ErrorAction SilentlyContinue) {`r`n$native}"
            return @{ Source = 'Native'; Code = $guarded; PSCompletionsName = $null }
        }
    }

    $pscModule = Get-Module -ListAvailable -Name PSCompletions | Select-Object -First 1
    if ($pscModule) {
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
    if (Test-Path $Path) {
        # Get-Content -Raw returns $null for an empty file; coalesce so
        # callers can pass the result straight to [regex]::IsMatch
        # without "Value cannot be null" exceptions.
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ($null -eq $raw) { return '' }
        return $raw
    }
    return ''
}

function Set-CompletionProfileBlock {
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
    $end = "# ScoopBucket:CliCompletion:$Cli`:END"
    $pattern = "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:BEGIN \w+.*?^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:END\r?\n?"
    $newBlock = "$begin`r`n$Block`r`n$end`r`n"
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        if (-not $Force) { return $Content }
        $before = $Content.Substring(0, $match.Index)
        $after = $Content.Substring($match.Index + $match.Length)
        return $before + $newBlock + $after
    }
    $trimmed = $Content.TrimEnd("`r", "`n")
    if ($trimmed) { return "$trimmed`r`n`r`n$newBlock" }
    return $newBlock
}

function Invoke-PscAdd {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cli)
    & psc add $Cli 2>$null | Out-Null
}

function Invoke-PscRemove {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cli)
    try { & psc remove $Cli 2>$null | Out-Null } catch { }
}

function Test-PSCompletionsHandler {
    <#
    .SYNOPSIS
        Internal: validate that a freshly-added PSCompletions entry for
        `$Cli` doesn't crash tab completion. Runs in a fresh pwsh
        -NoProfile child runspace so it doesn't poison the caller's
        session. Returns @{ Ok = $bool; Reason = <string> }.
    .DESCRIPTION
        Defensive guard for #179. PSCompletions is third-party content
        and has historically shipped completions whose PSReadLine key
        handler references properties that don't exist on the object
        PSReadLine actually passes (e.g. lowercase `.buffer`). When
        that happens the only feedback the user gets is a broken Tab
        key in every shell after the next profile reload — extremely
        difficult to diagnose. This probe attempts a synthetic
        CommandCompletion against `<cli> ` and treats any error as a
        validation failure so the caller can roll back.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cli)

    $pwsh = $null
    try { $pwsh = (Get-Process -Id $PID).Path } catch { }
    if (-not $pwsh) { $pwsh = 'pwsh' }

    $probe = @"
`$ErrorActionPreference = 'SilentlyContinue'
try { Import-Module PSReadLine -Force -ErrorAction Stop } catch { }
try { Import-Module PSCompletions -Force -ErrorAction Stop } catch {
    Write-Output ('__SBVAL_ERR__' + `$_.Exception.Message); return
}
`$Error.Clear()
try {
    `$line = '$Cli '
    [void][System.Management.Automation.CommandCompletion]::CompleteInput(`$line, `$line.Length, `$null)
} catch {
    Write-Output ('__SBVAL_ERR__' + `$_.Exception.Message); return
}
if (`$Error.Count) {
    `$msgs = (`$Error | ForEach-Object { `$_.Exception.Message } | Select-Object -Unique) -join '; '
    Write-Output ('__SBVAL_ERR__' + `$msgs); return
}
Write-Output '__SBVAL_OK__'
"@

    $safe = ($Cli -replace '[^A-Za-z0-9_.-]','_')
    $tmp = Join-Path $env:TEMP "ScoopBucket-pscval-$safe-$PID.ps1"
    try {
        Set-Content -Path $tmp -Value $probe -Encoding UTF8 -WhatIf:$false
        $out = & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>$null | Out-String
        if ($out -match '__SBVAL_ERR__(.+)') {
            return [pscustomobject]@{ Ok = $false; Reason = $Matches[1].Trim() }
        }
        if ($out -match '__SBVAL_OK__') {
            return [pscustomobject]@{ Ok = $true; Reason = $null }
        }
        return [pscustomobject]@{ Ok = $false; Reason = "PSCompletions validation produced no verdict for '$Cli'." }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message }
    } finally {
        Remove-Item -Path $tmp -ErrorAction Ignore
    }
}

function Register-CliCompletion {
    <#
    .SYNOPSIS
        Register PowerShell tab-completion for a single CLI by embedding
        a sentinel-delimited block in the AllUsersAllHosts profile.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [scriptblock]$NativeCommand,
        [switch]$Force,
        [string]$ProfilePath
    )

    $target = Get-CompletionProfilePath -OverridePath $ProfilePath
    if (-not $target) {
        return [pscustomobject]@{
            Cli         = $Cli; Source = 'Skipped'; Action = 'Skipped'; ProfilePath = $null
            Reason      = 'No AllUsersAllHosts profile path available on this host.'
        }
    }

    $content = Read-CompletionProfileContent -Path $target
    $existed = [regex]::IsMatch($content, "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:BEGIN \w+")
    if ($existed -and -not $Force) {
        return [pscustomobject]@{
            Cli         = $Cli; Source = 'Preserved'; Action = 'Preserved'
            ProfilePath = $target; Reason = 'Existing block preserved; pass -Force to overwrite.'
        }
    }

    $resolveSplat = @{ Cli = $Cli }
    if ($NativeCommand) { $resolveSplat['NativeCommand'] = $NativeCommand }
    $resolved = Resolve-CliCompletionSource @resolveSplat
    if ($resolved.Source -eq 'Skipped') {
        $reason = if ($NativeCommand) {
            "Native command produced no output for '$Cli' and PSCompletions has no catalog entry."
        } else {
            "No -NativeCommand supplied and PSCompletions has no catalog entry for '$Cli'."
        }
        if ($NativeCommand) {
            Write-Warning "Register-CliCompletion: $reason"
        }
        return [pscustomobject]@{
            Cli         = $Cli; Source = 'Skipped'; Action = 'Skipped'; ProfilePath = $target
            Reason      = $reason
        }
    }

    if ($resolved.Source -eq 'PSCompletions') {
        $pscAction = "psc add $Cli" + ($(if ($Force) { ' (re-add)' } else { '' }))
        if ($PSCmdlet.ShouldProcess($Cli, $pscAction)) {
            try {
                Import-Module PSCompletions -ErrorAction Stop
                Invoke-PscAdd -Cli $Cli
            } catch {
                Write-Warning "psc add $Cli failed: $($_.Exception.Message)"
            }

            # #179: validate the freshly-added PSCompletions handler in a
            # child runspace. If CommandCompletion errors (e.g. the handler
            # references a property the input object doesn't expose, as has
            # happened with several PSCompletions catalog entries), roll
            # the add back via `psc remove` and report Action=Failed instead
            # of polluting the user's profile.
            $validation = Test-PSCompletionsHandler -Cli $Cli
            if (-not $validation.Ok) {
                Write-Warning "Register-CliCompletion: PSCompletions handler for '$Cli' failed validation: $($validation.Reason). Rolling back."
                Invoke-PscRemove -Cli $Cli
                return [pscustomobject]@{
                    Cli         = $Cli; Source = 'PSCompletions'; Action = 'Failed'
                    ProfilePath = $target; Reason = $validation.Reason
                }
            }
        }
    }

    $shouldProcessAction = if ($existed) { "Replace completion block for '$Cli' ($($resolved.Source))" }
                          else { "Add completion block for '$Cli' ($($resolved.Source))" }
    if (-not $PSCmdlet.ShouldProcess($target, $shouldProcessAction)) {
        return [pscustomobject]@{
            Cli         = $Cli; Source = $resolved.Source; Action = 'WhatIf'
            ProfilePath = $target; Reason = '-WhatIf or -Confirm declined.'
        }
    }

    $newContent = Set-CompletionProfileBlock -Content $content -Cli $Cli -Block $resolved.Code -Force:$true
    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $newContent, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $target -Force

    return [pscustomobject]@{
        Cli         = $Cli; Source = $resolved.Source
        Action      = $(if ($existed) { 'Replaced' } else { 'Added' })
        ProfilePath = $target; Reason = $null
    }
}

function Install-PSCompletionsModule {
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

function Get-BucketCliName {
    <#
    .SYNOPSIS
        Internal: union of CLI command names declared by every bundle's
        [Package] objects (excluding those with Completion='none').

        Used as the default scope for Register-AllCliCompletions so we
        only register completions for the CLIs the bucket actually
        manages — not every executable on PATH (#180).
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param([string]$BucketPath)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $pkgArgs = @{}
    if ($BucketPath) { $pkgArgs['BucketPath'] = $BucketPath }
    $packages = @()
    try {
        $packages = Get-Package @pkgArgs -ErrorAction Stop
    } catch {
        Write-Warning "Get-BucketCliName: Get-Package failed: $($_.Exception.Message)"
    }
    foreach ($pkg in $packages) {
        # Skip packages that explicitly opt out of completion registration.
        if ($pkg.Completion -and ([string]$pkg.Completion).ToLowerInvariant() -eq 'none') { continue }
        foreach ($cli in @($pkg.CliCommands)) {
            if ($cli) { [void]$set.Add([string]$cli) }
        }
    }
    return @($set | Sort-Object)
}

function Register-AllCliCompletions {
    <#
    .SYNOPSIS
        Register tab-completion for CLIs declared by this bucket's
        bundles (default), an explicit -Names list, or every executable
        on PATH (-IncludeAllPath).

    .DESCRIPTION
        Default scope is the union of `CliCommands` across every
        [Package] returned by Get-Package whose `Completion` field is
        not 'none'. This avoids the surprising and slow behavior
        of sweeping every binary on PATH and registering PSCompletions
        entries for tools the user never asked about (#180).

        -IncludeAllPath restores the legacy PATH-sweep behavior for
        power users who want completions registered for every CLI
        they happen to have installed.

        -Names <subset> overrides scope entirely.

    .PARAMETER Force
        Replace existing sentinel-delimited completion blocks instead
        of preserving them.

    .PARAMETER ProfilePath
        Override the AllUsersAllHosts profile target (testing).

    .PARAMETER Names
        Explicit CLI names. When supplied, neither bucket discovery
        nor PATH sweep runs.

    .PARAMETER IncludeAllPath
        Opt into the legacy PATH sweep: enumerate every
        `Get-Command -CommandType Application` binary and try to
        register completion for each.

    .PARAMETER BucketPath
        Override the auto-detected bucket directory used when
        discovering CLIs from declared packages.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [switch]$Force,
        [string]$ProfilePath,
        [string[]]$Names,
        [switch]$IncludeAllPath,
        [string]$BucketPath
    )

    $scope = 'Bucket'
    if ($Names) {
        $scope = 'Explicit'
    } elseif ($IncludeAllPath) {
        $scope = 'PathSweep'
        $Names = Get-Command -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name -Unique |
            ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } |
            Sort-Object -Unique
    } else {
        $bucketArgs = @{}
        if ($BucketPath) { $bucketArgs['BucketPath'] = $BucketPath }
        $Names = Get-BucketCliName @bucketArgs
        if (-not $Names) {
            Write-Warning "Register-AllCliCompletions: no bucket-declared CLIs found. Pass -Names <cli...> or -IncludeAllPath to scan PATH."
            return @()
        }
    }

    Write-Verbose "Register-AllCliCompletions: scope=$scope, registering $($Names.Count) CLI(s)."

    $results = foreach ($n in $Names) {
        Register-CliCompletion -Cli $n -Force:$Force -ProfilePath $ProfilePath `
            -WhatIf:$WhatIfPreference -Confirm:$false
    }

    $byAction = $results | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host "Completion registration summary [scope=$scope]: $($byAction -join ', ')"
    return @($results)
}

function Invoke-CliCompletionsSweep {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [switch]$Force,
        [string]$ProfilePath,
        [string[]]$Names,
        [switch]$IncludeAllPath,
        [string]$BucketPath
    )

    Write-Host 'Configuring PowerShell tab completion for installed CLI tools...'

    Install-PSCompletionsModule -Force:$Force -WhatIf:$WhatIfPreference

    $splat = @{ Force = [bool]$Force }
    if ($ProfilePath) { $splat['ProfilePath'] = $ProfilePath }
    if ($Names) { $splat['Names'] = $Names }
    if ($IncludeAllPath) { $splat['IncludeAllPath'] = $true }
    if ($BucketPath) { $splat['BucketPath'] = $BucketPath }

    $results = Register-AllCliCompletions @splat -WhatIf:$WhatIfPreference

    if ($results) {
        $results |
            Sort-Object Source, Cli |
            Format-Table -AutoSize Cli, Source, Action, Reason |
            Out-String |
            Write-Host
    }

    return @($results)
}
