<#
.SYNOPSIS
    Personal post-install OneDrive customization (run-last, member of the
    MarkMichaelis* personal-customization bundle category).

.DESCRIPTION
    Reshapes OneDrive state on this machine to match the author's
    personal layout: all sync roots under a single configurable parent
    directory (default C:\OneDrive), tenant-redirection policy applied
    so future sign-ins land in the right place, and Known Folder Move
    (KFM) bindings rewritten to follow the OneDrive folder when it
    moves.

    Pattern follows GitConfigure.ps1 / SetPowerConfiguration.ps1: a
    free-form configuration script, NOT a [Package[]] declarative
    bundle. The MarkMichaelis* family runs AFTER all install bundles to
    reshape state.

    Behavior:
      - Idempotent: re-running is a no-op once state matches the
        convention.
      - Supports -WhatIf / -Confirm via $PSCmdlet.ShouldProcess on every
        state-changing operation.
      - Auto-migrates any account whose UserFolder doesn't match the
        target convention. Same-volume migrations use Move-Item (NTFS
        rename, preserves Cloud Files reparse + ACLs). Cross-volume
        migrations use robocopy /MIR /COPYALL /DCOPY:DAT /B and warn
        about Files-On-Demand placeholders.
      - Rewrites KFM bindings (User Shell Folders / Shell Folders /
        KNOWNFOLDERID GUIDs) when the owning account moves.
      - Extensible per-app fix-up hook ($AppFixUps) ships empty;
        Snagit is deliberately NOT included because its
        CatalogFolder / ExternalOutputDir use the logical Documents
        path and follow KFM transparently.

.PARAMETER RootDir
    Parent directory for all OneDrive sync roots. Default: C:\OneDrive.

.PARAMETER KfmOwner
    Account whose DisplayName identifies the canonical KFM owner.
    Default: 'Michaelis'. Resolved via a substring/equality match
    against the DisplayName of Business* registry slots.

.PARAMETER NoKfmRebind
    Suppress the warning + automatic rebind that fires when KFM is
    currently bound to a different account than -KfmOwner.

.PARAMETER FreshSync
    Names (Slot or DisplayName) of Business* accounts that should
    be unlinked instead of file-copy-migrated. For each match, the
    bundle stops OneDrive, deletes the per-account registry key
    (HKCU:\Software\Microsoft\OneDrive\Accounts\<Slot>) and the
    local UserFolder, then restarts OneDrive. The user must
    re-sign-in via the OneDrive UI; the DefaultRootDir policy
    (still applied) directs the new sync root to the canonical
    location, and OneDrive recreates cloud-only placeholders
    without bulk-downloading Files-On-Demand content. Personal
    accounts are not supported.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -WhatIf

    Shows every move + registry write the script would perform without
    changing any state.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1

    Run for real: pre-create $RootDir, apply policy, migrate any
    mis-located accounts, rewrite KFM, restart OneDrive.
#>

<#
Policy research (authoritative: https://learn.microsoft.com/sharepoint/use-group-policy)

Confirmed policy shape baked into this script:
  1. DefaultRootDir lives at HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir
     (per-user policy, not machine-wide).
  2. Each DefaultRootDir value name is the TenantId (GUID), and each value's
     data is the final tenant folder path, e.g. C:\OneDrive\OneDrive - Contoso.
  3. GPOSetUpdateRing lives at HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
     and therefore requires elevation to write.
  4. GPOSetUpdateRing must be 0 for the Deferred/Enterprise ring (stable
     updates). 4 would opt the machine into Insider/Preview builds; 5 is
     Production.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RootDir   = 'C:\OneDrive',
    [string] $KfmOwner  = 'Michaelis',
    [switch] $NoKfmRebind,
    [string[]] $FreshSync = @()
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pure helpers (no side effects -- the unit tests target these directly).
# ---------------------------------------------------------------------------

function Get-OneDriveTargetPath {
    <#
    .SYNOPSIS
        Compute the convention-correct local folder for an account.
    .DESCRIPTION
        Work tenants -> "$RootDir\OneDrive - <DisplayName>".
        Personal      -> "$RootDir\OneDrive - Personal".
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account,
        [Parameter(Mandatory)][string]$RootDir
    )
    if ($Account.AccountType -eq 'Personal') {
        return ([System.IO.Path]::Combine($RootDir, 'OneDrive - Personal'))
    }
    $name = $Account.DisplayName
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Account has no DisplayName; cannot compute target path."
    }
    return ([System.IO.Path]::Combine($RootDir, ("OneDrive - {0}" -f $name)))
}

