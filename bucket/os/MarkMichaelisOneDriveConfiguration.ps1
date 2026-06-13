<#
.SYNOPSIS
    Personal post-install OneDrive customization (run-last, member of the
    MarkMichaelis* personal-customization bundle category).

.DESCRIPTION
    Reshapes OneDrive state on this machine to match the author's
    personal layout: all sync roots under a single configurable parent
    directory (default C:\OneDrive), tenant-redirection policy applied
    so future sign-ins land in the right place, and Known Folder Move
    (KFM) bindings rewritten to follow the canonical Work account.

    Pattern follows GitConfigure.ps1 / SetPowerConfiguration.ps1: a
    free-form configuration script, NOT a [Package[]] declarative
    bundle. The MarkMichaelis* family runs AFTER all install bundles to
    reshape state.

    What the bundle does
    --------------------
    1. Discovers current OneDrive accounts, SharePoint mount points, and
       KFM ownership, then renders a plan before any mutations occur.
    2. Pre-creates $RootDir (default C:\OneDrive) and hardens its ACL to
       match $env:USERPROFILE so the sync root is user-only on alternate
       volumes.
    3. Applies tenant-redirection policy under
       HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir\<tid>
       for each Work tenant, and keeps GPOSetUpdateRing on the
       Production ring in HKLM.
    4. For each discovered account, migrates the existing UserFolder to
       the canonical path when it can do so without hydrating cloud-only
       placeholders.
    5. Rewrites Known Folder Move bindings (Documents / Pictures /
       Desktop in User Shell Folders, Shell Folders, and KNOWNFOLDERID
       GUIDs) so KFM follows the -KfmOwner account when its folder
       moves.

    Behavior
    --------
      - Idempotent: re-running is a no-op once state matches the
        convention.
      - Supports -WhatIf / -Confirm via $PSCmdlet.ShouldProcess on every
        state-changing operation.
      - Same-volume migrations use Move-Item (NTFS rename, preserves
        Cloud Files reparse points + ACLs).
      - Cross-volume migrations use robocopy /E /COPYALL /DCOPY:DAT /ZB
        and skip moves with cloud-only placeholders so cloud-only files
        stay cloud-only.
      - Rewrites KFM bindings when the owning account moves. If KFM is
        currently bound to a different account, the script warns and
        leaves reconfiguration to the OneDrive UI.
      - Extensible per-app fix-up hook ($AppFixUps) ships empty; Snagit
        is deliberately NOT included because its CatalogFolder /
        ExternalOutputDir use the logical Documents path and follow KFM
        transparently.

    Cross-volume migration and Files-On-Demand
    ------------------------------------------
    The default action for an account whose UserFolder differs from the
    convention is to migrate the files in place:

      - Same-volume:   Move-Item (NTFS rename, preserves Cloud Files
                       reparse points + ACLs).
      - Cross-volume:  robocopy /E /COPYALL /DCOPY:DAT /ZB.

    Cross-volume migration can materialize Files-On-Demand placeholders,
    so the script refuses those moves when cloud-only files are present.
    Use the OneDrive UI to re-link the affected account or make the files
    available offline before re-running.

    Why elevation is required
    -------------------------
    The bundle writes HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
    (GPOSetUpdateRing), which requires Administrator. The script fails
    fast with a clear message if launched without elevation.

    Known Folder Move (KFM) model
    -----------------------------
    KFM redirects Documents, Desktop, and Pictures into a OneDrive
    sync folder. Only one Work account at a time can own KFM. The
    -KfmOwner parameter identifies that canonical Business account by
    case-insensitive substring match. KFM is tracked when that account
    moves. Personal accounts are never eligible to own KFM.

.PARAMETER RootDir
    Parent directory for all OneDrive sync roots. Default: C:\OneDrive.
    When $RootDir is on a different volume than $env:USERPROFILE,
    file-copy migrations that would hydrate Files-On-Demand placeholders
    are skipped for safety.

.PARAMETER KfmOwner
    DisplayName identifying the canonical KFM owner - the Business
    account whose Documents / Desktop / Pictures KFM should follow.
    Default: 'Michaelis'. The match is case-insensitive substring
    matching against Business* registry-slot DisplayName values. Only
    the first Business match wins; Personal accounts are never eligible.

.PARAMETER DeleteSourceOnSuccess
    Delete verified cross-volume .migrated-* recovery folders during the
    run. By default those folders are preserved and the final summary
    prints exact Remove-Item cleanup commands.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -WhatIf

    Default plan-then-execute preview: roots at C:\OneDrive, all
    accounts evaluated for migration, and KFM following Michaelis.
    Shows every move + registry write without changing any state.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -RootDir D:\OneDrive -WhatIf

    Cross-volume preview to D:. Moves with cloud-only placeholders are
    skipped and reported so those files stay cloud-only.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1

    Run for real: compute the plan, export a registry backup, apply
    policy, migrate any mis-located accounts, rewrite KFM, verify the
    result, and restart OneDrive if needed.

.NOTES
    Requires an elevated PowerShell session (Run as Administrator):
    the bundle writes HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
    (GPOSetUpdateRing).

    Restarts OneDrive.exe whenever a migration occurs (stops with
    /shutdown, restarts with /background).

    Cross-volume migrations can hydrate Files-On-Demand placeholders
    and are skipped when cloud-only files are present.

    OneDrive's HKCU:\Software\Microsoft\OneDrive\Accounts\<slot>\UserFolder
    and the various ScopeIdToMountPointPathCache* values are internal
    OneDrive client state. Microsoft does not publish a supported
    migration API for them. This script mutates them pragmatically
    because (a) OneDrive otherwise treats a moved sync root as a new
    location and re-syncs from scratch, and (b) cached SharePoint mount
    paths must follow the move or the client will fall back to the old
    location. If a future OneDrive client version changes this state
    shape, this script will need updating.
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
  4. GPOSetUpdateRing values per Microsoft policy docs: 0 = Deferred/
     Enterprise (older stable cadence), 4 = Insider/Preview, 5 = Production
     (standard cadence). This script writes 5 (Production).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RootDir   = 'C:\OneDrive',
    [string] $KfmOwner  = 'Michaelis',
    [switch] $DeleteSourceOnSuccess
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pure helpers (no side effects -- the unit tests target these directly).
# ---------------------------------------------------------------------------

function Test-IsElevated {
    <#
    .SYNOPSIS
        Return $true when the current PowerShell session is running with
        Administrator privileges, else $false.
    .DESCRIPTION
        The bundle writes HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
        (DefaultRootDir / KFMSilentOptIn etc.), which requires admin.
        Centralizing the check in a function makes it overridable for
        unit tests.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Elevation pre-flight: fail fast (even under -WhatIf) before the banner
# or any state-changing side effect. Tests dot-source the script, so this
# block must only fire when invoked as a script.
#
# The $global:__MMOD_ForceIsElevated escape hatch lets unit tests poke a
# deterministic value into the pre-flight check without mocking
# Test-IsElevated itself (the script-local function definition would
# otherwise shadow any Pester Mock).
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $__mmodIsElevated = if ((Test-Path 'Variable:Global:__MMOD_ForceIsElevated') -and
                            ($global:__MMOD_ForceIsElevated -is [bool])) {
        $global:__MMOD_ForceIsElevated
    } else {
        Test-IsElevated
    }
    if (-not $__mmodIsElevated) {
        throw "MarkMichaelisOneDriveConfiguration must be run from an elevated PowerShell session (HKLM policy write requires admin). Re-launch with Run as Administrator."
    }
}

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

function Set-RootDirAclFromHome {
    <#
    .SYNOPSIS
        Copy the ACL from the user's home directory onto $Path.
    .DESCRIPTION
        When $RootDir is created on a volume other than the system
        drive (e.g. D:\OneDrive), it inherits the volume-root ACL,
        which on a default Windows install grants Read+Execute to
        BUILTIN\Users. That makes the OneDrive sync root readable
        by every local account on the box.

        This helper copies the explicit ACL from the user's home
        directory (which Windows provisions as user-only) onto the
        target path so the sync root is hardened to match home-dir
        permissions. Gated by $PSCmdlet.ShouldProcess so -WhatIf
        previews the intended Set-Acl call.

        Accepts an optional -ReferenceAcl so unit tests can supply
        a synthetic ACL without touching the real filesystem.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $ReferencePath = $env:USERPROFILE,
        [object] $ReferenceAcl
    )
    if (-not $ReferenceAcl) {
        $ReferenceAcl = Get-Acl -LiteralPath $ReferencePath
    }
    if ($PSCmdlet.ShouldProcess($Path, "Apply ACL from '$ReferencePath'")) {
        Set-Acl -LiteralPath $Path -AclObject $ReferenceAcl
    }
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

function Test-KfmOwnerMatch {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [AllowNull()][string]$DisplayName,
        [Parameter(Mandatory)][string]$KfmOwner
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        return $false
    }

    return ($DisplayName.IndexOf($KfmOwner, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
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
          - $KfmOwner: the desired owner DisplayName.
        Outputs an object with:
          - Action: 'None' | 'Track' | 'WarnOnly' | 'OwnerNotSignedIn'
          - OwnerAccount: the resolved account record, or $null
          - Reason: human-readable explanation
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [AllowNull()][string]$KfmCurrentPath,
        [Parameter(Mandatory)][string]$KfmOwner
    )

    if (-not $KfmCurrentPath) {
        return [pscustomobject]@{
            Action       = 'None'
            OwnerAccount = $null
            Reason       = "KFM is not currently active; nothing to track."
        }
    }

    $ownerAcct = $Accounts |
        Where-Object { $_.AccountType -ne 'Personal' -and (Test-KfmOwnerMatch -DisplayName $_.DisplayName -KfmOwner $KfmOwner) } |
        Select-Object -First 1

    if (-not $ownerAcct) {
        return [pscustomobject]@{
            Action       = 'OwnerNotSignedIn'
            OwnerAccount = $null
            Reason       = "KfmOwner '$KfmOwner' is not signed in to OneDrive (no Business* slot has matching DisplayName)."
        }
    }

    $ownerFolder = $ownerAcct.UserFolder
    if ($ownerFolder -and (Test-OneDrivePathUnderRoot -Path $KfmCurrentPath -Root $ownerFolder)) {
        return [pscustomobject]@{
            Action       = 'Track'
            OwnerAccount = $ownerAcct
            Reason       = "KFM is bound to the owner account ($($ownerAcct.DisplayName)); follow it when it moves."
        }
    }

    return [pscustomobject]@{
        Action       = 'WarnOnly'
        OwnerAccount = $ownerAcct
        Reason       = "KFM is bound to a non-owner path ('$KfmCurrentPath'); leaving it for the OneDrive UI to reconfigure."
    }
}

