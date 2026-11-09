# Hooks for the DbxProvider package in ClientBasePackages (#509).
#
# DbxProvider (github.com/MarkMichaelis/DbxProvider) is a PowerShell module
# that mounts Dropbox as a PSDrive. It ships as a GitHub release zip, so the
# package is Installer='custom':
#
#   Install-DbxProviderModule  -- CustomInstallScript: put the latest release
#                                 in the user's module path.
#   Set-DbxDriveProfile        -- ConfigScript: write the lazy `Dbx:` block
#                                 into the user's profile.
#
# Both are per-user: they resolve MyDocuments and $PROFILE for the account
# running the install. Under SYSTEM they skip with a warning rather than
# installing into systemprofile.
#
# The one-time Dropbox sign-in is deliberately NOT automated: it opens a
# browser and waits, which would hang unattended runs (CI, the post-Windows-
# Update task). Set-DbxDriveProfile prints a reminder instead.

$script:DbxProviderRepo = 'MarkMichaelis/DbxProvider'

function Test-DbxRunningAsSystem {
    $IsWindows -and [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

function Install-DbxProviderModule {
    <#
    .SYNOPSIS
        Install the latest DbxProvider release into the user's module path.

    .DESCRIPTION
        Extracts DbxProvider-<version>.zip from the latest GitHub release into
        <ModulesRoot>\DbxProvider\<version>. When that version's manifest is
        already there it downloads nothing, so it is cheap to rerun -- the
        package uses UpdateMode='Reinstall', which runs this on every update.

        If GitHub can't be reached (offline, rate-limited) and some version is
        already installed, it warns and keeps that version instead of failing
        the package. Set $env:GITHUB_TOKEN or $env:GH_TOKEN to authenticate the
        release lookup and avoid the anonymous rate limit.

        Older versions are left in place: PowerShell loads the highest one,
        and a running pwsh may still hold the older DLL open.

        The zip is extracted to a staging folder and moved into place only
        once it is known to contain DbxProvider.psd1, so a failed download
        never leaves a half-populated version folder behind.

    .PARAMETER ModulesRoot
        Module root to install under. Defaults to the CurrentUser module path
        for PowerShell 7 (<MyDocuments>\PowerShell\Modules), resolved through
        the shell folder so a OneDrive-redirected Documents works.

    .PARAMETER Release
        Test hook: a GitHub release object (tag_name, assets[].name,
        assets[].browser_download_url). Defaults to the repo's latest release.
    #>
    [CmdletBinding()]
    param(
        [string]$ModulesRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'),
        [object]$Release
    )

    if (Test-DbxRunningAsSystem) {
        Write-Warning 'DbxProvider installs per user; skipping under the SYSTEM account. Rerun as the user who will use Dbx:.'
        return
    }

    $moduleDir = Join-Path $ModulesRoot 'DbxProvider'
    $installed = @(Get-ChildItem -LiteralPath $moduleDir -Directory -ErrorAction Ignore |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'DbxProvider.psd1') })

    if (-not $Release) {
        $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'MarkMichaelis.ScoopBucket' }
        $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
        if ($token) { $headers.Authorization = "Bearer $token" }
        try {
            $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:DbxProviderRepo/releases/latest" `
                -Headers $headers -ErrorAction Stop
        }
        catch {
            if ($installed) {
                Write-Warning "Could not check GitHub for a newer DbxProvider ($($_.Exception.Message)); keeping installed version $($installed.Name -join ', ')."
                return
            }
            throw "Could not read the latest DbxProvider release from GitHub: $($_.Exception.Message)"
        }
    }

    $tag = [string]$Release.tag_name
    $version = $tag -replace '^v', ''
    $parsed = $null
    if (-not [version]::TryParse($version, [ref]$parsed)) {
        throw "DbxProvider release tag '$tag' is not a version (expected v<major>.<minor>.<patch>)."
    }
    $target = Join-Path $moduleDir $version

    if (Test-Path -LiteralPath (Join-Path $target 'DbxProvider.psd1')) {
        Write-Verbose "DbxProvider $version is already installed at $target."
        return
    }

    $assetName = "DbxProvider-$version.zip"
    $asset = @($Release.assets) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) {
        throw "DbxProvider release '$tag' has no '$assetName' asset."
    }

    New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
    $staging = Join-Path $moduleDir ".staging-$([guid]::NewGuid().ToString('N'))"
    $zip = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString('N'))-$assetName"
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
        if (-not (Test-Path -LiteralPath (Join-Path $staging 'DbxProvider.psd1'))) {
            throw "'$assetName' does not contain DbxProvider.psd1 at its root."
        }
        # A version folder without a manifest is the leftover of an earlier
        # failed install; replace it.
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Move-Item -LiteralPath $staging -Destination $target
        Write-Host "Installed DbxProvider $version to $target."
    }
    finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction Ignore
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore }
    }

    $onPath = ($env:PSModulePath -split [IO.Path]::PathSeparator) |
        Where-Object { $_ -and ($_.TrimEnd('\', '/') -ieq $ModulesRoot.TrimEnd('\', '/')) }
    if (-not $onPath) {
        Write-Warning "$ModulesRoot is not on PSModulePath, so 'Import-Module DbxProvider' will not find it."
    }
}

function Set-DbxDriveProfile {
    <#
    .SYNOPSIS
        Write the lazy `Dbx:` block into the user's PowerShell profile.

    .DESCRIPTION
        Writes a block delimited by `# ScoopBucket:DbxDrive:BEGIN <ver>` and
        `# ScoopBucket:DbxDrive:END`, replacing any earlier copy in place and
        rewriting the file only when its content changes. A rerun leaves the
        profile byte-identical. The profile keeps its encoding (including a
        BOM) and its line endings.

        If a BEGIN marker has no matching END (a hand edit), it warns and
        leaves the profile alone rather than guessing where the block ends.

        The block only defines a global `Dbx:` function. The first time it
        runs in a session it imports DbxProvider and calls
        `Connect-Dropbox -DriveName Dbx`, which reuses the refresh token saved
        under %LOCALAPPDATA%\DbxProvider -- no browser. Nothing runs at
        profile load, so shell startup makes no network call.

        When no saved credential exists, prints a one-line reminder to sign in
        once on this machine.

    .PARAMETER ProfilePath
        Profile to edit. Defaults to $PROFILE.CurrentUserAllHosts, which every
        PowerShell 7 host loads for this user.

    .PARAMETER CredentialPath
        Test hook: DbxProvider's saved-credential file, checked only to decide
        whether to print the sign-in reminder.
    #>
    [CmdletBinding()]
    param(
        [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,
        [string]$CredentialPath = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'DbxProvider\credentials.json' })
    )

    if (Test-DbxRunningAsSystem) {
        Write-Warning 'The Dbx: profile block is per user; skipping under the SYSTEM account.'
        return
    }
    if (-not $ProfilePath) {
        Write-Warning 'No CurrentUserAllHosts profile path for this account; skipping the Dbx: profile block.'
        return
    }

    # Read with BOM detection so the rewrite keeps the file's encoding.
    $content = ''
    $encoding = [Text.UTF8Encoding]::new($false)
    if (Test-Path -LiteralPath $ProfilePath) {
        $reader = [IO.StreamReader]::new($ProfilePath, $encoding, $true)
        try {
            $content = $reader.ReadToEnd()
            $encoding = $reader.CurrentEncoding
        } finally { $reader.Dispose() }
    }

    $nl = if ($content -match "`r`n" -or $content -notmatch "`n") { "`r`n" } else { "`n" }

    $sentinelVersion = 'v1'
    $block = @(
        "# ScoopBucket:DbxDrive:BEGIN $sentinelVersion"
        '# Dbx: connects the saved Dropbox account on first use (DbxProvider).'
        '# Lazy, so shell startup makes no network call. Sign in once per machine:'
        '#   Connect-Dropbox -DriveName Dbx'
        'function global:Dbx: {'
        '    if (-not (Get-PSDrive -Name Dbx -ErrorAction Ignore)) {'
        '        Import-Module DbxProvider -ErrorAction Stop'
        '        Connect-Dropbox -DriveName Dbx | Out-Null'
        '    }'
        "    Set-Location -LiteralPath 'Dbx:\'"
        '}'
        '# ScoopBucket:DbxDrive:END'
    ) -join $nl
    $block += $nl

    $pattern = '(?ms)^# ScoopBucket:DbxDrive:BEGIN \w+.*?^# ScoopBucket:DbxDrive:END[^\S\r\n]*\r?\n?'
    $match = [regex]::Match($content, $pattern)
    $beginCount = [regex]::Matches($content, '(?m)^# ScoopBucket:DbxDrive:BEGIN').Count
    $endCount   = [regex]::Matches($content, '(?m)^# ScoopBucket:DbxDrive:END').Count
    if ($beginCount -ne $endCount) {
        Write-Warning "$ProfilePath has a '# ScoopBucket:DbxDrive:BEGIN' line without a matching END (or the reverse); leaving it unchanged. Fix or remove the markers and rerun."
        return
    }

    $updated = if ($match.Success) {
        $content.Substring(0, $match.Index) + $block + $content.Substring($match.Index + $match.Length)
    } else {
        $trimmed = $content.TrimEnd("`r", "`n")
        if ($trimmed) { "$trimmed$nl$nl$block" } else { $block }
    }

    if ($updated -cne $content) {
        $dir = Split-Path -Parent $ProfilePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($ProfilePath, $updated, $encoding)
        Write-Verbose "Wrote the Dbx: block to $ProfilePath."
    }

    if (-not ($CredentialPath -and (Test-Path -LiteralPath $CredentialPath))) {
        Write-Host 'DbxProvider: sign in to Dropbox once on this machine with: Connect-Dropbox -DriveName Dbx'
    }
}