function Test-IsSameVolume {
    <#
    .SYNOPSIS
        True if two paths live on the same Windows volume (drive root).
    .DESCRIPTION
        Same-volume migrations can use Move-Item (NTFS rename, preserves
        Cloud Files reparse points + ACLs). Cross-volume needs robocopy
        with /COPYALL /DCOPY:DAT /B.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $srcRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Source))
    $dstRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Destination))
    return ($srcRoot -and $dstRoot -and
            [string]::Equals($srcRoot, $dstRoot, [System.StringComparison]::OrdinalIgnoreCase))
}

function Resolve-KfmRebindAction {
    <#
    .SYNOPSIS
        Decide what to do with the current KFM binding.
    .DESCRIPTION
        Inputs:
          - $Accounts: list of discovered account records (with DisplayName,
            UserFolder, AccountType).
          - $KfmCurrentPath: current resolved Documents/Pictures path (or
            $null if KFM is not active).
          - $KfmOwner: the DisplayName substring of the desired owner.
          - $NoKfmRebind: switch -- if set, suppress rebind.

        Outputs an object with:
          - Action: 'None' | 'Track' | 'Rebind' | 'WarnOnly' | 'OwnerNotSignedIn'
          - OwnerAccount: the resolved account record, or $null
          - Reason: human-readable explanation
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [AllowNull()][string]$KfmCurrentPath,
        [Parameter(Mandatory)][string]$KfmOwner,
        [switch]$NoKfmRebind
    )

    $ownerAcct = $Accounts |
        Where-Object { $_.AccountType -ne 'Personal' -and $_.DisplayName -and ($_.DisplayName -match [regex]::Escape($KfmOwner)) } |
        Select-Object -First 1

    if (-not $ownerAcct) {
        return [pscustomobject]@{
            Action       = 'OwnerNotSignedIn'
            OwnerAccount = $null
            Reason       = "KfmOwner '$KfmOwner' is not signed in to OneDrive (no Business* slot has matching DisplayName)."
        }
    }

    if (-not $KfmCurrentPath) {
        return [pscustomobject]@{
            Action       = 'None'
            OwnerAccount = $ownerAcct
            Reason       = "KFM is not currently active; nothing to track."
        }
    }

    $ownerFolder = $ownerAcct.UserFolder
    if ($ownerFolder -and $KfmCurrentPath.StartsWith($ownerFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Action       = 'Track'
            OwnerAccount = $ownerAcct
            Reason       = "KFM is bound to the owner account ($($ownerAcct.DisplayName)); follow it when it moves."
        }
    }

    if ($NoKfmRebind) {
        return [pscustomobject]@{
            Action       = 'WarnOnly'
            OwnerAccount = $ownerAcct
            Reason       = "KFM is bound to a non-owner account ('$KfmCurrentPath') but -NoKfmRebind was supplied; leaving it alone."
        }
    }

    return [pscustomobject]@{
        Action       = 'Rebind'
        OwnerAccount = $ownerAcct
        Reason       = "KFM is bound to a non-owner path ('$KfmCurrentPath'); rebind to $($ownerAcct.DisplayName)."
    }
}