# ---------------------------------------------------------------------------
# Side-effectful helpers (registry + filesystem). Each wraps every
# state-changing call in $PSCmdlet.ShouldProcess so -WhatIf works.
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

function Resolve-KfmCurrentOwnerRoot {
    <#
    .SYNOPSIS
        Find the discovered OneDrive account whose UserFolder is the longest
        prefix of the current KFM path.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [AllowNull()][string]$KfmCurrentPath
    )

    if ([string]::IsNullOrWhiteSpace($KfmCurrentPath)) { return $null }

    $match = $Accounts |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.UserFolder) } |
        Sort-Object { $_.UserFolder.TrimEnd('\').Length } -Descending |
        Where-Object {
            $root = $_.UserFolder.TrimEnd('\')
            $current = $KfmCurrentPath.TrimEnd('\')
            $current.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
            $current.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -First 1

    return $match
}

function Stop-OneDriveExe {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $exe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
    if (-not (Test-Path $exe)) { $exe = 'OneDrive.exe' }
    if ($PSCmdlet.ShouldProcess('OneDrive.exe', '/shutdown')) {
        try { & $exe /shutdown 2>$null } catch {
            Write-Verbose "OneDrive shutdown command failed: $($_.Exception.Message)"
        }
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

function Invoke-RobocopyMirror {
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $robocopyArgs = @($Source, $Destination, '/E','/COPYALL','/DCOPY:DAT','/ZB','/R:1','/W:1','/XJ','/NFL','/NDL')
    & robocopy @robocopyArgs | Out-Null
    return $LASTEXITCODE
}

function Test-OneDriveFolderMoveVerification {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [AllowNull()][string]$DeferredSource
    )

    if (-not (Test-Path $Destination)) { return $false }
    if ($DeferredSource) {
        return (Test-Path $DeferredSource)
    }
    return $true
}

function Move-OneDriveFolder {
    <#
    .SYNOPSIS
        Move an account's UserFolder from $Source to $Destination,
        using NTFS rename when possible and robocopy /E /COPYALL
        otherwise. Cross-volume moves rename the original source to a
        .migrated-* recovery folder, verify the destination, then delete
        the recovery folder.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$DeleteSourceOnSuccess
    )

    $result = [pscustomobject]@{
        SameVolume         = $null
        DeferredDeletePath = $null
    }

    if (-not (Test-Path $Source)) {
        Write-Verbose "Source '$Source' does not exist; treating as new account folder."
        return $result
    }
    if ((Test-Path $Destination) -and ((Get-Item $Destination).FullName -ieq (Get-Item $Source).FullName)) {
        return $result
    }
    if (Test-Path $Destination) {
        $destChildren = @(Get-ChildItem -LiteralPath $Destination -Force -ErrorAction SilentlyContinue)
        if ($destChildren.Count -gt 0) {
            throw "Refusing to merge: destination '$Destination' already exists and is not empty. Resolve manually."
        }
        # An empty pre-existing destination is safe: remove it so the move
        # recreates the destination path itself (a same-volume rename moves the
        # source onto the path, not into an existing directory).
        if ($PSCmdlet.ShouldProcess($Destination, 'Remove empty pre-existing destination directory')) {
            Remove-Item -LiteralPath $Destination -Force
        }
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path $parent)) {
        if ($PSCmdlet.ShouldProcess($parent, 'Create parent directory')) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    $result.SameVolume = Test-IsSameVolume -Source $Source -Destination $Destination
    if ($result.SameVolume) {
        if ($PSCmdlet.ShouldProcess($Source, "Move-Item -> $Destination (same volume)")) {
            Move-Item -LiteralPath $Source -Destination $Destination
        }
        return $result
    }

    Write-Warning "Cross-volume migration uses robocopy /E /COPYALL first, then renames the original source to a .migrated-* recovery folder. The recovery folder is preserved unless -DeleteSourceOnSuccess is supplied."
    if ($PSCmdlet.ShouldProcess($Source, "robocopy /E /COPYALL -> $Destination (cross volume)")) {
        $rc = Invoke-RobocopyMirror -Source $Source -Destination $Destination
        # robocopy success: 0-7. >=8 is failure.
        if ($rc -ge 8) {
            throw "robocopy failed (exit $rc) -- leaving source '$Source' in place."
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $migratedPath = "$Source.migrated-$timestamp"
        Move-Item -LiteralPath $Source -Destination $migratedPath

        if (-not (Test-OneDriveFolderMoveVerification -Destination $Destination -DeferredSource $migratedPath)) {
            throw "Cross-volume verification failed after copying '$Source' to '$Destination'. Original data was preserved at '$migratedPath'."
        }

        if ($DeleteSourceOnSuccess) {
            if ($PSCmdlet.ShouldProcess($migratedPath, 'Remove-Item -Recurse (verified cross-volume source cleanup)')) {
                Remove-Item -LiteralPath $migratedPath -Recurse -Force
            }
        } else {
            $result.DeferredDeletePath = $migratedPath
        }
    }

    return $result
}

function Update-OneDriveAccountRegistry {
    <#
    .SYNOPSIS
        Update OneDrive's per-account registry so it knows where the
        UserFolder lives after a move.
    .NOTES
        Mutates OneDrive client internal registry state
        (Accounts\<slot>\UserFolder and ScopeIdToMountPointPathCache*).
        Microsoft does not document these as supported migration APIs.
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
                (Test-OneDrivePathUnderRoot -Path $cur -Root $Account.UserFolder)) {
                $new = $NewPath + $cur.Substring($Account.UserFolder.Length)
                if ($PSCmdlet.ShouldProcess("$cacheKey\$pName", "Rewrite '$cur' -> '$new'")) {
                    Set-ItemProperty -Path $cacheKey -Name $pName -Value $new
                }
            }
        }
    }
}

function Get-OneDriveAccountRegistrySnapshot {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account
    )

    $regPath = $Account.RegistryPath
    $snapshot = [ordered]@{
        UserFolder  = (Get-ItemProperty -Path $regPath -Name 'UserFolder' -ErrorAction SilentlyContinue).UserFolder
        CacheValues = @{}
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
                (Test-OneDrivePathUnderRoot -Path $cur -Root $Account.UserFolder)) {
                $snapshot.CacheValues["$cacheKey|$pName"] = $cur
            }
        }
    }

    return [pscustomobject]$snapshot
}

function Restore-OneDriveAccountRegistrySnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account,
        [Parameter(Mandatory)][pscustomobject]$Snapshot
    )

    $regPath = $Account.RegistryPath
    if ($PSCmdlet.ShouldProcess("$regPath\UserFolder", "Restore -> $($Snapshot.UserFolder)")) {
        Set-ItemProperty -Path $regPath -Name 'UserFolder' -Value $Snapshot.UserFolder -Type String
    }

    foreach ($entry in $Snapshot.CacheValues.GetEnumerator()) {
        $parts = $entry.Key -split '\|', 2
        $cacheKey = $parts[0]
        $pName = $parts[1]
        if ($PSCmdlet.ShouldProcess("$cacheKey\$pName", "Restore -> $($entry.Value)")) {
            Set-ItemProperty -Path $cacheKey -Name $pName -Value $entry.Value
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
            if (Test-OneDrivePathUnderRoot -Path $cur -Root $OldRoot) {
                $new = $NewRoot + $cur.Substring($OldRoot.Length)
                if ($PSCmdlet.ShouldProcess("$key\$pName", "Rewrite '$cur' -> '$new'")) {
                    # User Shell Folders uses ExpandString templates; Shell
                    # Folders is plain String. Preserve whichever type the
                    # value already had.
                    $keyItem = Get-Item -LiteralPath $key
                    if ($keyItem.PSObject.Methods.Name -contains 'GetValueKind') {
                        $kind = $keyItem.GetValueKind($pName)
                    } elseif (($keyItem.PSObject.Properties.Name -contains 'GetValueKind') -and ($keyItem.GetValueKind -is [scriptblock])) {
                        $kind = & $keyItem.GetValueKind $pName
                    } else {
                        $kind = if ($leaf -eq 'User Shell Folders') { 'ExpandString' } else { 'String' }
                    }
                    Set-ItemProperty -Path $key -Name $pName -Value $new -Type $kind
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

function Get-OneDriveRegistryStringValuesUnderPath {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    $keys = @([pscustomobject]@{ PSPath = $Path }) + @(Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue)
    foreach ($key in $keys) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($pName in $props.PSObject.Properties.Name) {
            if ($pName -like 'PS*') { continue }
            $value = $props.$pName
            if ($value -is [string] -and [System.IO.Path]::IsPathRooted($value)) {
                $results.Add([pscustomobject]@{
                    KeyPath    = $key.PSPath
                    ValueName  = $pName
                    Value      = $value
                }) | Out-Null
            }
        }
    }
    return $results.ToArray()
}

function New-OneDriveRegistryBackupPath {
    [OutputType([string])]
    [CmdletBinding()]
    param()

    $dir = Join-Path $env:LOCALAPPDATA 'MarkMichaelis\OneDriveMigration'
    return (Join-Path $dir ("backup-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Invoke-RegExportCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$OutputPath
    )

    & reg.exe export $SubKey $OutputPath /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe export failed for '$SubKey' (exit $LASTEXITCODE)."
    }
}

function ConvertTo-OneDriveRegistryProviderPath {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubKey
    )

    if ($SubKey -like 'HKCU\*') {
        return ('Registry::HKEY_CURRENT_USER\{0}' -f $SubKey.Substring(5))
    }

    if ($SubKey -like 'HKLM\*') {
        return ('Registry::HKEY_LOCAL_MACHINE\{0}' -f $SubKey.Substring(5))
    }

    throw "Unsupported registry hive in backup key '$SubKey'."
}

function Export-OneDriveRegistryBackup {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath
    )

    $subKeys = @(
        'HKCU\Software\Microsoft\OneDrive\Accounts',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions',
        'HKCU\SOFTWARE\Policies\Microsoft\OneDrive',
        'HKLM\SOFTWARE\Policies\Microsoft\OneDrive'
    )

    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Set-Content -Path $OutputPath -Value "Windows Registry Editor Version 5.00`r`n" -Encoding ascii
    $index = 0
    foreach ($subKey in $subKeys) {
        $index++
        $providerPath = ConvertTo-OneDriveRegistryProviderPath -SubKey $subKey
        if (-not (Test-Path -LiteralPath $providerPath)) {
            continue
        }

        $scratch = Join-Path $dir ("backup-part-{0:00}.reg" -f $index)
        Invoke-RegExportCommand -SubKey $subKey -OutputPath $scratch
        $content = Get-Content -Path $scratch -Raw -ErrorAction Stop
        $content = $content -replace '^Windows Registry Editor Version 5\.00\s*', ''
        Add-Content -Path $OutputPath -Value "`r`n$content" -Encoding ascii
        Remove-Item -LiteralPath $scratch -Force
    }

    return $OutputPath
}

function Get-OneDriveFileAttributes {
    [OutputType([System.IO.FileAttributes])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    return [System.IO.File]::GetAttributes($Path)
}

function Get-OneDrivePlaceholderCount {
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) { return 0 }

    $count = 0
    foreach ($file in @(Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue)) {
        $attrs = Get-OneDriveFileAttributes -Path $file.FullName
        if (($attrs -band 0x00400000) -or ($attrs -band 0x00001000)) {
            $count++
        }
    }
    return $count
}

function Get-OneDriveSharePointSiteList {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [Parameter(Mandatory)][string]$RootDir
    )

    $sites = New-Object System.Collections.Generic.List[object]
    foreach ($account in $Accounts) {
        if ($account.AccountType -ne 'Business' -or -not $account.TenantId -or -not $account.DisplayName) { continue }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $paths = New-Object System.Collections.Generic.List[string]

        $tenantRoot = Join-Path $account.RegistryPath ("Tenants\{0}" -f $account.TenantId)
        foreach ($entry in @(Get-OneDriveRegistryStringValuesUnderPath -Path $tenantRoot)) {
            if ($entry.Value -and $entry.Value -ne $account.UserFolder -and $seen.Add($entry.Value)) {
                $paths.Add($entry.Value) | Out-Null
            }
        }

        foreach ($cacheLeaf in 'ScopeIdToMountPointPathCache','ScopeIdToMountPointPathCacheRoot') {
            $cacheKey = Join-Path $account.RegistryPath $cacheLeaf
            foreach ($entry in @(Get-OneDriveRegistryStringValuesUnderPath -Path $cacheKey)) {
                if ($entry.Value -and $entry.Value -ne $account.UserFolder -and $seen.Add($entry.Value)) {
                    $paths.Add($entry.Value) | Out-Null
                }
            }
        }

        foreach ($pathValue in $paths) {
            $leafName = Split-Path -Leaf $pathValue
            if ([string]::IsNullOrWhiteSpace($leafName)) { continue }
            $desiredPath = [System.IO.Path]::Combine($RootDir, $account.DisplayName, $leafName)
            $sites.Add([pscustomobject]@{
                OwnerAccount = $account
                CurrentPath  = $pathValue
                LeafName     = $leafName
                DesiredPath  = $desiredPath
            }) | Out-Null
        }
    }

    return $sites.ToArray()
}

function Update-OneDriveSharePointCache {
    <#
    .SYNOPSIS
        Rewrite cached SharePoint mount-point paths after a move.
    .NOTES
        Mutates OneDrive client internal ScopeIdToMountPointPathCache*
        values. Microsoft does not document these as supported migration
        APIs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account,
        [Parameter(Mandatory)][string]$OldPath,
        [Parameter(Mandatory)][string]$NewPath
    )

    $candidateRoots = @(
        (Join-Path $Account.RegistryPath ("Tenants\{0}" -f $Account.TenantId)),
        (Join-Path $Account.RegistryPath 'ScopeIdToMountPointPathCache'),
        (Join-Path $Account.RegistryPath 'ScopeIdToMountPointPathCacheRoot')
    )

    foreach ($root in $candidateRoots) {
        foreach ($entry in @(Get-OneDriveRegistryStringValuesUnderPath -Path $root)) {
            if (Test-OneDrivePathUnderRoot -Path $entry.Value -Root $OldPath) {
                $newValue = $NewPath + $entry.Value.Substring($OldPath.Length)
                if ($PSCmdlet.ShouldProcess("$($entry.KeyPath)\$($entry.ValueName)", "Rewrite '$($entry.Value)' -> '$newValue'")) {
                    Set-ItemProperty -Path $entry.KeyPath -Name $entry.ValueName -Value $newValue -Type String
                }
            }
        }
    }
}

function New-OneDriveVerificationCheck {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Fail','Skip')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )

    return [pscustomobject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }
}

function Invoke-OneDriveMigrationVerification {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan
    )

    $checks = New-Object System.Collections.Generic.List[object]
    $accounts = @(Get-OneDriveAccountList)
    $rootDirItem = $Plan | Where-Object { $_.Type -eq 'CreateDir' -and -not $_.Account } | Select-Object -First 1
    $rootDir = if ($rootDirItem) { $rootDirItem.DesiredValue } else { $null }

    $accountFailures = New-Object System.Collections.Generic.List[string]
    $verifiableAccounts = @($accounts | Where-Object { $_.AccountType -in @('Business','Personal') })
    if (-not $rootDir) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'A. Account UserFolder registry targets' -Status 'Skip' -Detail 'RootDir could not be inferred from the plan.')) | Out-Null
    } elseif ($verifiableAccounts.Count -eq 0) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'A. Account UserFolder registry targets' -Status 'Skip' -Detail 'No OneDrive accounts require verification.')) | Out-Null
    } else {
        foreach ($account in $verifiableAccounts) {
            $desired = Get-OneDriveTargetPath -Account $account -RootDir $rootDir
            $actual = (Get-ItemProperty -Path $account.RegistryPath -Name 'UserFolder' -ErrorAction SilentlyContinue).UserFolder
            $actualTrimmed = if ($actual) { $actual.TrimEnd('\') } else { $actual }
            $desiredTrimmed = if ($desired) { $desired.TrimEnd('\') } else { $desired }
            if (-not [string]::Equals($actualTrimmed, $desiredTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                $accountFailures.Add("$($account.Slot): '$actual' != '$desired'") | Out-Null
            }
        }
        $checks.Add((New-OneDriveVerificationCheck -Name 'A. Account UserFolder registry targets' -Status $(if ($accountFailures.Count -eq 0) { 'Pass' } else { 'Fail' }) -Detail $(if ($accountFailures.Count -eq 0) { "Verified $($verifiableAccounts.Count) account target(s)." } else { $accountFailures -join '; ' }))) | Out-Null
    }

    $tenantCreateItems = @($Plan | Where-Object { $_.Type -eq 'CreateDir' -and $_.Account -and $_.Account.AccountType -eq 'Business' })
    if ($tenantCreateItems.Count -eq 0) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'B. Tenant directory existence' -Status 'Skip' -Detail 'No tenant-display-name folders were planned.')) | Out-Null
    } else {
        $missingTenantDirs = @($tenantCreateItems | Where-Object { -not (Test-Path $_.Target) } | ForEach-Object { $_.Target })
        $checks.Add((New-OneDriveVerificationCheck -Name 'B. Tenant directory existence' -Status $(if ($missingTenantDirs.Count -eq 0) { 'Pass' } else { 'Fail' }) -Detail $(if ($missingTenantDirs.Count -eq 0) { "Verified $($tenantCreateItems.Count) tenant folder(s)." } else { 'Missing: ' + ($missingTenantDirs -join '; ') }))) | Out-Null
    }

    $rewriteKfmItem = $Plan | Where-Object { $_.Type -eq 'RewriteKfm' } | Select-Object -First 1
    if (-not $rewriteKfmItem -or -not $rewriteKfmItem.DesiredValue) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'C. KFM owner binding' -Status 'Skip' -Detail 'KFM tracking verification was not applicable.')) | Out-Null
    } else {
        $documentsPath = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name 'Personal' -ErrorAction SilentlyContinue).Personal
        $kfmPass = $documentsPath -and (Test-OneDrivePathUnderRoot -Path $documentsPath -Root $rewriteKfmItem.DesiredValue)
        $checks.Add((New-OneDriveVerificationCheck -Name 'C. KFM owner binding' -Status $(if ($kfmPass) { 'Pass' } else { 'Fail' }) -Detail $(if ($kfmPass) { "Documents resolves under '$($rewriteKfmItem.DesiredValue)'." } else { "Documents path '$documentsPath' does not resolve under '$($rewriteKfmItem.DesiredValue)'." }))) | Out-Null
    }

    $policyItems = @($Plan | Where-Object { $_.Type -eq 'WritePolicy' -and $_.PolicyKind -eq 'DefaultRootDir' })
    if ($policyItems.Count -eq 0) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'D. DefaultRootDir policy' -Status 'Skip' -Detail 'No tenant DefaultRootDir policy writes were planned.')) | Out-Null
    } else {
        $policyFailures = New-Object System.Collections.Generic.List[string]
        foreach ($item in $policyItems) {
            $actual = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' -Name $item.Account.TenantId -ErrorAction SilentlyContinue).$($item.Account.TenantId)
            if (-not [string]::Equals(($actual ?? '').TrimEnd('\'), ($item.DesiredValue ?? '').TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                $policyFailures.Add("$($item.Account.TenantId): '$actual' != '$($item.DesiredValue)'") | Out-Null
            }
        }
        $checks.Add((New-OneDriveVerificationCheck -Name 'D. DefaultRootDir policy' -Status $(if ($policyFailures.Count -eq 0) { 'Pass' } else { 'Fail' }) -Detail $(if ($policyFailures.Count -eq 0) { "Verified $($policyItems.Count) policy value(s)." } else { $policyFailures -join '; ' }))) | Out-Null
    }

    $sharePointMoves = @($Plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.SharePointSite -and $_.Status -eq 'Done' -and $_.CurrentValue })
    if ($sharePointMoves.Count -eq 0) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'E. SharePoint cache old-root purge' -Status 'Skip' -Detail 'No SharePoint site moves completed in this plan.')) | Out-Null
    } else {
        $cacheFailures = New-Object System.Collections.Generic.List[string]
        foreach ($move in $sharePointMoves) {
            foreach ($account in $accounts) {
                foreach ($cacheLeaf in 'ScopeIdToMountPointPathCache','ScopeIdToMountPointPathCacheRoot') {
                    $cacheKey = Join-Path $account.RegistryPath $cacheLeaf
                    foreach ($entry in @(Get-OneDriveRegistryStringValuesUnderPath -Path $cacheKey)) {
                        if (Test-OneDrivePathUnderRoot -Path $entry.Value -Root $move.CurrentValue) {
                            $cacheFailures.Add("$($entry.KeyPath)\\$($entry.ValueName) still references '$($move.CurrentValue)' via '$($entry.Value)'") | Out-Null
                        }
                    }
                }
            }
        }
        $checks.Add((New-OneDriveVerificationCheck -Name 'E. SharePoint cache old-root purge' -Status $(if ($cacheFailures.Count -eq 0) { 'Pass' } else { 'Fail' }) -Detail $(if ($cacheFailures.Count -eq 0) { "Verified $($sharePointMoves.Count) SharePoint move(s)." } else { $cacheFailures -join '; ' }))) | Out-Null
    }

    $startItem = $Plan | Where-Object { $_.Type -eq 'StartOneDrive' } | Select-Object -First 1
    $shouldBeRunning = [bool]($startItem -and -not $startItem.Skipped -and $startItem.Status -eq 'Done')
    $isRunning = [bool](Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)
    $checks.Add((New-OneDriveVerificationCheck -Name 'F. OneDrive.exe running state' -Status $(if ($isRunning -eq $shouldBeRunning) { 'Pass' } else { 'Fail' }) -Detail $(if ($isRunning -eq $shouldBeRunning) { "OneDrive running state matched expectation ($shouldBeRunning)." } else { "Expected running=$shouldBeRunning but observed running=$isRunning." }))) | Out-Null

    $failedChecks = @($checks | Where-Object Status -eq 'Fail')
    $overallStatus = if ($failedChecks.Count -gt 0) {
        'Fail'
    } elseif (@($checks | Where-Object Status -eq 'Pass').Count -gt 0) {
        'Pass'
    } else {
        'Skip'
    }

    return [pscustomobject]@{
        Checks        = $checks.ToArray()
        OverallStatus = $overallStatus
        FailedChecks  = $failedChecks
    }
}

