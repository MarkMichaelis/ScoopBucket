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
    4. For each discovered account, either migrates the existing
       UserFolder to the canonical path or unlinks it for fresh-sync.
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
        and normally refuse to hydrate cloud-only placeholders unless
        you explicitly pass -ForceHydrate.
      - Rewrites KFM bindings when the owning account moves or needs an
        explicit rebind.
      - Extensible per-app fix-up hook ($AppFixUps) ships empty; Snagit
        is deliberately NOT included because its CatalogFolder /
        ExternalOutputDir use the logical Documents path and follow KFM
        transparently.

    Robocopy migration vs -FreshSync (the key cross-volume trade-off)
    ----------------------------------------------------------------
    The default action for an account whose UserFolder differs from the
    convention is to migrate the files in place:

      - Same-volume:   Move-Item (NTFS rename, preserves Cloud Files
                       reparse points + ACLs).
      - Cross-volume:  robocopy /E /COPYALL /DCOPY:DAT /ZB.

    Cross-volume migration can materialize Files-On-Demand placeholders.
    Use -FreshSync <slot-or-DisplayName>... as the escape hatch for
    Business accounts whose local tree you would rather discard and
    recreate from the OneDrive UI at the new canonical path.

    Why elevation is required
    -------------------------
    The bundle writes HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
    (GPOSetUpdateRing), which requires Administrator. The script fails
    fast with a clear message if launched without elevation. Pass
    -SkipElevationCheck only if the HKLM policy is already pre-applied
    out-of-band.

    Known Folder Move (KFM) model
    -----------------------------
    KFM redirects Documents, Desktop, and Pictures into a OneDrive
    sync folder. Only one Work account at a time can own KFM. The
    -KfmOwner parameter identifies that canonical Business account and
    KFM is then tracked or rebound to follow that account as needed.
    Personal accounts are never eligible to own KFM.

.PARAMETER RootDir
    Parent directory for all OneDrive sync roots. Default: C:\OneDrive.
    When $RootDir is on a different volume than $env:USERPROFILE,
    file-copy migrations can hydrate Files-On-Demand placeholders.
    Combine with -FreshSync to opt selected cloud-only accounts out of
    that hydration, or pass -ForceHydrate to proceed intentionally.

.PARAMETER KfmOwner
    DisplayName identifying the canonical KFM owner - the Business
    account whose Documents / Desktop / Pictures KFM should follow.
    Default: 'Michaelis'. By default the match is case-insensitive
    equality against Business* registry-slot DisplayName values. Use
    -KfmOwnerContains to opt into case-insensitive substring matching.
    Only the first Business match wins; Personal accounts are never
    eligible.

.PARAMETER KfmOwnerContains
    Treat -KfmOwner as a case-insensitive substring match instead of an
    exact DisplayName match.

.PARAMETER NoKfmRebind
    Suppress the warning + automatic rebind that fires when KFM is
    currently bound to a different account than -KfmOwner. The bundle
    still applies policy and migrates files; only the KFM rewrite is
    skipped.

.PARAMETER NoFolderDescriptionsWrite
    Skip the undocumented writes under
    Explorer\FolderDescriptions\<GUID> and rely only on User Shell
    Folders updates when rebinding KFM.

.PARAMETER FreshSync
    Names (slot names such as 'Business2' or DisplayNames such as
    'IntelliTect') of Business* accounts that should be unlinked
    instead of file-copy-migrated. For each match, the bundle stops
    OneDrive, deletes the per-account registry key
    (HKCU:\Software\Microsoft\OneDrive\Accounts\<Slot>), and renames
    the local UserFolder to <UserFolder>.freshsync-<yyyyMMdd-HHmmss> by
    default so a recovery copy is preserved. Pass -DeleteSourceOnSuccess to
    remove that recovery folder after a successful fresh-sync unlink.
    The user must re-sign-in via the OneDrive UI; the DefaultRootDir
    policy still directs the new sync root to the canonical location,
    and OneDrive recreates cloud-only placeholders without a bulk
    download. Personal accounts are not supported.

.PARAMETER DeleteSourceOnSuccess
    For fresh-sync accounts, delete the recovery folder after a
    successful unlink instead of keeping the renamed
    .freshsync-<yyyyMMdd-HHmmss> backup.

.PARAMETER ForceHydrate
    Allow cross-volume moves that would hydrate cloud-only
    Files-On-Demand placeholders. Without this switch, such moves are
    skipped for safety and reported in the plan.