function Resolve-FreshSyncAccounts {
    <#
    .SYNOPSIS
        Match -FreshSync entries against discovered accounts and return
        the resolved account records.
    .DESCRIPTION
        Pure function. Each entry in $FreshSync is matched
        case-insensitively against either the Slot name (e.g.
        'Business2') or the DisplayName (e.g. 'IntelliTect') of a
        Business* account. Personal accounts are out of scope and
        cause a throw. Unmatched entries also cause a throw.

        Returns an array of the matched account objects (possibly
        empty when $FreshSync is empty).
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [AllowEmptyCollection()][AllowNull()][string[]]$FreshSync
    )

    if (-not $FreshSync -or $FreshSync.Count -eq 0) {
        return @()
    }

    $matched = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $FreshSync) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $hit = $Accounts | Where-Object {
            ($_.Slot -and [string]::Equals($_.Slot, $entry, [System.StringComparison]::OrdinalIgnoreCase)) -or
            ($_.DisplayName -and [string]::Equals($_.DisplayName, $entry, [System.StringComparison]::OrdinalIgnoreCase))
        } | Select-Object -First 1

        if (-not $hit) {
            throw "FreshSync entry '$entry' does not match any discovered OneDrive account (by Slot or DisplayName)."
        }
        if ($hit.AccountType -ne 'Business') {
            throw "FreshSync entry '$entry' matched a $($hit.AccountType) account (Slot=$($hit.Slot)); only Business accounts are supported."
        }
        if (-not ($matched | Where-Object { $_.Slot -eq $hit.Slot })) {
            $matched.Add($hit) | Out-Null
        }
    }
    return $matched.ToArray()
}

# ---------------------------------------------------------------------------
# Side-effectful helpers (registry + filesystem). Each wraps every
# state-changing call in $PSCmdlet.ShouldProcess so -WhatIf works.
# ---------------------------------------------------------------------------

$KnownFolderGuids = @(
    '{F42EE2D3-909F-4907-8871-4C22FC0BF756}',  # Documents
    '{0DDD015D-B06C-45D5-8C4C-F59713854639}',  # Pictures
    '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}'   # Desktop
)

function Get-OneDriveAccountList {
    <#
    .SYNOPSIS
        Enumerate OneDrive Business* + Personal accounts from HKCU.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    $root = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
    if (-not (Test-Path $root)) { return @() }

    foreach ($slot in Get-ChildItem -Path $root -ErrorAction SilentlyContinue) {
        $name = $slot.PSChildName
        $isBusiness = $name -like 'Business*'
        $isPersonal = $name -eq 'Personal'
        if (-not ($isBusiness -or $isPersonal)) { continue }

        $props = Get-ItemProperty -Path $slot.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }

        # Personal slot is only meaningful when populated (UserFolder set).
        if ($isPersonal -and -not $props.UserFolder) { continue }

        # Business slot may be a zombie left over from a failed sign-in:
        # no DisplayName, no UserFolder, no UserEmail. Skip it -- there is
        # nothing to compute a target path from and nothing to migrate.
        if ($isBusiness -and (-not $props.DisplayName -or -not $props.UserFolder)) {
            Write-Verbose "Skipping empty/zombie Business slot '$name' (no DisplayName or UserFolder)."
            continue
        }

        $tenantId = $props.ConfiguredTenantId
        if (-not $tenantId) { $tenantId = $props.cid }

        $results.Add([pscustomobject]@{
            Slot              = $name
            AccountType       = if ($isPersonal) { 'Personal' } else { 'Business' }
            DisplayName       = $props.DisplayName
            TenantId          = $tenantId
            UserEmail         = $props.UserEmail
            UserFolder        = $props.UserFolder
            RegistryPath      = $slot.PSPath
        }) | Out-Null
    }
    return $results.ToArray()
}

function Get-CurrentKfmPath {
    <#
    .SYNOPSIS
        Read the resolved Documents path from Shell Folders, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    $shellFolders = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    if (-not (Test-Path $shellFolders)) { return $null }
    $props = Get-ItemProperty -Path $shellFolders -ErrorAction SilentlyContinue
    if (-not $props) { return $null }
    return $props.Personal  # the "Personal" value here = Documents
}