# ---------------------------------------------------------------------------
# Main orchestration. Skipped when the script is dot-sourced (so unit
# tests can pull in just the helper functions above).
# ---------------------------------------------------------------------------

function New-OneDriveMigrationPlanItem {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Target,
        [AllowNull()]$CurrentValue,
        [AllowNull()]$DesiredValue,
        [AllowNull()]$SameVolume,
        [AllowNull()][pscustomobject]$Account,
        [Parameter(Mandatory)][string]$Reason,
        $Skipped = $false,
        [AllowNull()][string]$SkipReason,
        [string[]]$Warnings = @()
    )

    return [pscustomobject]@{
        Type          = $Type
        Target        = $Target
        CurrentValue  = $CurrentValue
        DesiredValue  = $DesiredValue
        SameVolume    = $SameVolume
        Account       = $Account
        Reason        = $Reason
        Skipped       = [bool]$Skipped
        SkipReason    = $SkipReason
        Warnings      = @($Warnings)
        Status        = if ($Skipped) { 'Skipped' } else { 'Pending' }
        FailureReason = $null
    }
}

function Set-OneDriveTenantDefaultRootDirPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account,
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

    $target = [System.IO.Path]::Combine($RootDir, ("OneDrive - {0}" -f $Account.DisplayName))
    if ($PSCmdlet.ShouldProcess("$hkcuDefRoot\$($Account.TenantId)", "Set DefaultRootDir -> $target")) {
        Set-ItemProperty -Path $hkcuDefRoot -Name $Account.TenantId -Value $target -Type String
    }
}

function Set-OneDriveUpdateRingPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $hklmPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    if (-not (Test-Path $hklmPolicy)) {
        if ($PSCmdlet.ShouldProcess($hklmPolicy, 'Create registry key')) {
            try { New-Item -Path $hklmPolicy -Force | Out-Null } catch {
                Write-Warning "Could not create $hklmPolicy (requires elevation): $($_.Exception.Message)"
                return
            }
        }
    }
    if ($PSCmdlet.ShouldProcess("$hklmPolicy\GPOSetUpdateRing", 'Set DWord = 5 (Production ring; standard update cadence)')) {
        try {
            Set-ItemProperty -Path $hklmPolicy -Name 'GPOSetUpdateRing' -Value 5 -Type DWord
        } catch {
            Write-Warning "Could not set GPOSetUpdateRing (requires elevation): $($_.Exception.Message)"
        }
    }
}

