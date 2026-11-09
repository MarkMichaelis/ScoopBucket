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
# The one-time Dropbox sign-in is deliberately NOT automated: it opens a
# browser and waits, which would hang unattended runs (CI, the post-Windows-
# Update task). Set-DbxDriveProfile prints a reminder instead.

$script:DbxProviderRepo = 'MarkMichaelis/DbxProvider'

function Install-DbxProviderModule {
    <#
    .SYNOPSIS
        Install the latest DbxProvider release into the user's module path.

    .DESCRIPTION
        Extracts DbxProvider-<version>.zip from the latest GitHub release into
        <ModulesRoot>\DbxProvider\<version>. When that version's manifest is
        already there it downloads nothing, so it is cheap to rerun -- the
        package uses UpdateMode='Reinstall', which runs this on every update.

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

    if (-not $Release) {
        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:DbxProviderRepo/releases/latest" `
            -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'MarkMichaelis.ScoopBucket' }
    }

    $version = ([string]$Release.tag_name).TrimStart('v')
    $moduleDir = Join-Path $ModulesRoot 'DbxProvider'
    $target = Join-Path $moduleDir $version

    if (Test-Path -LiteralPath (Join-Path $target 'DbxProvider.psd1')) {
        Write-Verbose "DbxProvider $version is already installed at $target."
        return
    }

    $assetName = "DbxProvider-$version.zip"
    $asset = @($Release.assets) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) {
        throw "DbxProvider release '$($Release.tag_name)' has no '$assetName' asset."
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
}

function Set-DbxDriveProfile {
    <#
    .SYNOPSIS
        Write the lazy `Dbx:` block into the user's PowerShell profile.

    .DESCRIPTION
        Writes a block delimited by `# ScoopBucket:DbxDrive:BEGIN <ver>` and
        `# ScoopBucket:DbxDrive:END`, replacing any earlier copy in place and
        rewriting the file only when its content changes. A rerun leaves the
        profile byte-identical.

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

    if (-not $ProfilePath) {
        Write-Warning 'No CurrentUserAllHosts profile path for this account; skipping the Dbx: profile block.'
        return
    }

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
    ) -join "`r`n"
    $block += "`r`n"

    $content = if (Test-Path -LiteralPath $ProfilePath) { Get-Content -LiteralPath $ProfilePath -Raw } else { '' }
    if ($null -eq $content) { $content = '' }

    $pattern = '(?ms)^# ScoopBucket:DbxDrive:BEGIN \w+.*?^# ScoopBucket:DbxDrive:END[^\S\r\n]*\r?\n?'
    $match = [regex]::Match($content, $pattern)
    $updated = if ($match.Success) {
        $content.Substring(0, $match.Index) + $block + $content.Substring($match.Index + $match.Length)
    } else {
        $trimmed = $content.TrimEnd("`r", "`n")
        if ($trimmed) { "$trimmed`r`n`r`n$block" } else { $block }
    }

    if ($updated -cne $content) {
        $dir = Split-Path -Parent $ProfilePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -LiteralPath $ProfilePath -Value $updated -NoNewline
        Write-Verbose "Wrote the Dbx: block to $ProfilePath."
    }

    if (-not ($CredentialPath -and (Test-Path -LiteralPath $CredentialPath))) {
        Write-Host 'DbxProvider: sign in to Dropbox once on this machine with: Connect-Dropbox -DriveName Dbx'
    }
}