function Set-OneDrivePolicy {
    <#
    .SYNOPSIS
        Apply tenant-redirection policy (DefaultRootDir per Work tenant)
        and the GPOSetUpdateRing policy in HKLM.
    .DESCRIPTION
        Policy shape verified against https://learn.microsoft.com/sharepoint/use-group-policy:
          - DefaultRootDir is a per-user HKCU policy whose value name is the
            tenant GUID and whose value data is the final tenant folder.
          - GPOSetUpdateRing is a machine HKLM policy. Value 0 selects the
            Deferred/Enterprise ring (stable updates).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object[]]$Accounts,
        [Parameter(Mandatory)][string]$RootDir
    )

    $hkcuPolicy = 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive'
    $hkcuDefRoot = "$hkcuPolicy\DefaultRootDir"
    foreach ($key in @($hkcuPolicy, $hkcuDefRoot)) {
        if (-not (Test-Path $key)) {
            if ($PSCmdlet.ShouldProcess($key, 'Create registry key')) {
                New-Item -Path $key -Force | Out-Null
            }
        }
    }

    foreach ($acct in $Accounts) {
        if ($acct.AccountType -ne 'Business') { continue }
        if (-not $acct.TenantId)              { continue }
        if (-not $acct.DisplayName)           { continue }
        $target = Join-Path $RootDir ("OneDrive - {0}" -f $acct.DisplayName)
        $existing = (Get-ItemProperty -Path $hkcuDefRoot -Name $acct.TenantId -ErrorAction SilentlyContinue).$($acct.TenantId)
        if ($existing -eq $target) { continue }
        if ($PSCmdlet.ShouldProcess("$hkcuDefRoot\$($acct.TenantId)", "Set DefaultRootDir -> $target")) {
            Set-ItemProperty -Path $hkcuDefRoot -Name $acct.TenantId -Value $target -Type String
        }
    }

    $hklmPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    if (-not (Test-Path $hklmPolicy)) {
        if ($PSCmdlet.ShouldProcess($hklmPolicy, 'Create registry key')) {
            try { New-Item -Path $hklmPolicy -Force | Out-Null } catch {
                Write-Warning "Could not create $hklmPolicy (requires elevation): $($_.Exception.Message)"
                return
            }
        }
    }
    $existingRing = (Get-ItemProperty -Path $hklmPolicy -Name 'GPOSetUpdateRing' -ErrorAction SilentlyContinue).GPOSetUpdateRing
    if ($existingRing -ne 0) {
        if ($PSCmdlet.ShouldProcess("$hklmPolicy\GPOSetUpdateRing", 'Set DWord = 0 (Deferred/Enterprise ring; stable updates)')) {
            try {
                Set-ItemProperty -Path $hklmPolicy -Name 'GPOSetUpdateRing' -Value 0 -Type DWord
            } catch {
                Write-Warning "Could not set GPOSetUpdateRing (requires elevation): $($_.Exception.Message)"
            }
        }
    }
}