function New-OneDriveMigrationPlan {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [AllowEmptyCollection()][object[]]$SharePointSites = @(),
        [AllowNull()][string]$KfmCurrentPath,
        [Parameter(Mandatory)][pscustomobject]$KfmDecision,
        [bool]$WasRunning
    )

    $plan = New-Object System.Collections.Generic.List[object]
    $executionItems = New-Object System.Collections.Generic.List[object]
    $moveItemsBySlot = @{}

    $rootExists = Test-Path $RootDir
    $plan.Add((New-OneDriveMigrationPlanItem -Type 'CreateDir' -Target $RootDir -CurrentValue $(if ($rootExists) { $RootDir } else { $null }) -DesiredValue $RootDir -SameVolume $null -Account $null -Reason 'Ensure the canonical OneDrive root exists.' -Skipped:$rootExists -SkipReason $(if ($rootExists) { 'Directory already exists.' } else { $null }))) | Out-Null
    $plan.Add((New-OneDriveMigrationPlanItem -Type 'HardenRootDirAcl' -Target $RootDir -CurrentValue $RootDir -DesiredValue $RootDir -SameVolume $null -Account $null -Reason 'Re-assert the home-directory ACL on the canonical OneDrive root. Runs even when the root already exists, in case it inherited a world-readable drive-root ACL.')) | Out-Null

    foreach ($a in $Accounts) {
        if ($a.AccountType -ne 'Business' -or [string]::IsNullOrWhiteSpace($a.DisplayName)) { continue }
        $tenantDir = [System.IO.Path]::Combine($RootDir, $a.DisplayName)
        $tenantExists = Test-Path $tenantDir
        $plan.Add((New-OneDriveMigrationPlanItem -Type 'CreateDir' -Target $tenantDir -CurrentValue $(if ($tenantExists) { $tenantDir } else { $null }) -DesiredValue $tenantDir -SameVolume $null -Account $a -Reason 'Create the bare tenant directory used for SharePoint sibling nesting.' -Skipped:$tenantExists -SkipReason $(if ($tenantExists) { 'Directory already exists.' } else { $null }))) | Out-Null
    }

    $hkcuDefRoot = 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir'
    foreach ($acct in $Accounts) {
        if ($acct.AccountType -ne 'Business' -or -not $acct.TenantId -or -not $acct.DisplayName) { continue }
        $target = [System.IO.Path]::Combine($RootDir, ("OneDrive - {0}" -f $acct.DisplayName))
        $current = (Get-ItemProperty -Path $hkcuDefRoot -Name $acct.TenantId -ErrorAction SilentlyContinue).$($acct.TenantId)
        $item = New-OneDriveMigrationPlanItem -Type 'WritePolicy' -Target "$hkcuDefRoot\$($acct.TenantId)" -CurrentValue $current -DesiredValue $target -SameVolume $null -Account $acct -Reason 'Keep OneDrive tenant redirection pinned to the canonical target path.' -Skipped:($current -eq $target) -SkipReason $(if ($current -eq $target) { 'Policy already matches desired tenant target.' } else { $null })
        $item | Add-Member -NotePropertyName PolicyKind -NotePropertyValue 'DefaultRootDir'
        $plan.Add($item) | Out-Null
    }

    $hklmPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    $existingRing = (Get-ItemProperty -Path $hklmPolicy -Name 'GPOSetUpdateRing' -ErrorAction SilentlyContinue).GPOSetUpdateRing
    $ringItem = New-OneDriveMigrationPlanItem -Type 'WritePolicy' -Target "$hklmPolicy\GPOSetUpdateRing" -CurrentValue $existingRing -DesiredValue 5 -SameVolume $null -Account $null -Reason 'Keep OneDrive on the Production update ring (standard cadence).' -Skipped:($existingRing -eq 5) -SkipReason $(if ($existingRing -eq 5) { 'Update ring already set to Production.' } else { $null })
    $ringItem | Add-Member -NotePropertyName PolicyKind -NotePropertyValue 'GPOSetUpdateRing'
    $plan.Add($ringItem) | Out-Null

    foreach ($a in $Accounts) {
        $target = Get-OneDriveTargetPath -Account $a -RootDir $RootDir
        $sourceExists = $a.UserFolder -and (Test-Path $a.UserFolder)
        $alreadyTarget = $a.UserFolder -and ($a.UserFolder.TrimEnd('\') -ieq $target.TrimEnd('\'))
        $sameVolume = if ($sourceExists) { Test-IsSameVolume -Source $a.UserFolder -Destination $target } else { $null }
        $moveSkipReason = $null
        $moveWarnings = @()
        if (-not $a.UserFolder) {
            $moveSkipReason = 'Account has no UserFolder.'
        } elseif ($alreadyTarget) {
            $moveSkipReason = 'Current path already matches the canonical target.'
        } elseif (-not $sourceExists) {
            $moveSkipReason = 'Source folder is missing; migration skipped for safety.'
        }
        if (-not $moveSkipReason -and -not $sameVolume) {
            $placeholderCount = Get-OneDrivePlaceholderCount -Path $a.UserFolder
            if ($placeholderCount -gt 0) {
                $moveSkipReason = "Refusing cross-volume move of $placeholderCount cloud-only files; use OneDrive UI re-link or make the files available offline first."
            }
        }

        $moveItem = New-OneDriveMigrationPlanItem -Type 'MoveAccount' -Target $target -CurrentValue $a.UserFolder -DesiredValue $target -SameVolume $sameVolume -Account $a -Reason 'Move the account sync root to the canonical target path.' -Skipped:([bool]$moveSkipReason) -SkipReason $moveSkipReason -Warnings $moveWarnings
        $moveItem | Add-Member -NotePropertyName SharePointSite -NotePropertyValue $false
        $executionItems.Add($moveItem) | Out-Null
        $moveItemsBySlot[$a.Slot] = $moveItem

        $regCurrent = (Get-ItemProperty -Path $a.RegistryPath -Name 'UserFolder' -ErrorAction SilentlyContinue).UserFolder
        $regSkipReason = if ($regCurrent -eq $target) {
            'Account registry already points at the canonical target.'
        } elseif ($moveItem.Skipped -and -not $alreadyTarget) {
            $moveItem.SkipReason
        } else {
            $null
        }
        $regItem = New-OneDriveMigrationPlanItem -Type 'UpdateAccountRegistry' -Target "$($a.RegistryPath)\UserFolder" -CurrentValue $regCurrent -DesiredValue $target -SameVolume $sameVolume -Account $a -Reason 'Rewrite OneDrive account registry paths after the move.' -Skipped:([bool]$regSkipReason) -SkipReason $regSkipReason
        $regItem | Add-Member -NotePropertyName MoveItem -NotePropertyValue $moveItem
        $executionItems.Add($regItem) | Out-Null

        if ($AppFixUps.Count -gt 0) {
            $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'AppFixUp' -Target $target -CurrentValue $a.UserFolder -DesiredValue $target -SameVolume $sameVolume -Account $a -Reason 'Run application-specific path fix-ups after the move.' -Skipped:$moveItem.Skipped -SkipReason $moveItem.SkipReason)) | Out-Null
        }
    }
    foreach ($site in $SharePointSites) {
        $sourceExists = $site.CurrentPath -and (Test-Path $site.CurrentPath)
        $alreadyTarget = $site.CurrentPath -and ($site.CurrentPath.TrimEnd('\') -ieq $site.DesiredPath.TrimEnd('\'))
        $sameVolume = if ($sourceExists) { Test-IsSameVolume -Source $site.CurrentPath -Destination $site.DesiredPath } else { $null }
        $moveSkipReason = $null
        $moveWarnings = @()
        if (-not $site.CurrentPath) {
            $moveSkipReason = 'SharePoint site has no current mount path.'
        } elseif ($alreadyTarget) {
            $moveSkipReason = 'SharePoint site already matches the canonical target.'
        } elseif (-not $sourceExists) {
            $moveSkipReason = 'SharePoint site source folder is missing; migration skipped for safety.'
        }
        if (-not $moveSkipReason -and -not $sameVolume) {
            $placeholderCount = Get-OneDrivePlaceholderCount -Path $site.CurrentPath
            if ($placeholderCount -gt 0) {
                $moveSkipReason = "Refusing cross-volume move of $placeholderCount cloud-only files; use OneDrive UI re-link or make the files available offline first."
            }
        }
        $moveItem = New-OneDriveMigrationPlanItem -Type 'MoveAccount' -Target $site.DesiredPath -CurrentValue $site.CurrentPath -DesiredValue $site.DesiredPath -SameVolume $sameVolume -Account $site.OwnerAccount -Reason 'Move the SharePoint site/library mount to the canonical tenant sibling path.' -Skipped:([bool]$moveSkipReason) -SkipReason $moveSkipReason -Warnings $moveWarnings
        $moveItem = New-OneDriveMigrationPlanItem -Type 'MoveAccount' -Target $site.DesiredPath -CurrentValue $site.CurrentPath -DesiredValue $site.DesiredPath -SameVolume $sameVolume -Account $site.OwnerAccount -Reason 'Move the SharePoint site/library mount to the canonical tenant sibling path.' -Skipped:([bool]$moveSkipReason) -SkipReason $moveSkipReason -Warnings $moveWarnings
        $moveItem | Add-Member -NotePropertyName SharePointSite -NotePropertyValue $true
        $moveItem | Add-Member -NotePropertyName Site -NotePropertyValue $site
        $executionItems.Add($moveItem) | Out-Null

        $rewriteSkipReason = if ($moveItem.Skipped) { $moveItem.SkipReason } else { $null }
        $rewriteItem = New-OneDriveMigrationPlanItem -Type 'RewriteSPCache' -Target $site.DesiredPath -CurrentValue $site.CurrentPath -DesiredValue $site.DesiredPath -SameVolume $sameVolume -Account $site.OwnerAccount -Reason 'Rewrite SharePoint mount-point cache entries after the site move.' -Skipped:([bool]$rewriteSkipReason) -SkipReason $rewriteSkipReason
        $rewriteItem | Add-Member -NotePropertyName Site -NotePropertyValue $site
        $rewriteItem | Add-Member -NotePropertyName MoveItem -NotePropertyValue $moveItem
        $executionItems.Add($rewriteItem) | Out-Null
    }

    if ($KfmDecision.Action -eq 'Track' -and $KfmDecision.OwnerAccount) {
        $ownerTarget = Get-OneDriveTargetPath -Account $KfmDecision.OwnerAccount -RootDir $RootDir
        $ownerMoveItem = $moveItemsBySlot[$KfmDecision.OwnerAccount.Slot]
        $skipReason = if (-not $ownerMoveItem) {
            'Owner account is not moving.'
        } elseif ($ownerMoveItem.Skipped) {
            $ownerMoveItem.SkipReason
        } else {
            $null
        }
        $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'RewriteKfm' -Target $ownerTarget -CurrentValue $KfmDecision.OwnerAccount.UserFolder -DesiredValue $ownerTarget -SameVolume $ownerMoveItem.SameVolume -Account $KfmDecision.OwnerAccount -Reason 'Keep KFM bound to the owner account after that account moves.' -Skipped:([bool]$skipReason) -SkipReason $skipReason)) | Out-Null
    } elseif ($KfmDecision.Action -eq 'WarnOnly') {
        $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'RewriteKfm' -Target 'KFM' -CurrentValue $KfmCurrentPath -DesiredValue $null -SameVolume $null -Account $KfmDecision.OwnerAccount -Reason 'Leave KFM on its current non-owner path for the OneDrive UI to reconfigure.' -Skipped:$true -SkipReason $KfmDecision.Reason -Warnings @($KfmDecision.Reason))) | Out-Null
    } else {
        $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'RewriteKfm' -Target 'KFM' -CurrentValue $KfmCurrentPath -DesiredValue $null -SameVolume $null -Account $KfmDecision.OwnerAccount -Reason 'No KFM rewrite required.' -Skipped:$true -SkipReason $KfmDecision.Reason)) | Out-Null
    }

    $needsBackup = @($plan | Where-Object { -not $_.Skipped -and $_.Type -in @('CreateDir','WritePolicy') }).Count -gt 0 -or
                   @($executionItems | Where-Object { -not $_.Skipped -and $_.Type -in @('MoveAccount','UpdateAccountRegistry','RewriteSPCache','RewriteKfm','AppFixUp') }).Count -gt 0
    $plan.Insert(0, (New-OneDriveMigrationPlanItem -Type 'RegistryBackup' -Target (New-OneDriveRegistryBackupPath) -CurrentValue $null -DesiredValue $null -SameVolume $null -Account $null -Reason 'Export a registry backup before any mutations.' -Skipped:(-not $needsBackup) -SkipReason $(if (-not $needsBackup) { 'No registry-affecting mutations are required.' } else { $null })))

    $needsStopStart = @($executionItems | Where-Object { -not $_.Skipped -and $_.Type -in @('MoveAccount','UpdateAccountRegistry','RewriteSPCache','RewriteKfm','AppFixUp') }).Count -gt 0
    $plan.Add((New-OneDriveMigrationPlanItem -Type 'StopOneDrive' -Target 'OneDrive.exe' -CurrentValue $(if ($WasRunning) { 'Running' } else { 'NotRunning' }) -DesiredValue 'Stopped' -SameVolume $null -Account $null -Reason 'Stop OneDrive before mutating sync roots or registry.' -Skipped:(-not $needsStopStart) -SkipReason $(if (-not $needsStopStart) { 'No file or registry mutations are required.' } else { $null }))) | Out-Null
    foreach ($item in $executionItems) {
        $plan.Add($item) | Out-Null
    }
    $startSkipReason = if (-not $needsStopStart) {
        'No file or registry mutations were required.'
    } elseif (-not $WasRunning) {
        'OneDrive was not running before the script started.'
    } else {
        $null
    }
    $plan.Add((New-OneDriveMigrationPlanItem -Type 'StartOneDrive' -Target 'OneDrive.exe' -CurrentValue 'Stopped' -DesiredValue $(if ($WasRunning) { 'Running' } else { 'NotRunning' }) -SameVolume $null -Account $null -Reason 'Restore OneDrive to its pre-run process state.' -Skipped:([bool]$startSkipReason) -SkipReason $startSkipReason)) | Out-Null
    $plan.Add((New-OneDriveMigrationPlanItem -Type 'Verify' -Target 'PostMigration' -CurrentValue $null -DesiredValue $null -SameVolume $null -Account $null -Reason 'Run post-migration verification checks across account registry, tenant folders, KFM, policy, SharePoint cache, and OneDrive.exe state.' -Skipped:(-not $needsStopStart) -SkipReason $(if (-not $needsStopStart) { 'No file or registry mutations were required.' } else { $null }))) | Out-Null

    return $plan.ToArray()
}