.PARAMETER SkipElevationCheck
    Bypass the top-level Administrator pre-flight. Use only when the
    HKLM OneDrive policy is already applied (for example by Group
    Policy) and you intentionally want to preview or run the remaining
    per-user work from a non-elevated shell.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -WhatIf

    Default plan-then-execute preview: roots at C:\OneDrive, all
    accounts evaluated for migration, and KFM following Michaelis.
    Shows every move + registry write without changing any state.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -RootDir D:\OneDrive -FreshSync Business2 -WhatIf

    Cross-volume move to D:; Business2 is unlinked instead of copied so
    cloud-only content is recreated by OneDrive after re-sign-in rather
    than hydrated during migration.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -NoKfmRebind

    Apply policy + migrate files but leave current KFM bindings alone.
    Useful when KFM is intentionally bound to a non-default account.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1

    Run for real: compute the plan, export a registry backup, apply
    policy, migrate any mis-located accounts, rewrite KFM, verify the
    result, and restart OneDrive if needed.

.NOTES
    Requires an elevated PowerShell session (Run as Administrator):
    the bundle writes HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
    (GPOSetUpdateRing). Pass -SkipElevationCheck only if the HKLM
    policy is already pre-applied via Group Policy.

    Restarts OneDrive.exe whenever a migration or fresh-sync unlink
    occurs (stops with /shutdown, restarts with /background).

    Cross-volume migrations can hydrate Files-On-Demand placeholders
    unless -FreshSync is used to unlink the affected account or
    -ForceHydrate is explicitly accepted.

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
    [switch] $KfmOwnerContains,
    [switch] $NoKfmRebind,
    [switch] $NoFolderDescriptionsWrite,
    [string[]] $FreshSync = @(),
    [switch] $DeleteSourceOnSuccess,
    [switch] $ForceHydrate,
    [switch] $SkipElevationCheck
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
    if (-not $SkipElevationCheck -and -not $__mmodIsElevated) {
        throw "MarkMichaelisOneDriveConfiguration must be run from an elevated PowerShell session (HKLM policy write requires admin). Re-launch with Run as Administrator, or pass -SkipElevationCheck if you have pre-applied HKLM\SOFTWARE\Policies\Microsoft\OneDrive via Group Policy."
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
        [Parameter(Mandatory)][string]$KfmOwner,
        [switch]$KfmOwnerContains
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        return $false
    }

    if ($KfmOwnerContains) {
        return ($DisplayName.IndexOf($KfmOwner, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }

    return [string]::Equals($DisplayName, $KfmOwner, [System.StringComparison]::OrdinalIgnoreCase)
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
          - $KfmOwnerContains: switch -- use substring matching instead of
            exact DisplayName equality.
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
        [switch]$KfmOwnerContains,
        [switch]$NoKfmRebind
    )

    if (-not $KfmCurrentPath) {
        return [pscustomobject]@{
            Action       = 'None'
            OwnerAccount = $null
            Reason       = "KFM is not currently active; nothing to track."
        }
    }

    $ownerAcct = $Accounts |
        Where-Object { $_.AccountType -ne 'Personal' -and (Test-KfmOwnerMatch -DisplayName $_.DisplayName -KfmOwner $KfmOwner -KfmOwnerContains:$KfmOwnerContains) } |
        Select-Object -First 1

    if (-not $ownerAcct) {
        return [pscustomobject]@{
            Action       = 'OwnerNotSignedIn'
            OwnerAccount = $null
            Reason       = "KfmOwner '$KfmOwner' is not signed in to OneDrive (no Business* slot has matching DisplayName)."
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
# ---------------------------------------------------------------------------# ---------------------------------------------------------------------------
# Side-effectful helpers (registry + filesystem). Each wraps every
# state-changing call in $PSCmdlet.ShouldProcess so -WhatIf works.
# ---------------------------------------------------------------------------

$KnownFolderGuids = @(
    '{F42EE2D3-909F-4907-8871-4C22FC0BF756}',  # Documents
    '{0DDD015D-B06C-45D5-8C4C-F59713854639}',  # Pictures
    '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}',  # Desktop
    '{4BD8D571-6D19-48D3-BE97-422220080E43}',  # Music
    '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}',  # Videos
    '{374DE290-123F-4565-9164-39C4925E467B}',  # Downloads
    '{1777F761-68AD-4D8A-87BD-30B759FA33DD}',  # Favorites
    '{B7BEDE81-DF94-4682-A7D8-57A52620B86F}'   # Screenshots
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

function Set-OneDrivePolicy {
    <#
    .SYNOPSIS
        Apply tenant-redirection policy (DefaultRootDir per Work tenant)
        and the GPOSetUpdateRing policy in HKLM.
    .DESCRIPTION
        Policy shape verified against https://learn.microsoft.com/sharepoint/use-group-policy:
          - DefaultRootDir is a per-user HKCU policy whose value name is the
            tenant GUID and whose value data is the final tenant folder.
          - GPOSetUpdateRing is a machine HKLM policy. Value 5 selects the
            Production ring (standard update cadence).
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
    if ($existingRing -ne 5) {
        if ($PSCmdlet.ShouldProcess("$hklmPolicy\GPOSetUpdateRing", 'Set DWord = 5 (Production ring; standard update cadence)')) {
            try {
                Set-ItemProperty -Path $hklmPolicy -Name 'GPOSetUpdateRing' -Value 5 -Type DWord
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

function Invoke-RobocopyMirror {
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $args = @($Source, $Destination, '/E','/COPYALL','/DCOPY:DAT','/ZB','/R:1','/W:1','/XJ','/NFL','/NDL')
    & robocopy @args | Out-Null
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
        .migrated-* recovery folder and only delete it when explicitly
        requested via -DeleteSourceOnSuccess.
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

    Write-Warning "Cross-volume migration uses robocopy /E /COPYALL first, then renames the original source to a .migrated-* recovery folder. Use -DeleteSourceOnSuccess only after you are comfortable auto-removing that recovery folder."
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
                $cur.StartsWith($Account.UserFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
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
                $cur.StartsWith($Account.UserFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
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
        [Parameter(Mandatory)][string]$NewRoot,
        [switch]$NoFolderDescriptionsWrite
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

    if ($NoFolderDescriptionsWrite) {
        return
    }

    # WARNING: FolderDescriptions\<GUID>\RelativePath and ParsingName are
    # Windows shell internals, not a Microsoft-documented KFM migration
    # interface. The supported KFM mechanism is the KFMSilentOptIn policy +
    # standard User Shell Folders updates. We write here empirically because
    # some apps (notably Office) cache these for known-folder resolution and
    # stale entries cause silent breakage. If a future Windows release removes
    # or relocates these values, drop this block and rely solely on User Shell
    # Folders.
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
        and preserve the local UserFolder as a fresh-sync recovery copy
        so the user can re-sign-in fresh.
    .DESCRIPTION
        Used by -FreshSync to avoid bulk-hydrating Files-On-Demand
        placeholders during a cross-volume migration. Caller is
        responsible for stopping OneDrive.exe first. By default the
        local UserFolder is renamed to <UserFolder>.freshsync-<timestamp>
        so the user retains a recovery copy. Pass -DeleteRecoveryFolder
        to remove that renamed recovery folder after the unlink.
    #>
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Account,
        [switch]$DeleteRecoveryFolder
    )
    $regPath = $Account.RegistryPath
    if ($regPath -and (Test-Path $regPath)) {
        if ($PSCmdlet.ShouldProcess($regPath, "Remove OneDrive account registry key (fresh-sync)")) {
            Remove-Item -LiteralPath $regPath -Recurse -Force
        }
    }
    $folder = $Account.UserFolder
    $recoveryPath = $null
    if ($folder -and (Test-Path $folder)) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $recoveryPath = "$folder.freshsync-$timestamp"
        if ($PSCmdlet.ShouldProcess($folder, "Rename local OneDrive sync folder -> $recoveryPath (fresh-sync recovery)")) {
            Move-Item -LiteralPath $folder -Destination $recoveryPath
        }
        if ($DeleteRecoveryFolder) {
            if ($PSCmdlet.ShouldProcess($recoveryPath, 'Remove-Item -Recurse (fresh-sync recovery cleanup)')) {
                Remove-Item -LiteralPath $recoveryPath -Recurse -Force
                $recoveryPath = $null
            }
        }
    }
    return $recoveryPath
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
            $desiredPath = Join-Path (Join-Path $RootDir $account.DisplayName) $leafName
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
            if ($entry.Value.StartsWith($OldPath, [System.StringComparison]::OrdinalIgnoreCase)) {
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
    $freshSyncSlots = @($Plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.FreshSync } | ForEach-Object { $_.Account.Slot })
    $rootDirItem = $Plan | Where-Object { $_.Type -eq 'CreateDir' -and -not $_.Account } | Select-Object -First 1
    $rootDir = if ($rootDirItem) { $rootDirItem.DesiredValue } else { $null }

    $accountFailures = New-Object System.Collections.Generic.List[string]
    $verifiableAccounts = @($accounts | Where-Object { $_.AccountType -in @('Business','Personal') -and ($freshSyncSlots -notcontains $_.Slot) })
    if (-not $rootDir) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'A. Account UserFolder registry targets' -Status 'Skip' -Detail 'RootDir could not be inferred from the plan.')) | Out-Null
    } elseif ($verifiableAccounts.Count -eq 0) {
        $checks.Add((New-OneDriveVerificationCheck -Name 'A. Account UserFolder registry targets' -Status 'Skip' -Detail 'No non-FreshSync accounts require verification.')) | Out-Null
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
        $checks.Add((New-OneDriveVerificationCheck -Name 'C. KFM owner binding' -Status 'Skip' -Detail 'KFM track/rebind verification was not applicable.')) | Out-Null
    } else {
        $documentsPath = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name 'Personal' -ErrorAction SilentlyContinue).Personal
        $kfmPass = $documentsPath -and $documentsPath.StartsWith($rewriteKfmItem.DesiredValue.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
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
                        if ($entry.Value.StartsWith($move.CurrentValue, [System.StringComparison]::OrdinalIgnoreCase)) {
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

    $target = Join-Path $RootDir ("OneDrive - {0}" -f $Account.DisplayName)
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
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FreshSyncAccounts,
        [AllowEmptyCollection()][object[]]$SharePointSites = @(),
        [AllowNull()][string]$KfmCurrentPath,
        [Parameter(Mandatory)][pscustomobject]$KfmDecision,
        [bool]$WasRunning,
        [switch]$ForceHydrate
    )

    $plan = New-Object System.Collections.Generic.List[object]
    $executionItems = New-Object System.Collections.Generic.List[object]
    $freshSyncSlots = @($FreshSyncAccounts | ForEach-Object { $_.Slot })
    $moveItemsBySlot = @{}

    $rootExists = Test-Path $RootDir
    $plan.Add((New-OneDriveMigrationPlanItem -Type 'CreateDir' -Target $RootDir -CurrentValue $(if ($rootExists) { $RootDir } else { $null }) -DesiredValue $RootDir -SameVolume $null -Account $null -Reason 'Ensure the canonical OneDrive root exists.' -Skipped:$rootExists -SkipReason $(if ($rootExists) { 'Directory already exists.' } else { $null }))) | Out-Null
    $plan.Add((New-OneDriveMigrationPlanItem -Type 'HardenRootDirAcl' -Target $RootDir -CurrentValue $RootDir -DesiredValue $RootDir -SameVolume $null -Account $null -Reason 'Re-assert the home-directory ACL on the canonical OneDrive root. Runs even when the root already exists, in case it inherited a world-readable drive-root ACL.')) | Out-Null

    foreach ($a in $Accounts) {
        if ($freshSyncSlots -contains $a.Slot) { continue }
        if ($a.AccountType -ne 'Business' -or [string]::IsNullOrWhiteSpace($a.DisplayName)) { continue }
        $tenantDir = Join-Path $RootDir $a.DisplayName
        $tenantExists = Test-Path $tenantDir
        $plan.Add((New-OneDriveMigrationPlanItem -Type 'CreateDir' -Target $tenantDir -CurrentValue $(if ($tenantExists) { $tenantDir } else { $null }) -DesiredValue $tenantDir -SameVolume $null -Account $a -Reason 'Create the bare tenant directory used for SharePoint sibling nesting.' -Skipped:$tenantExists -SkipReason $(if ($tenantExists) { 'Directory already exists.' } else { $null }))) | Out-Null
    }

    $hkcuDefRoot = 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir'
    foreach ($acct in $Accounts) {
        if ($acct.AccountType -ne 'Business' -or -not $acct.TenantId -or -not $acct.DisplayName) { continue }
        $target = Join-Path $RootDir ("OneDrive - {0}" -f $acct.DisplayName)
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
        if ($freshSyncSlots -contains $a.Slot) {
            $hasFolder = $a.UserFolder -and (Test-Path $a.UserFolder)
            $moveItem = New-OneDriveMigrationPlanItem -Type 'MoveAccount' -Target $a.UserFolder -CurrentValue $a.UserFolder -DesiredValue $null -SameVolume $null -Account $a -Reason 'Fresh-sync unlink instead of migrating the existing local OneDrive tree.' -Skipped:(-not $hasFolder) -SkipReason $(if (-not $hasFolder) { 'Fresh-sync account has no local folder to remove.' } else { $null })
            $moveItem | Add-Member -NotePropertyName FreshSync -NotePropertyValue $true
            $moveItem | Add-Member -NotePropertyName SharePointSite -NotePropertyValue $false
            $executionItems.Add($moveItem) | Out-Null
            continue
        }

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
                if ($ForceHydrate) {
                    $moveWarnings += "Will hydrate $placeholderCount cloud-only files (~size unknown)."
                } else {
                    $moveSkipReason = "Refusing cross-volume move of $placeholderCount cloud-only files; re-run with -ForceHydrate to proceed."
                }
            }
        }

        $moveItem = New-OneDriveMigrationPlanItem -Type 'MoveAccount' -Target $target -CurrentValue $a.UserFolder -DesiredValue $target -SameVolume $sameVolume -Account $a -Reason 'Move the account sync root to the canonical target path.' -Skipped:([bool]$moveSkipReason) -SkipReason $moveSkipReason -Warnings $moveWarnings
        $moveItem | Add-Member -NotePropertyName FreshSync -NotePropertyValue $false
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
        if ($freshSyncSlots -contains $site.OwnerAccount.Slot) { continue }
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
                if ($ForceHydrate) {
                    $moveWarnings += "Will hydrate $placeholderCount cloud-only files (~size unknown)."
                } else {
                    $moveSkipReason = "Refusing cross-volume move of $placeholderCount cloud-only files; re-run with -ForceHydrate to proceed."
                }
            }
        }

        $moveItem = New-OneDriveMigrationPlanItem -Type 'MoveAccount' -Target $site.DesiredPath -CurrentValue $site.CurrentPath -DesiredValue $site.DesiredPath -SameVolume $sameVolume -Account $site.OwnerAccount -Reason 'Move the SharePoint site/library mount to the canonical tenant sibling path.' -Skipped:([bool]$moveSkipReason) -SkipReason $moveSkipReason -Warnings $moveWarnings
        $moveItem | Add-Member -NotePropertyName FreshSync -NotePropertyValue $false
        $moveItem | Add-Member -NotePropertyName SharePointSite -NotePropertyValue $true
        $moveItem | Add-Member -NotePropertyName Site -NotePropertyValue $site
        $executionItems.Add($moveItem) | Out-Null

        $rewriteSkipReason = if ($moveItem.Skipped) { $moveItem.SkipReason } else { $null }
        $rewriteItem = New-OneDriveMigrationPlanItem -Type 'RewriteSPCache' -Target $site.DesiredPath -CurrentValue $site.CurrentPath -DesiredValue $site.DesiredPath -SameVolume $sameVolume -Account $site.OwnerAccount -Reason 'Rewrite SharePoint mount-point cache entries after the site move.' -Skipped:([bool]$rewriteSkipReason) -SkipReason $rewriteSkipReason
        $rewriteItem | Add-Member -NotePropertyName Site -NotePropertyValue $site
        $rewriteItem | Add-Member -NotePropertyName MoveItem -NotePropertyValue $moveItem
        $executionItems.Add($rewriteItem) | Out-Null
    }

    $ownerInFreshSync = $KfmDecision.OwnerAccount -and ($freshSyncSlots -contains $KfmDecision.OwnerAccount.Slot)
    if ($ownerInFreshSync) {
        $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'RewriteKfm' -Target 'KFM' -CurrentValue $KfmCurrentPath -DesiredValue $null -SameVolume $null -Account $KfmDecision.OwnerAccount -Reason 'Skip KFM rewrite because the configured owner is being fresh-synced.' -Skipped:$true -SkipReason 'KFM owner is in -FreshSync.' -Warnings @("KFM owner account '$($KfmDecision.OwnerAccount.DisplayName)' is in -FreshSync; reconfigure Known Folder Move after re-sign-in."))) | Out-Null
    } elseif ($KfmDecision.Action -eq 'Track' -and $KfmDecision.OwnerAccount) {
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
    } elseif ($KfmDecision.Action -eq 'Rebind' -and $KfmDecision.OwnerAccount) {
        $ownerTarget = Get-OneDriveTargetPath -Account $KfmDecision.OwnerAccount -RootDir $RootDir
        $kfmCurrentOwner = Resolve-KfmCurrentOwnerRoot -Accounts $Accounts -KfmCurrentPath $KfmCurrentPath
        if (-not $kfmCurrentOwner) {
            $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'RewriteKfm' -Target $ownerTarget -CurrentValue $KfmCurrentPath -DesiredValue $ownerTarget -SameVolume $null -Account $KfmDecision.OwnerAccount -Reason 'Automatic KFM rebind requested.' -Skipped:$true -SkipReason 'Current KFM path is orphaned outside discovered OneDrive roots.' -Warnings @("KFM is currently bound to '$KfmCurrentPath', which is not under any discovered OneDrive account UserFolder. Skipping automatic rebind."))) | Out-Null
        } else {
            $skipReason = if ($KfmCurrentPath -and $KfmCurrentPath.StartsWith($ownerTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                'KFM already resolves under the desired owner root.'
            } else {
                $null
            }
            $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'RewriteKfm' -Target $ownerTarget -CurrentValue $kfmCurrentOwner.UserFolder -DesiredValue $ownerTarget -SameVolume $null -Account $KfmDecision.OwnerAccount -Reason 'Rebind KFM from the current owning account root to the desired owner root.' -Skipped:([bool]$skipReason) -SkipReason $skipReason)) | Out-Null
        }
    } elseif ($KfmDecision.Action -eq 'WarnOnly') {
        $executionItems.Add((New-OneDriveMigrationPlanItem -Type 'RewriteKfm' -Target 'KFM' -CurrentValue $KfmCurrentPath -DesiredValue $null -SameVolume $null -Account $KfmDecision.OwnerAccount -Reason 'Respect -NoKfmRebind and leave KFM on its current non-owner path.' -Skipped:$true -SkipReason $KfmDecision.Reason -Warnings @($KfmDecision.Reason))) | Out-Null
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
        [AllowEmptyCollection()][AllowNull()][object[]]$FreshSyncAccounts = @(),
        [switch]$NoKfmRebind,
        [switch]$WhatIfMode,
        [switch]$SkipElevationCheck,
        [bool]$IsElevated = $true,
        [string]$HomeDir = $env:USERPROFILE
    )

    $freshSyncSlots = @($FreshSyncAccounts | ForEach-Object { $_.Slot })
    $headerTag = if ($WhatIfMode) { '[PLAN | -WhatIf]' } else { '[APPLY]' }

    Write-Host ''
    Write-Host ("=== MarkMichaelisOneDriveConfiguration  {0} ===" -f $headerTag)
    if ($IsElevated) {
        Write-Host 'Elevation:     OK (Administrator)'
    } elseif ($SkipElevationCheck) {
        Write-Host 'Elevation:     NOT ELEVATED (bypassed via -SkipElevationCheck)'
        Write-Host '  WARNING: HKLM policy writes will fail unless Group Policy already applied them.'
    } else {
        Write-Host 'Elevation:     NOT ELEVATED'
    }

    if ($RootDir) {
        $rootLine = "RootDir:       $RootDir"
        if ($HomeDir) {
            $homeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($HomeDir))
            $rootRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($RootDir))
            if ($homeRoot -and $rootRoot -and -not [string]::Equals($homeRoot, $rootRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rootLine += "   (cross-volume from $homeRoot -- migrations hydrate cloud-only files unless -FreshSync or -ForceHydrate)"
            }
        }
        Write-Host $rootLine
    }

    if ($KfmOwner) {
        Write-Host ("KFM owner:     {0}  (Documents/Desktop/Pictures follow this account)" -f $KfmOwner)
        if ($NoKfmRebind) {
            Write-Host 'KFM:           suppressed (-NoKfmRebind)'
        }
    }
    Write-Host 'Update ring:   Production (HKLM)'

    if ($Accounts.Count -gt 0) {
        Write-Host ("Accounts ({0}):" -f $Accounts.Count)
        foreach ($account in $Accounts) {
            $name = if ($account.DisplayName) { $account.DisplayName } elseif ($account.UserEmail) { $account.UserEmail } else { $account.Slot }
            $target = if ($RootDir) { Get-OneDriveTargetPath -Account $account -RootDir $RootDir } else { $null }
            if ($freshSyncSlots -contains $account.Slot) {
                Write-Host ("  [{0}] {1,-18} -> FRESH-SYNC (unlink)  {2}  ->  {3}" -f $account.AccountType, $name, $account.UserFolder, $target)
                continue
            }

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
        [switch]$DeleteSourceOnSuccess,
        [switch]$NoFolderDescriptionsWrite
    )

    $deferredCleanupPaths = New-Object System.Collections.Generic.List[string]
    $freshSyncRecoveryPaths = New-Object System.Collections.Generic.List[string]
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
                    if ($item.FreshSync) {
                        $freshSyncRecoveryPath = Remove-OneDriveAccountLink -Account $item.Account -DeleteRecoveryFolder:$DeleteSourceOnSuccess
                        if ($freshSyncRecoveryPath) {
                            $freshSyncRecoveryPaths.Add($freshSyncRecoveryPath) | Out-Null
                            $item.Warnings += "FreshSync recovery folder preserved at: $freshSyncRecoveryPath"
                        }
                    } else {
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
                }
                'UpdateAccountRegistry' {
                    Update-OneDriveAccountRegistry -Account $item.Account -NewPath $item.DesiredValue
                }
                'RewriteSPCache' {
                    Update-OneDriveSharePointCache -Account $item.Account -OldPath $item.CurrentValue -NewPath $item.DesiredValue
                }
                'RewriteKfm' {
                    if ($item.CurrentValue -and $item.DesiredValue) {
                        Update-KfmBindings -OldRoot $item.CurrentValue -NewRoot $item.DesiredValue -NoFolderDescriptionsWrite:$NoFolderDescriptionsWrite
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
                    $Plan | Where-Object { $_.Type -eq 'MoveAccount' -and -not $_.FreshSync -and $_.Account -and $_.Account.Slot -eq $item.Account.Slot } | Select-Object -First 1
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
        DeferredCleanupPaths   = $deferredCleanupPaths
        FreshSyncRecoveryPaths = $freshSyncRecoveryPaths
        Plan                   = $Plan
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
        [AllowEmptyCollection()][string[]]$DeferredCleanupPaths = @(),
        [AllowEmptyCollection()][string[]]$FreshSyncRecoveryPaths = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $freshSyncItems = @($Plan | Where-Object { $_.Type -eq 'MoveAccount' -and ($_.PSObject.Properties.Name -contains 'FreshSync') -and $_.FreshSync })
    $migratedItems = @($Plan | Where-Object { $_.Type -eq 'MoveAccount' -and (-not ($_.PSObject.Properties.Name -contains 'FreshSync') -or -not $_.FreshSync) })

    $lines.Add('MarkMichaelisOneDriveConfiguration summary:') | Out-Null
    $lines.Add('Execution Summary:') | Out-Null
    $lines.Add(("  - Migrated items planned/executed: {0}" -f $migratedItems.Count)) | Out-Null
    if ($freshSyncItems.Count -eq 0) {
        $lines.Add('  - FreshSync: none') | Out-Null
    } else {
        $freshSyncNames = ($freshSyncItems | ForEach-Object { if ($_.Account.DisplayName) { $_.Account.DisplayName } else { $_.Account.Slot } } | Sort-Object -Unique) -join ', '
        $lines.Add(("  - FreshSync: {0} account(s) -- ACTION REQUIRED: re-sign-in via OneDrive UI ({1})" -f $freshSyncItems.Count, $freshSyncNames)) | Out-Null
    }

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
        foreach ($path in @($DeferredCleanupPaths)) {
            $lines.Add(("  - {0}" -f $path)) | Out-Null
        }
    }

    $lines.Add('FreshSync recovery folders preserved at:') | Out-Null
    if (@($FreshSyncRecoveryPaths).Count -eq 0) {
        $lines.Add('  - none') | Out-Null
    } else {
        foreach ($path in @($FreshSyncRecoveryPaths)) {
            $lines.Add(("  - {0}" -f $path)) | Out-Null
        }
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

function Invoke-MarkMichaelisOneDriveConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$KfmOwner,
        [switch]$KfmOwnerContains,
        [switch]$NoKfmRebind,
        [switch]$NoFolderDescriptionsWrite,
        [AllowEmptyCollection()][AllowNull()][string[]]$FreshSync,
        [switch]$DeleteSourceOnSuccess,
        [switch]$ForceHydrate,
        [switch]$SkipElevationCheck,
        [bool]$IsElevated = $true
    )

    Write-Warning 'Mutates OneDrive client internal registry state (Accounts\<slot>\UserFolder, ScopeIdToMountPointPathCache*); these are not Microsoft-documented migration APIs.'
    Write-Host "MarkMichaelisOneDriveConfiguration: RootDir=$RootDir, KfmOwner=$KfmOwner"
    if ($KfmOwnerContains) {
        Write-Host '  KfmOwnerContains requested: using substring owner matching'
    }
    if ($FreshSync -and $FreshSync.Count -gt 0) {
        Write-Host "  FreshSync requested: $($FreshSync -join ', ')"
    }
    if ($ForceHydrate) {
        Write-Host '  ForceHydrate requested: cross-volume placeholder hydration is allowed'
    }
    if ($NoFolderDescriptionsWrite) {
        Write-Host '  NoFolderDescriptionsWrite requested: skipping FolderDescriptions internal rewrites'
    }

    $accounts = Get-OneDriveAccountList
    $freshSyncAccounts = Resolve-FreshSyncAccounts -Accounts $accounts -FreshSync $FreshSync
    $sharePointSites = Get-OneDriveSharePointSiteList -Accounts $accounts -RootDir $RootDir

    Write-Verbose ("Discovered {0} account(s); {1} fresh-sync." -f $accounts.Count, $freshSyncAccounts.Count)

    $kfmCurrent = Get-CurrentKfmPath
    $kfmDecision = Resolve-KfmRebindAction -Accounts $accounts -KfmCurrentPath $kfmCurrent -KfmOwner $KfmOwner -KfmOwnerContains:$KfmOwnerContains -NoKfmRebind:$NoKfmRebind
    Write-Host "  KFM: [$($kfmDecision.Action)] $($kfmDecision.Reason)"
    if ($kfmDecision.Action -eq 'OwnerNotSignedIn') {
        throw "KFM owner '$KfmOwner' is not signed in. Sign in to the matching Work account in OneDrive and re-run."
    }

    $wasRunning = [bool](Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)
    $plan = New-OneDriveMigrationPlan -RootDir $RootDir -Accounts $accounts -FreshSyncAccounts @($freshSyncAccounts) -SharePointSites @($sharePointSites) -KfmCurrentPath $kfmCurrent -KfmDecision $kfmDecision -WasRunning:$wasRunning -ForceHydrate:$ForceHydrate
    Format-OneDriveMigrationPlan -Plan $plan -Accounts $accounts -RootDir $RootDir -KfmOwner $KfmOwner `
        -FreshSyncAccounts $freshSyncAccounts -NoKfmRebind:$NoKfmRebind `
        -WhatIfMode:$WhatIfPreference -SkipElevationCheck:$SkipElevationCheck `
        -IsElevated $IsElevated

    if ($WhatIfPreference) {
        return $plan
    }

    $backupPath = ($plan | Where-Object Type -eq 'RegistryBackup' | Select-Object -First 1).Target
    $deferredCleanupPaths = @()
    $freshSyncRecoveryPaths = @()
    try {
        $execution = Invoke-OneDriveMigrationPlan -Plan $plan -DeleteSourceOnSuccess:$DeleteSourceOnSuccess -NoFolderDescriptionsWrite:$NoFolderDescriptionsWrite -Confirm:$false
        $deferredCleanupPaths = @($execution.DeferredCleanupPaths)
        $freshSyncRecoveryPaths = @($execution.FreshSyncRecoveryPaths)
    } catch {
        $failedItem = $plan | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 1
        if ($failedItem -and $failedItem.Type -eq 'UpdateAccountRegistry' -and $failedItem.Account) {
            Write-Error "Migration failed for $($failedItem.Account.DisplayName): $($failedItem.FailureReason) Best-effort rollback attempted. Inspect the old and new paths and verify OneDrive account registry under '$($failedItem.Account.RegistryPath)' before restarting OneDrive. Registry backup: $backupPath. OneDrive NOT restarted automatically."
        } elseif ($failedItem) {
            Write-Error "Migration failed during $($failedItem.Type): $($failedItem.FailureReason). Registry backup: $backupPath. OneDrive NOT restarted automatically."
        }
        throw
    }

    $summaryLines = Get-OneDriveMigrationSummaryLines -Accounts $accounts -SharePointSites @($sharePointSites) -Plan $plan -DeferredCleanupPaths @($deferredCleanupPaths) -FreshSyncRecoveryPaths @($freshSyncRecoveryPaths)
    Write-OneDriveMigrationSummary -Lines $summaryLines

    $verifyItem = $plan | Where-Object Type -eq 'Verify' | Select-Object -First 1
    if ($verifyItem -and ($verifyItem.PSObject.Properties.Name -contains 'VerifyResult')) {
        Write-OneDriveMigrationVerificationSummary -VerifyResult $verifyItem.VerifyResult
        if ($verifyItem.VerifyResult.FailedChecks.Count -gt 0) {
            $failedChecksSummary = ($verifyItem.VerifyResult.FailedChecks | ForEach-Object { "[$($_.Name)] $($_.Detail)" }) -join '; '
            throw "Post-migration verification failed: $failedChecksSummary. Registry backup: $backupPath. Data was already migrated; investigate manually (no rollback performed)."
        }
    }

    if ($freshSyncAccounts.Count -gt 0) {
        Write-Host ''
        Write-Host 'FRESH-SYNC accounts unlinked:'
        foreach ($fa in $freshSyncAccounts) {
            Write-Host ("  - {0} ({1})" -f $fa.DisplayName, $fa.Slot)
        }
        Write-Host ''
        Write-Host 'To complete the fresh-sync flow:'
        Write-Host "  1. Open OneDrive Settings (right-click cloud icon -> Settings -> Account)"
        Write-Host "  2. Click 'Add an account'"
        foreach ($fa in $freshSyncAccounts) {
            $newTarget = Get-OneDriveTargetPath -Account $fa -RootDir $RootDir
            Write-Host ("  3. Sign in to: {0}" -f $fa.UserEmail)
            Write-Host ("     Policy will direct the new sync root to: {0}" -f $newTarget)
        }
        Write-Host '  4. OneDrive will create cloud-only placeholders (no bulk download).'
        Write-Host ''
    }

    $fodGatedItems = @($plan | Where-Object { $_.Type -eq 'MoveAccount' -and $_.SkipReason -like 'Refusing cross-volume move of *cloud-only files*' })
    if ($fodGatedItems.Count -gt 0) {
        Write-Warning ("Files-On-Demand gate blocked {0} cross-volume move(s). Re-run with -ForceHydrate to proceed after accepting hydration." -f $fodGatedItems.Count)
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
    $null = Invoke-MarkMichaelisOneDriveConfiguration -RootDir $RootDir -KfmOwner $KfmOwner `
        -KfmOwnerContains:$KfmOwnerContains -NoKfmRebind:$NoKfmRebind `
        -NoFolderDescriptionsWrite:$NoFolderDescriptionsWrite -FreshSync $FreshSync `
        -DeleteSourceOnSuccess:$DeleteSourceOnSuccess -ForceHydrate:$ForceHydrate `
        -SkipElevationCheck:$SkipElevationCheck -IsElevated $__mmodIsElevated
}