function Stop-OneDriveExe {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $exe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
    if (-not (Test-Path $exe)) { $exe = 'OneDrive.exe' }
    if ($PSCmdlet.ShouldProcess('OneDrive.exe', '/shutdown')) {
        try { & $exe /shutdown 2>$null } catch { }
        # Best-effort wait: poll for process exit up to 10s.
        for ($i = 0; $i -lt 20; $i++) {
            if (-not (Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Start-OneDriveExe {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $exe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
    if (-not (Test-Path $exe)) { $exe = 'OneDrive.exe' }
    if ($PSCmdlet.ShouldProcess('OneDrive.exe', 'start (background)')) {
        try { Start-Process -FilePath $exe -ArgumentList '/background' -WindowStyle Hidden | Out-Null } catch {
            Write-Warning "Failed to start OneDrive: $($_.Exception.Message)"
        }
    }
}

function Move-OneDriveFolder {
    <#
    .SYNOPSIS
        Move an account's UserFolder from $Source to $Destination,
        using NTFS rename when possible and robocopy /MIR /COPYALL
        otherwise. Throws on failure (leaves source in place).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path $Source)) {
        Write-Verbose "Source '$Source' does not exist; treating as new account folder."
        return
    }
    if ((Test-Path $Destination) -and ((Get-Item $Destination).FullName -ieq (Get-Item $Source).FullName)) {
        return
    }
    if (Test-Path $Destination) {
        throw "Refusing to merge: destination '$Destination' already exists. Resolve manually."
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path $parent)) {
        if ($PSCmdlet.ShouldProcess($parent, 'Create parent directory')) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    if (Test-IsSameVolume -Source $Source -Destination $Destination) {
        if ($PSCmdlet.ShouldProcess($Source, "Move-Item -> $Destination (same volume)")) {
            Move-Item -LiteralPath $Source -Destination $Destination
        }
    } else {
        Write-Warning "Cross-volume migration: Files-On-Demand placeholders will be materialized by robocopy. To force-hydrate cloud-only files first, run: attrib -O '$Source\*' /S /D"
        if ($PSCmdlet.ShouldProcess($Source, "robocopy /MIR /COPYALL -> $Destination (cross volume)")) {
            $args = @($Source, $Destination, '/MIR','/COPYALL','/DCOPY:DAT','/B','/R:1','/W:1','/XJ','/NFL','/NDL')
            & robocopy @args | Out-Null
            $rc = $LASTEXITCODE
            # robocopy success: 0-7. >=8 is failure.
            if ($rc -ge 8) {
                throw "robocopy failed (exit $rc) -- leaving source '$Source' in place."
            }
            if ($PSCmdlet.ShouldProcess($Source, 'Remove-Item -Recurse (after successful robocopy)')) {
                Remove-Item -LiteralPath $Source -Recurse -Force
            }
        }
    }
}

function Update-OneDriveAccountRegistry {
    <#
    .SYNOPSIS
        Update OneDrive's per-account registry so it knows where the
        UserFolder lives after a move.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account,
        [Parameter(Mandatory)][string]$NewPath
    )
    $regPath = $Account.RegistryPath
    if ($PSCmdlet.ShouldProcess("$regPath\UserFolder", "Set -> $NewPath")) {
        Set-ItemProperty -Path $regPath -Name 'UserFolder' -Value $NewPath -Type String
    }
    foreach ($valueName in 'ScopeIdToMountPointPathCache','ScopeIdToMountPointPathCacheRoot') {
        $cacheKey = Join-Path $regPath $valueName
        if (-not (Test-Path $cacheKey)) { continue }
        $props = Get-ItemProperty -Path $cacheKey -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($pName in $props.PSObject.Properties.Name) {
            if ($pName -like 'PS*') { continue }
            $cur = $props.$pName
            if ($cur -is [string] -and $Account.UserFolder -and
                $cur.StartsWith($Account.UserFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
                $new = $NewPath + $cur.Substring($Account.UserFolder.Length)
                if ($PSCmdlet.ShouldProcess("$cacheKey\$pName", "Rewrite '$cur' -> '$new'")) {
                    Set-ItemProperty -Path $cacheKey -Name $pName -Value $new
                }
            }
        }
    }
}

function Update-KfmBindings {
    <#
    .SYNOPSIS
        Rewrite User Shell Folders / Shell Folders / KNOWNFOLDERID GUID
        entries that point under $OldRoot so they now point under
        $NewRoot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    foreach ($leaf in 'User Shell Folders','Shell Folders') {
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\$leaf"
        if (-not (Test-Path $key)) { continue }
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($pName in $props.PSObject.Properties.Name) {
            if ($pName -like 'PS*') { continue }
            $cur = [string]$props.$pName
            if ($cur.StartsWith($OldRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $new = $NewRoot + $cur.Substring($OldRoot.Length)
                if ($PSCmdlet.ShouldProcess("$key\$pName", "Rewrite '$cur' -> '$new'")) {
                    # User Shell Folders uses ExpandString templates; Shell
                    # Folders is plain String. Preserve whichever type the
                    # value already had.
                    $kind = (Get-Item -LiteralPath $key).GetValueKind($pName)
                    Set-ItemProperty -Path $key -Name $pName -Value $new -Type $kind
                }
            }
        }
    }

    foreach ($guid in $KnownFolderGuids) {
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\$guid"
        if (-not (Test-Path $key)) { continue }
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($pName in 'RelativePath','ParsingName') {
            $cur = [string]$props.$pName
            if ($cur -and $cur.StartsWith($OldRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $new = $NewRoot + $cur.Substring($OldRoot.Length)
                if ($PSCmdlet.ShouldProcess("$key\$pName", "Rewrite '$cur' -> '$new'")) {
                    Set-ItemProperty -Path $key -Name $pName -Value $new
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Extensible per-app fix-up hook.
#
# Snagit is deliberately NOT included: its CatalogFolder /
# ExternalOutputDir use the logical Documents path
# (%USERPROFILE%\Documents or the KFM-redirected Documents target), so
# it follows KFM transparently without needing a registry rewrite.
# ---------------------------------------------------------------------------

$AppFixUps = @{
    # Example shape (left empty by design):
    #
    # 'HKCU:\Software\SomeVendor\SomeApp' = @{
    #     'SomeValueName' = { param($old, $new) $current = (Get-ItemProperty $key $name).$name; ... }
    # }
}

function Remove-OneDriveAccountLink {
    <#
    .SYNOPSIS
        Unlink a OneDrive Business account: delete its registry slot
        and local UserFolder so the user can re-sign-in fresh.
    .DESCRIPTION
        Used by -FreshSync to avoid bulk-hydrating Files-On-Demand
        placeholders during a cross-volume migration. Caller is
        responsible for stopping OneDrive.exe first.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account
    )
    $regPath = $Account.RegistryPath
    if ($regPath -and (Test-Path $regPath)) {
        if ($PSCmdlet.ShouldProcess($regPath, "Remove OneDrive account registry key (fresh-sync)")) {
            Remove-Item -LiteralPath $regPath -Recurse -Force
        }
    }
    $folder = $Account.UserFolder
    if ($folder -and (Test-Path $folder)) {
        if ($PSCmdlet.ShouldProcess($folder, "Remove local OneDrive sync folder (fresh-sync)")) {
            Remove-Item -LiteralPath $folder -Recurse -Force
        }
    }
}

function Invoke-AppFixUps {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )
    foreach ($regPath in $AppFixUps.Keys) {
        if (-not (Test-Path $regPath)) { continue }
        foreach ($valueName in $AppFixUps[$regPath].Keys) {
            $sb = $AppFixUps[$regPath][$valueName]
            if ($PSCmdlet.ShouldProcess("$regPath\$valueName", 'Run app fix-up scriptblock')) {
                & $sb $OldRoot $NewRoot
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main orchestration. Skipped when the script is dot-sourced (so unit
# tests can pull in just the helper functions above).
# ---------------------------------------------------------------------------

function Invoke-MarkMichaelisOneDriveConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$KfmOwner,
        [switch]$NoKfmRebind,
        [AllowEmptyCollection()][AllowNull()][string[]]$FreshSync
    )

    Write-Host "MarkMichaelisOneDriveConfiguration: RootDir=$RootDir, KfmOwner=$KfmOwner"
    if ($FreshSync -and $FreshSync.Count -gt 0) {
        Write-Host "  FreshSync requested: $($FreshSync -join ', ')"
    }

    # 1. Pre-create $RootDir.
    if (-not (Test-Path $RootDir)) {
        if ($PSCmdlet.ShouldProcess($RootDir, 'Create directory')) {
            New-Item -ItemType Directory -Path $RootDir -Force | Out-Null
        }
    }

    # 2. Discover accounts.
    $accounts = Get-OneDriveAccountList

    # 2a. Resolve -FreshSync entries against the discovered accounts.
    $freshSyncAccounts = Resolve-FreshSyncAccounts -Accounts $accounts -FreshSync $FreshSync
    $freshSyncSlots = @($freshSyncAccounts | ForEach-Object { $_.Slot })

    Write-Host "  Discovered $($accounts.Count) account(s):"
    foreach ($a in $accounts) {
        $tag = if ($freshSyncSlots -contains $a.Slot) { '  [FRESH-SYNC]' } else { '' }
        Write-Host ("    [{0}] {1} <{2}> -> {3}{4}" -f $a.AccountType, $a.DisplayName, $a.UserEmail, $a.UserFolder, $tag)
    }

    # 3. Pre-create per-account target directories under $RootDir.
    #    Skip FreshSync accounts: OneDrive will create the folder on re-sign-in.
    foreach ($a in $accounts) {
        if ($freshSyncSlots -contains $a.Slot) { continue }
        $target = Get-OneDriveTargetPath -Account $a -RootDir $RootDir
        if (-not (Test-Path $target)) {
            if ($PSCmdlet.ShouldProcess($target, 'Create directory')) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            }
        }
    }

    # 4. KFM decision (computed before any moves so we know who to track).
    $kfmCurrent = Get-CurrentKfmPath
    $kfmDecision = Resolve-KfmRebindAction -Accounts $accounts -KfmCurrentPath $kfmCurrent `
        -KfmOwner $KfmOwner -NoKfmRebind:$NoKfmRebind
    Write-Host "  KFM: [$($kfmDecision.Action)] $($kfmDecision.Reason)"
    if ($kfmDecision.Action -eq 'OwnerNotSignedIn') {
        throw "KFM owner '$KfmOwner' is not signed in. Sign in to the matching Work account in OneDrive and re-run."
    }

    # If the KFM owner itself is being fresh-synced, KFM bindings will
    # break -- skip the rewrite/rebind work and warn the user.
    $kfmOwnerInFreshSync = $false
    if ($kfmDecision.OwnerAccount -and ($freshSyncSlots -contains $kfmDecision.OwnerAccount.Slot)) {
        $kfmOwnerInFreshSync = $true
        Write-Warning ("KFM owner account '{0}' ({1}) is in -FreshSync. KFM bindings will break when the account is unlinked. After re-sign-in, reconfigure KFM via OneDrive Settings -> Backup -> Manage backup." -f $kfmDecision.OwnerAccount.DisplayName, $kfmDecision.OwnerAccount.Slot)
    }

    # 5. Apply policy. Still applied for FreshSync accounts so the
    #    new sync root lands at the policy-directed path on re-sign-in.
    Set-OneDrivePolicy -Accounts $accounts -RootDir $RootDir

    # 6. Compute migration plan (file-copy) and execute. FreshSync
    #    accounts are excluded from the file-copy list and handled
    #    separately via Remove-OneDriveAccountLink.
    $stoppedOneDrive = $false
    $migrations = @()
    foreach ($a in $accounts) {
        if ($freshSyncSlots -contains $a.Slot) { continue }
        $target = Get-OneDriveTargetPath -Account $a -RootDir $RootDir
        if ($a.UserFolder -and (Test-Path $a.UserFolder) -and
            ($a.UserFolder.TrimEnd('\') -ine $target.TrimEnd('\'))) {
            $migrations += [pscustomobject]@{ Account = $a; OldPath = $a.UserFolder; NewPath = $target }
        }
    }

    if ($migrations.Count -gt 0 -or $freshSyncAccounts.Count -gt 0) {
        Stop-OneDriveExe
        $stoppedOneDrive = $true

        foreach ($m in $migrations) {
            try {
                Write-Host "  Migrating $($m.Account.DisplayName): $($m.OldPath) -> $($m.NewPath)"
                Move-OneDriveFolder -Source $m.OldPath -Destination $m.NewPath
                Update-OneDriveAccountRegistry -Account $m.Account -NewPath $m.NewPath

                # Rewrite KFM if this account is the (tracked) owner.
                if (-not $kfmOwnerInFreshSync -and
                    $kfmDecision.Action -eq 'Track' -and
                    $kfmDecision.OwnerAccount -and
                    $kfmDecision.OwnerAccount.Slot -eq $m.Account.Slot) {
                    Update-KfmBindings -OldRoot $m.OldPath -NewRoot $m.NewPath
                }
                Invoke-AppFixUps -OldRoot $m.OldPath -NewRoot $m.NewPath
            } catch {
                Write-Error "Migration failed for $($m.Account.DisplayName): $($_.Exception.Message). Source left in place; OneDrive NOT restarted."
                throw
            }
        }

        foreach ($fa in $freshSyncAccounts) {
            try {
                Write-Verbose "Fresh-sync: unlinking account '$($fa.Slot)' ($($fa.DisplayName)) (registry + local folder)..."
                Write-Host "  Fresh-sync unlink: $($fa.DisplayName) (Slot=$($fa.Slot))"
                Remove-OneDriveAccountLink -Account $fa
            } catch {
                Write-Error "Fresh-sync unlink failed for $($fa.DisplayName): $($_.Exception.Message). OneDrive NOT restarted."
                throw
            }
        }
    }

    # 7. Handle Rebind / WarnOnly cases (skip if owner is in FreshSync).
    if (-not $kfmOwnerInFreshSync) {
        if ($kfmDecision.Action -eq 'Rebind' -and $kfmDecision.OwnerAccount) {
            $ownerTarget = Get-OneDriveTargetPath -Account $kfmDecision.OwnerAccount -RootDir $RootDir
            $kfmRoot = $kfmCurrent
            # Trim to drive root if it doesn't match a known account folder.
            if ($PSCmdlet.ShouldProcess("KFM root '$kfmRoot' -> '$ownerTarget'", "Rebind KFM")) {
                Update-KfmBindings -OldRoot $kfmRoot -NewRoot $ownerTarget
            }
        } elseif ($kfmDecision.Action -eq 'WarnOnly') {
            Write-Warning $kfmDecision.Reason
        }
    }

    if ($stoppedOneDrive) {
        Start-OneDriveExe
    }

    # 8. Banner.
    Write-Host ""
    Write-Host "MarkMichaelisOneDriveConfiguration complete:"
    Write-Host "  Accounts found:   $($accounts.Count)"
    Write-Host "  Migrations:       $($migrations.Count)"
    Write-Host "  Fresh-sync:       $($freshSyncAccounts.Count)"
    if ($kfmOwnerInFreshSync) {
        Write-Host "  KFM action:       Skipped (owner in -FreshSync)"
    } else {
        Write-Host "  KFM action:       $($kfmDecision.Action)"
    }
    Write-Host ""

    if ($freshSyncAccounts.Count -gt 0) {
        Write-Host "FRESH-SYNC accounts unlinked:"
        foreach ($fa in $freshSyncAccounts) {
            Write-Host ("  - {0} ({1})" -f $fa.DisplayName, $fa.Slot)
        }
        Write-Host ""
        Write-Host "To complete the migration:"
        Write-Host "  1. Open OneDrive Settings (right-click cloud icon -> Settings -> Account)"
        Write-Host "  2. Click 'Add an account'"
        foreach ($fa in $freshSyncAccounts) {
            $newTarget = Get-OneDriveTargetPath -Account $fa -RootDir $RootDir
            Write-Host ("  3. Sign in to: {0}" -f $fa.UserEmail)
            Write-Host ("     Policy will direct the new sync root to: {0}" -f $newTarget)
        }
        Write-Host "  4. OneDrive will create cloud-only placeholders (no bulk download)."
        Write-Host ""
    }

    Write-Warning "MRU staleness: Office recent docs / Snagit Recent File List / VS recent files may reference old OneDrive paths; reopen as needed."
}

# Only run when invoked as a script (Scoop's installer does
# `& "$dir\MarkMichaelisOneDriveConfiguration.ps1"`). When dot-sourced
# (Pester tests), expose the helpers without running migration.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MarkMichaelisOneDriveConfiguration -RootDir $RootDir -KfmOwner $KfmOwner -NoKfmRebind:$NoKfmRebind -FreshSync $FreshSync
}