function Format-OneDriveMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [AllowEmptyCollection()][AllowNull()][object[]]$Accounts = @(),
        [AllowNull()][string]$RootDir,
        [AllowNull()][string]$KfmOwner,
        [switch]$WhatIfMode,
        [bool]$IsElevated = $true,
        [string]$HomeDir = $env:USERPROFILE
    )

    $headerTag = if ($WhatIfMode) { '[PLAN | -WhatIf]' } else { '[APPLY]' }

    Write-Host ''
    Write-Host ("=== MarkMichaelisOneDriveConfiguration  {0} ===" -f $headerTag)
    if ($IsElevated) {
        Write-Host 'Elevation:     OK (Administrator)'
    } else {
        Write-Host 'Elevation:     NOT ELEVATED'
    }

    if ($RootDir) {
        $rootLine = "RootDir:       $RootDir"
        if ($HomeDir) {
            $homeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($HomeDir))
            $rootRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($RootDir))
            if ($homeRoot -and $rootRoot -and -not [string]::Equals($homeRoot, $rootRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rootLine += "   (cross-volume from $homeRoot -- cloud-only files are skipped)"
            }
        }
        Write-Host $rootLine
    }

    if ($KfmOwner) {
        Write-Host ("KFM owner:     {0}  (Documents/Desktop/Pictures follow this account)" -f $KfmOwner)
    }
    Write-Host 'Update ring:   Production (HKLM)'

    if ($Accounts.Count -gt 0) {
        Write-Host ("Accounts ({0}):" -f $Accounts.Count)
        foreach ($account in $Accounts) {
            $name = if ($account.DisplayName) { $account.DisplayName } elseif ($account.UserEmail) { $account.UserEmail } else { $account.Slot }
            $target = if ($RootDir) { Get-OneDriveTargetPath -Account $account -RootDir $RootDir } else { $null }

            $action = 'PLAN'
            if ($target -and $account.UserFolder) {
                if ($account.UserFolder.TrimEnd('\\') -ieq $target.TrimEnd('\\')) {
                    $action = 'NO-OP'
                } elseif (Test-IsSameVolume -Source $account.UserFolder -Destination $target) {
                    $action = 'MOVE'
                } else {
                    $action = 'MOVE (cross-volume)'
                }
            }
            Write-Host ("  [{0}] {1,-18} -> {2}  {3}  ->  {4}" -f $account.AccountType, $name, $action, $account.UserFolder, $target)
        }
    }

    Write-Host 'Planned OneDrive migration:'
    foreach ($item in $Plan) {
        $status = if ($item.Skipped) { '[Skip]' } else { '[Plan]' }
        Write-Host ("  {0} {1}: {2}" -f $status, $item.Type, $item.Target)
        if ($null -ne $item.CurrentValue -or $null -ne $item.DesiredValue) {
            Write-Host ("      Current: {0}" -f $item.CurrentValue)
            Write-Host ("      Desired: {0}" -f $item.DesiredValue)
        }
        Write-Host ("      Reason : {0}" -f $item.Reason)
        if ($item.SkipReason) {
            Write-Host ("      Skip   : {0}" -f $item.SkipReason)
        }
        foreach ($warning in @($item.Warnings)) {
            Write-Host ("      Warning: {0}" -f $warning)
        }
    }
    Write-Host ''
}

function Invoke-OneDriveMigrationPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [switch]$DeleteSourceOnSuccess
    )
    $deferredCleanupPaths = New-Object System.Collections.Generic.List[string]
    $deferredCleanupPaths = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Plan) {
        if ($item.Skipped) {
            $item.Status = 'Skipped'
            foreach ($warning in @($item.Warnings)) {
                Write-Warning $warning
            }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.Target, "$($item.Type): $($item.Reason)")) {
            $item.Status = 'Skipped'
            $item.SkipReason = 'ShouldProcess declined the operation.'
            continue
        }

        try {
            switch ($item.Type) {
                'RegistryBackup' {
                    Export-OneDriveRegistryBackup -OutputPath $item.Target | Out-Null
                }
                'CreateDir' {
                    if (-not (Test-Path $item.Target)) {
                        New-Item -ItemType Directory -Path $item.Target -Force | Out-Null
                    }
                }
                'HardenRootDirAcl' {
                    Set-RootDirAclFromHome -Path $item.Target
                }
                'WritePolicy' {
                    if ($item.PolicyKind -eq 'DefaultRootDir') {
                        Set-OneDriveTenantDefaultRootDirPolicy -Account $item.Account -RootDir (Split-Path -Parent $item.DesiredValue)
                    } elseif ($item.PolicyKind -eq 'GPOSetUpdateRing') {
                        Set-OneDriveUpdateRingPolicy
                    }
                }
                'StopOneDrive' {
                    Stop-OneDriveExe
                }
                'MoveAccount' {
                    $sameVolume = Test-IsSameVolume -Source $item.CurrentValue -Destination $item.DesiredValue
                    $registrySnapshot = $null
                    if ($sameVolume -and -not $item.SharePointSite) {
                        $registrySnapshot = Get-OneDriveAccountRegistrySnapshot -Account $item.Account
                    }
                    $moveResult = Move-OneDriveFolder -Source $item.CurrentValue -Destination $item.DesiredValue -DeleteSourceOnSuccess:$DeleteSourceOnSuccess
                    if ($moveResult -and $moveResult.DeferredDeletePath) {
                        $deferredCleanupPaths.Add($moveResult.DeferredDeletePath) | Out-Null
                        $item.Warnings += "Manual cleanup pending: $($moveResult.DeferredDeletePath)"
                    }
                    $item | Add-Member -NotePropertyName SameVolume -NotePropertyValue $sameVolume -Force
                    $item | Add-Member -NotePropertyName RegistrySnapshot -NotePropertyValue $registrySnapshot -Force
                }
                'UpdateAccountRegistry' {
                    Update-OneDriveAccountRegistry -Account $item.Account -NewPath $item.DesiredValue
                }
                'RewriteSPCache' {
                    Update-OneDriveSharePointCache -Account $item.Account -OldPath $item.CurrentValue -NewPath $item.DesiredValue
                }
                'RewriteKfm' {
                    if ($item.CurrentValue -and $item.DesiredValue) {
                        Update-KfmBindings -OldRoot $item.CurrentValue -NewRoot $item.DesiredValue
                    }
                    foreach ($warning in @($item.Warnings)) {
                        Write-Warning $warning
                    }
                }
                'AppFixUp' {
                    Invoke-AppFixUps -OldRoot $item.CurrentValue -NewRoot $item.DesiredValue
                }
                'Verify' {
                    $verifyResult = Invoke-OneDriveMigrationVerification -Plan $Plan
                    $item | Add-Member -NotePropertyName VerifyResult -NotePropertyValue $verifyResult -Force
                }
                'StartOneDrive' {
                    Start-OneDriveExe
                }
                default {
                    throw "Unsupported plan item type '$($item.Type)'."
                }
            }
            $item.Status = 'Done'
        } catch {
            $item.Status = 'Failed'
            $item.FailureReason = $_.Exception.Message
            if ($item.Type -in @('UpdateAccountRegistry','RewriteSPCache') -and $item.SameVolume) {
                $moveItem = if ($item.PSObject.Properties.Name -contains 'MoveItem') {
                    $item.MoveItem
                } else {
                    $Plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.Account -and $_.Account.Slot -eq $item.Account.Slot } | Select-Object -First 1
                }
                if ($moveItem -and (Test-Path $moveItem.DesiredValue) -and -not (Test-Path $moveItem.CurrentValue)) {
                    Move-Item -LiteralPath $moveItem.DesiredValue -Destination $moveItem.CurrentValue
                }
                if ($item.Type -eq 'UpdateAccountRegistry' -and $moveItem -and $moveItem.RegistrySnapshot) {
                    Restore-OneDriveAccountRegistrySnapshot -Account $item.Account -Snapshot $moveItem.RegistrySnapshot
                }
            }
            throw
        }
    }

    return [pscustomobject]@{
        DeferredCleanupPaths = $deferredCleanupPaths
        Plan                 = $Plan
    }
}

function Get-OneDrivePlanItemStatusText {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Item
    )

    if ($Item.Type -eq 'Verify' -and ($Item.PSObject.Properties.Name -contains 'VerifyResult')) {
        switch ($Item.VerifyResult.OverallStatus) {
            'Fail' { return "Failed: $($Item.VerifyResult.FailedChecks.Count) check(s)" }
            'Skip' { return 'Skipped: Verification not required.' }
        }
    }

    switch ($Item.Status) {
        'Done' { return 'Done' }
        'Failed' { return "Failed: $($Item.FailureReason)" }
        default {
            if ($Item.SkipReason) {
                return "Skipped: $($Item.SkipReason)"
            }
            return 'Skipped'
        }
    }
}

function Get-OneDriveMigrationSummaryLines {
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SharePointSites,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [AllowEmptyCollection()][string[]]$DeferredCleanupPaths = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $migratedItems = @($Plan | Where-Object { $_.Type -eq 'MoveAccount' })

    $lines.Add('MarkMichaelisOneDriveConfiguration summary:') | Out-Null
    $lines.Add('Execution Summary:') | Out-Null
    $lines.Add(("  - Migrated items planned/executed: {0}" -f $migratedItems.Count)) | Out-Null

    $lines.Add('Discovered Accounts:') | Out-Null
    if ($Accounts.Count -eq 0) {
        $lines.Add('  - none') | Out-Null
    } else {
        foreach ($account in $Accounts) {
            $lines.Add(("  - [{0}] {1} -> {2}" -f $account.AccountType, $account.DisplayName, $account.UserFolder)) | Out-Null
        }
    }

    $lines.Add('Discovered SharePoint Sites:') | Out-Null
    if ($SharePointSites.Count -eq 0) {
        $lines.Add('  - none') | Out-Null
    } else {
        foreach ($site in $SharePointSites) {
            $lines.Add(("  - {0} -> {1}" -f $site.CurrentPath, $site.DesiredPath)) | Out-Null
        }
    }

    $sections = @(
        @{ Name = 'Policy Writes'; Types = @('RegistryBackup','WritePolicy') },
        @{ Name = 'Moves'; Types = @('MoveAccount') },
        @{ Name = 'KFM Rewrites'; Types = @('RewriteKfm') },
        @{ Name = 'SharePoint Cache Rewrites'; Types = @('RewriteSPCache') },
        @{ Name = 'App Fix-ups'; Types = @('AppFixUp') },
        @{ Name = 'Verification Results'; Types = @('Verify') }
    )

    foreach ($section in $sections) {
        $lines.Add("$($section.Name):") | Out-Null
        $items = @($Plan | Where-Object { $section.Types -contains $_.Type })
        if ($items.Count -eq 0) {
            $lines.Add('  - none') | Out-Null
            continue
        }
        foreach ($item in $items) {
            $status = Get-OneDrivePlanItemStatusText -Item $item
            $detail = if ($item.CurrentValue -or $item.DesiredValue) {
                " ($($item.CurrentValue) -> $($item.DesiredValue))"
            } else {
                ''
            }
            $lines.Add(("  - {0} | {1}{2}" -f $status, $item.Target, $detail)) | Out-Null
        }
    }

    $backupItem = $Plan | Where-Object Type -eq 'RegistryBackup' | Select-Object -First 1
    $lines.Add('Backup Location:') | Out-Null
    if ($backupItem) {
        $lines.Add(("  - {0} | {1}" -f (Get-OneDrivePlanItemStatusText -Item $backupItem), $backupItem.Target)) | Out-Null
    } else {
        $lines.Add('  - none') | Out-Null
    }

    $lines.Add('MRU Warning:') | Out-Null
    $lines.Add('  - Office / Snagit / VS recent-file lists may still reference old OneDrive paths.') | Out-Null

    $lines.Add('.migrated-* directories awaiting cleanup:') | Out-Null
    if (@($DeferredCleanupPaths).Count -eq 0) {
        $lines.Add('  - none') | Out-Null
    } else {
        $lines.Add('  - Review these folders after OneDrive restarts and the verification checks pass.') | Out-Null
        $lines.Add('  - Cleanup commands:') | Out-Null
        foreach ($path in @($DeferredCleanupPaths)) {
            $escapedPath = $path -replace "'", "''"
            $lines.Add(("    Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $escapedPath)) | Out-Null
        }
        $lines.Add('  - If you need to recover instead, stop OneDrive, inspect the new target, move the .migrated-* folder back manually, restore the registry backup above, then restart OneDrive.') | Out-Null
    }

    return $lines.ToArray()
}

function Write-OneDriveMigrationSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines
    )

    foreach ($line in $Lines) {
        $color = $null
        if ($line -match ':$') {
            $color = 'Cyan'
        } elseif ($line -like '  - Done*') {
            $color = 'Green'
        } elseif ($line -like '  - Skipped*') {
            $color = 'Yellow'
        } elseif ($line -like '  - Failed*') {
            $color = 'Red'
        }

        try {
            if ($color -and $Host.UI -and $Host.UI.RawUI) {
                Write-Host $line -ForegroundColor $color
            } else {
                Write-Host $line
            }
        } catch {
            Write-Host $line
        }
    }
}

function Write-OneDriveMigrationVerificationSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$VerifyResult
    )

    Write-Host ''
    Write-Host 'Verification checks:'
    $table = ($VerifyResult.Checks | Select-Object Status, Name, Detail | Format-Table -AutoSize | Out-String -Width 220).TrimEnd()
    foreach ($line in ($table -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Host $line
        }
    }
}

# ---------------------------------------------------------------------------
# Open-handle pre-flight: a same-volume folder move is an NTFS directory
# rename, which fails with a sharing violation if any file under the source is
# held open by another process (editor, Office, Snagit, an Explorer window, a
# terminal parked in the tree). The migration stops OneDrive's own processes
# but cannot close third-party apps, so a stray handle aborts the run mid-way.
# These helpers enumerate the open handles BEFORE any mutation so the run can
# fail fast with an actionable list.
#
# CRITICAL: detection must NOT open file contents. Opening a Files-On-Demand
# cloud-only placeholder for read triggers hydration, defeating the script's
# FOD gate. Sysinternals 'handle' enumerates the system handle table directly,
# so it never touches file contents.
# ---------------------------------------------------------------------------

function Test-OneDrivePathUnderRoot {
    <#
    .SYNOPSIS
        Return $true when $Path is the root itself or lives beneath it, using a
        path-separator boundary so 'C:\x\OneDrive - Foo' is NOT treated as being
        under 'C:\x\OneDrive'.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $normRoot = $Root.TrimEnd([char]'\', [char]'/')
    $oic = [System.StringComparison]::OrdinalIgnoreCase
    if ($Path.Equals($normRoot, $oic)) { return $true }
    return $Path.StartsWith($normRoot + [char]'\', $oic) -or $Path.StartsWith($normRoot + [char]'/', $oic)
}

function ConvertFrom-OneDriveHandleOutput {
    <#
    .SYNOPSIS
        Pure parser: turn raw Sysinternals 'handle' output lines into blocker
        records for the file handles that fall under one of the given roots.
    .DESCRIPTION
        Each emitted record is the process name, PID, and object path of an open
        File handle whose path is under one of $Root (boundary-correct match).
        OneDrive's own helper processes are excluded by default because the
        migration stops them itself; pass -IncludeOneDriveProcesses to keep them.
    .OUTPUTS
        PSCustomObject (Process, Id, Path) per blocking handle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line,
        [Parameter(Mandatory)][string[]]$Root,
        [switch]$IncludeOneDriveProcesses
    )

    $oneDriveProcessNames = @('OneDrive', 'OneDrive.Sync.Service', 'FileCoAuth')
    $roots = @($Root | Where-Object { $_ })

    foreach ($entry in $Line) {
        if ($entry -notmatch '^(?<proc>\S+)\s+pid:\s*(?<pid>\d+)\s+type:\s*File\s+\w+:\s*(?<path>.+)$') {
            continue
        }
        $procName = $Matches.proc -replace '\.exe$', ''
        $path = $Matches.path.Trim()

        $underRoot = $false
        foreach ($r in $roots) {
            if (Test-OneDrivePathUnderRoot -Path $path -Root $r) { $underRoot = $true; break }
        }
        if (-not $underRoot) { continue }
        if (-not $IncludeOneDriveProcesses -and $oneDriveProcessNames -contains $procName) { continue }

        [pscustomobject]@{
            Process = $Matches.proc
            Id      = [int]$Matches.pid
            Path    = $path
        }
    }
}

function Resolve-OneDriveHandleExe {
    <#
    .SYNOPSIS
        Resolve the Sysinternals 'handle' executable (handle64.exe / handle.exe)
        on PATH, or $null when it is not installed.
    .OUTPUTS
        System.String (full path) or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $cmd = Get-Command 'handle64.exe', 'handle.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-OneDriveOpenHandleScan {
    <#
    .SYNOPSIS
        Run Sysinternals 'handle' for a search term and return its raw output
        lines. Isolated as a thin wrapper so unit tests can mock the external
        call.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$HandleExe,
        [Parameter(Mandatory)][string]$SearchTerm
    )
    & $HandleExe -accepteula -nobanner $SearchTerm 2>$null
}

function Get-OneDriveMoveBlocker {
    <#
    .SYNOPSIS
        Report the processes holding open file handles under one of the OneDrive
        move-source roots -- the handles that would block a same-volume move.
    .DESCRIPTION
        Resolves Sysinternals 'handle', scans the handle table for the shortest
        common root (handle does a case-insensitive substring match, so one scan
        covers nested roots), then re-filters every line against the full root
        list with a path-separator boundary to avoid prefix bleed. Returns
        nothing -- and warns -- when 'handle' is not installed, so a missing
        optional tool degrades gracefully instead of aborting the migration.
    .OUTPUTS
        PSCustomObject (Process, Id, Path) per blocking handle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [switch]$IncludeOneDriveProcesses
    )

    $roots = @($Root | Where-Object { $_ })
    if (-not $roots) { return }

    $handleExe = Resolve-OneDriveHandleExe
    if (-not $handleExe) {
        Write-Warning "Open-handle pre-flight skipped: Sysinternals 'handle' was not found on PATH (install with 'scoop install sysinternals'). A file left open under a move source could still abort the migration mid-run."
        return
    }

    $searchTerm = ($roots | Sort-Object { $_.Length } | Select-Object -First 1)
    $rawLines = @(Invoke-OneDriveOpenHandleScan -HandleExe $handleExe -SearchTerm $searchTerm |
            Where-Object { $_ -match 'pid:' })

    ConvertFrom-OneDriveHandleOutput -Line $rawLines -Root $roots -IncludeOneDriveProcesses:$IncludeOneDriveProcesses
}

function Get-OneDriveBlockerProcess {
    <#
    .SYNOPSIS
        Collapse the per-handle blocker records into one record per process
        instance (Process + Id), with the handle count and example paths.
    .OUTPUTS
        PSCustomObject (Process, Id, HandleCount, Paths) per blocking process.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Blocker
    )

    $Blocker | Group-Object Id | ForEach-Object {
        [pscustomobject]@{
            Process     = $_.Group[0].Process
            Id          = [int]$_.Name
            HandleCount = $_.Count
            Paths       = @($_.Group.Path)
        }
    } | Sort-Object Process, Id
}

function Write-OneDriveBlockerReport {
    <#
    .SYNOPSIS
        Warn about the processes whose open handles would block a same-volume
        OneDrive folder move, one line per process instance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Process
    )

    Write-Warning 'Open file handles under the OneDrive move source(s) would block the same-volume folder rename:'
    foreach ($p in $Process) {
        $example = $p.Paths | Select-Object -First 1
        Write-Warning ('  {0} (PID {1}) holds {2} open handle(s), e.g. {3}' -f $p.Process, $p.Id, $p.HandleCount, $example)
    }
}

function Read-OneDriveBlockerAction {
    <#
    .SYNOPSIS
        Prompt the user for how to handle the open-handle blockers: stop the
        listed processes, recheck after closing apps manually, or abort.
    .OUTPUTS
        System.String -- one of 'Kill', 'Recheck', 'Abort'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Process
    )

    $kill = [System.Management.Automation.Host.ChoiceDescription]::new(
        '&Kill', 'Stop the listed process(es) now, then recheck.')
    $recheck = [System.Management.Automation.Host.ChoiceDescription]::new(
        '&Recheck', "Recheck after you've closed the apps yourself.")
    $abort = [System.Management.Automation.Host.ChoiceDescription]::new(
        '&Abort', 'Abort the migration without changing anything.')
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@($kill, $recheck, $abort)

    $caption = 'Open file handles block the OneDrive folder move'
    $message = '{0} process(es) hold an open handle. Choose how to proceed:' -f @($Process).Count
    $selection = $Host.UI.PromptForChoice($caption, $message, $choices, 1)

    switch ($selection) {
        0 { 'Kill' }
        1 { 'Recheck' }
        default { 'Abort' }
    }
}

function Invoke-OneDriveMoveBlockerResolution {
    <#
    .SYNOPSIS
        Pre-flight gate: loop until no process holds an open handle under a
        OneDrive move source, prompting the user to stop the offending
        processes or recheck, and aborting (throwing) on request.
    .DESCRIPTION
        On each pass the open handles are rescanned. When blockers remain the
        user is prompted: Kill stops each process (guarded by ShouldProcess so
        it honours -WhatIf / -Confirm), Recheck rescans after the user closes
        apps manually, and Abort throws before any migration mutation. The loop
        exits cleanly once the scan is clear.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]]$Root
    )

    $abortMessage = 'Open file handles still block the OneDrive folder move. Close the listed applications and re-run. No changes were made.'

    while ($true) {
        $blockers = @(Get-OneDriveMoveBlocker -Root $Root)
        if ($blockers.Count -eq 0) { return }

        $processes = @(Get-OneDriveBlockerProcess -Blocker $blockers)
        Write-OneDriveBlockerReport -Process $processes

        $action = Read-OneDriveBlockerAction -Process $processes
        if ($action -eq 'Abort') {
            throw $abortMessage
        }
        if ($action -eq 'Kill') {
            $stopped = 0
            foreach ($p in $processes) {
                $target = '{0} (PID {1})' -f $p.Process, $p.Id
                if ($PSCmdlet.ShouldProcess($target, 'Stop process holding open handle(s) under a OneDrive move source')) {
                    try {
                        Stop-Process -Id $p.Id -Force -ErrorAction Stop
                        $stopped++
                    } catch {
                        Write-Warning ('Failed to stop {0}: {1}' -f $target, $_.Exception.Message)
                    }
                }
            }
            if ($stopped -eq 0) {
                throw $abortMessage
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Invoke-MarkMichaelisOneDriveConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$KfmOwner,
        [switch]$DeleteSourceOnSuccess,
        [bool]$IsElevated = $true
    )

    Write-Warning 'Mutates OneDrive client internal registry state (Accounts\<slot>\UserFolder, ScopeIdToMountPointPathCache*); these are not Microsoft-documented migration APIs.'
    Write-Host "MarkMichaelisOneDriveConfiguration: RootDir=$RootDir, KfmOwner=$KfmOwner"
    $accounts = Get-OneDriveAccountList
    $sharePointSites = Get-OneDriveSharePointSiteList -Accounts $accounts -RootDir $RootDir

    Write-Verbose ("Discovered {0} account(s)." -f $accounts.Count)

    $kfmCurrent = Get-CurrentKfmPath
    $kfmDecision = Resolve-KfmRebindAction -Accounts $accounts -KfmCurrentPath $kfmCurrent -KfmOwner $KfmOwner
    Write-Host "  KFM: [$($kfmDecision.Action)] $($kfmDecision.Reason)"
    if ($kfmDecision.Action -eq 'OwnerNotSignedIn') {
        throw "KFM owner '$KfmOwner' is not signed in. Sign in to the matching Work account in OneDrive and re-run."
    }
    $wasRunning = [bool](Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)
    $plan = New-OneDriveMigrationPlan -RootDir $RootDir -Accounts $accounts -SharePointSites @($sharePointSites) -KfmCurrentPath $kfmCurrent -KfmDecision $kfmDecision -WasRunning:$wasRunning
    Format-OneDriveMigrationPlan -Plan $plan -Accounts $accounts -RootDir $RootDir -KfmOwner $KfmOwner `
        -WhatIfMode:$WhatIfPreference `
        -IsElevated $IsElevated

    $moveSources = @(
        $plan |
            Where-Object { $_.Type -eq 'MoveAccount' -and -not $_.Skipped -and $_.CurrentValue } |
            ForEach-Object { $_.CurrentValue }
    ) | Select-Object -Unique

    if ($moveSources.Count -gt 0) {
        if ($WhatIfPreference) {
            $blockers = @(Get-OneDriveMoveBlocker -Root $moveSources)
            if ($blockers.Count -gt 0) {
                Write-OneDriveBlockerReport -Process (Get-OneDriveBlockerProcess -Blocker $blockers)
                Write-Warning 'WhatIf: a real run would prompt to stop these processes or recheck before moving any folder.'
            }
        } else {
            Invoke-OneDriveMoveBlockerResolution -Root $moveSources
        }
    }

    if ($WhatIfPreference) {
        return $plan
    }

    $backupPath = ($plan | Where-Object Type -eq 'RegistryBackup' | Select-Object -First 1).Target
    $deferredCleanupPaths = @()
    try {
        $execution = Invoke-OneDriveMigrationPlan -Plan $plan -DeleteSourceOnSuccess:$DeleteSourceOnSuccess -Confirm:$false
        $deferredCleanupPaths = @($execution.DeferredCleanupPaths)
    } catch {
        $failedItem = $plan | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 1
        $restartInstruction = "After inspection, restart OneDrive with: Start-Process `"$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe`" -ArgumentList '/background'"
        if ($failedItem -and $failedItem.Type -eq 'UpdateAccountRegistry' -and $failedItem.Account) {
            Write-Error "Migration failed for $($failedItem.Account.DisplayName): $($failedItem.FailureReason) Best-effort rollback attempted. Inspect the old and new paths and verify OneDrive account registry under '$($failedItem.Account.RegistryPath)' before restarting OneDrive. Registry backup: $backupPath. OneDrive NOT restarted automatically. $restartInstruction"
        } elseif ($failedItem) {
            Write-Error "Migration failed during $($failedItem.Type): $($failedItem.FailureReason). Registry backup: $backupPath. OneDrive NOT restarted automatically. $restartInstruction"
        }
        throw
    }

    $summaryLines = Get-OneDriveMigrationSummaryLines -Accounts $accounts -SharePointSites @($sharePointSites) -Plan $plan -DeferredCleanupPaths @($deferredCleanupPaths)
    Write-OneDriveMigrationSummary -Lines $summaryLines

    $verifyItem = $plan | Where-Object Type -eq 'Verify' | Select-Object -First 1
    if ($verifyItem -and ($verifyItem.PSObject.Properties.Name -contains 'VerifyResult')) {
        Write-OneDriveMigrationVerificationSummary -VerifyResult $verifyItem.VerifyResult
        if ($verifyItem.VerifyResult.FailedChecks.Count -gt 0) {
            $failedChecksSummary = ($verifyItem.VerifyResult.FailedChecks | ForEach-Object { "[$($_.Name)] $($_.Detail)" }) -join '; '
            throw "Post-migration verification failed: $failedChecksSummary. Registry backup: $backupPath. Data was already migrated; investigate manually (no rollback performed). Restart OneDrive after inspection with: Start-Process `"$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe`" -ArgumentList '/background'"
        }
    }

    $fodGatedItems = @($plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.SkipReason -like 'Refusing cross-volume move of *cloud-only files*' })
    if ($fodGatedItems.Count -gt 0) {
        Write-Warning ("Files-On-Demand gate blocked {0} cross-volume move(s). Use OneDrive UI re-link or make the files available offline first." -f $fodGatedItems.Count)
        throw "Files-On-Demand gate blocked $($fodGatedItems.Count) move(s). Registry backup: $backupPath."
    }

    Write-Warning 'MRU staleness: Office recent docs / Snagit Recent File List / VS recent files may reference old OneDrive paths; reopen as needed.'
    return $plan
}

# Only run when invoked as a script (Scoop's installer does
# `& "$dir\MarkMichaelisOneDriveConfiguration.ps1"`). When dot-sourced
# (Pester tests), expose the helpers without running migration.
if ($MyInvocation.InvocationName -ne '.') {
    # Suppress the plan object the orchestrator returns: the human-readable
    # summary is already written via Write-Host. Without this, the returned
    # plan array would be echoed to the success stream and auto-formatted into
    # a second, raw object dump on the console. The function still returns the
    # plan for programmatic and test callers that capture it.
    $null = Invoke-MarkMichaelisOneDriveConfiguration -RootDir $RootDir -KfmOwner $KfmOwner -DeleteSourceOnSuccess:$DeleteSourceOnSuccess -IsElevated $__mmodIsElevated
}
