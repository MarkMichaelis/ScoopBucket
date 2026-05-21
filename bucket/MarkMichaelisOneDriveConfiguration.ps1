<#
.SYNOPSIS
    Personal post-install OneDrive customization: pin sync roots under a
    single parent directory, apply tenant-redirection policy, and rewrite
    Known Folder Move bindings to follow the canonical Work account.

.DESCRIPTION
    Reshapes OneDrive state on this machine to match the author's
    personal layout. Member of the MarkMichaelis* personal-customization
    bundle category (run-last); reshapes state, does not install
    software. Pattern follows GitConfigure.ps1 / SetPowerConfiguration.ps1
    (free-form configuration script, NOT a [Package[]] declarative
    bundle).

    What the bundle does
    --------------------
    1. Pre-creates $RootDir (default C:\OneDrive) and hardens its ACL
       to match $env:USERPROFILE so the sync root is user-only on
       alternate volumes (which otherwise inherit BUILTIN\Users
       Read+Execute).
    2. Applies tenant-redirection policy:
         HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir\<tid>
       per Work tenant, so future sign-ins land in the right place.
    3. Sets HKLM:\SOFTWARE\Policies\Microsoft\OneDrive\GPOSetUpdateRing
       = 4 (Deferred), which is admin-only -- see .NOTES.
    4. For each discovered account, either file-copy-migrates the
       UserFolder to the convention path or unlinks it for fresh-sync
       (see below).
    5. Rewrites Known Folder Move bindings (Documents / Pictures /
       Desktop in User Shell Folders, Shell Folders, and KNOWNFOLDERID
       GUIDs) so KFM follows the -KfmOwner account when its folder
       moves.

    Robocopy migration vs -FreshSync (the key cross-volume trade-off)
    ----------------------------------------------------------------
    The default action for an account whose UserFolder differs from the
    convention is to migrate the files in place:

      - Same-volume:   Move-Item (NTFS rename, preserves Cloud Files
                       reparse points + ACLs).
      - Cross-volume:  robocopy /MIR /COPYALL /DCOPY:DAT /B.

    Cross-volume robocopy MATERIALIZES every Files-On-Demand placeholder
    on the source -- a Business tenant with 39 GB of cloud-only files
    will fully hydrate them on the destination volume.

    -FreshSync <slot-or-DisplayName>... is the escape hatch. For each
    matching Business account the bundle stops OneDrive, deletes the
    per-account registry slot and the local UserFolder, and restarts
    OneDrive. The user re-signs-in via the OneDrive UI; the
    DefaultRootDir policy (still applied) directs the new sync root to
    the convention path, and OneDrive recreates cloud-only placeholders
    WITHOUT bulk-downloading content.

    Why elevation is required
    -------------------------
    The bundle writes HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
    (GPOSetUpdateRing), which requires Administrator. The script
    fails fast with a clear message if launched without elevation.
    Pass -SkipElevationCheck if the HKLM policy is already
    pre-applied via Group Policy.

    Known Folder Move (KFM) model
    -----------------------------
    KFM redirects Documents, Desktop, and Pictures into a OneDrive
    sync folder. Only ONE Work account at a time can own KFM. The
    -KfmOwner parameter (default 'Michaelis') is matched
    case-insensitively as a substring against the DisplayName of
    Business* registry slots; KFM is then rewritten to follow that
    account whenever its UserFolder moves. Personal accounts are
    never eligible to own KFM.

    Idempotent: re-running is a no-op once state matches the
    convention. Supports -WhatIf / -Confirm via $PSCmdlet.ShouldProcess
    on every state-changing operation.

.PARAMETER RootDir
    Parent directory for all OneDrive sync roots. Default: C:\OneDrive.
    When $RootDir is on a different volume than $env:USERPROFILE,
    every account that gets file-copy-migrated will hydrate its
    Files-On-Demand placeholders during robocopy. Combine with
    -FreshSync to opt cloud-only accounts out of that hydration.

.PARAMETER KfmOwner
    DisplayName substring identifying the canonical KFM owner -- the
    Business account whose Documents / Desktop / Pictures KFM follows.
    Default: 'Michaelis'. Matched case-insensitively against the
    DisplayName of Business* registry slots; only the first match wins.
    Personal accounts are never eligible.

.PARAMETER NoKfmRebind
    Suppress the warning + automatic rebind that fires when KFM is
    currently bound to a different account than -KfmOwner. The bundle
    still applies policy and migrates files; only the KFM rewrite is
    skipped.

.PARAMETER FreshSync
    String array of Business* Slot names (e.g. 'Business2') or
    DisplayNames (e.g. 'IntelliTect') to unlink instead of
    file-copy-migrate. The matching account's registry slot and local
    UserFolder are deleted; the user must re-sign-in via the OneDrive
    UI after the bundle finishes. Use this to avoid hydrating
    cloud-only Files-On-Demand content during a cross-volume move.
    Personal accounts are not supported and cause a throw.

.PARAMETER SkipElevationCheck
    Bypass the Administrator pre-flight. Use only when the HKLM
    OneDrive policy is already applied (e.g. by Group Policy) and the
    bundle only needs to perform per-user (HKCU + filesystem) work.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -WhatIf

    Default plan: roots at C:\OneDrive, all accounts robocopy-migrated,
    KFM follows Michaelis. Shows every move + registry write without
    changing any state.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -RootDir D:\OneDrive -FreshSync Business2 -WhatIf

    Cross-volume move to D:; IntelliTect (Business2) is unlinked to
    avoid hydrating 39 GB of cloud-only files. The user re-signs-in
    after the bundle completes; the DefaultRootDir policy directs the
    new sync root to D:\OneDrive\OneDrive - IntelliTect.

.EXAMPLE
    .\MarkMichaelisOneDriveConfiguration.ps1 -NoKfmRebind

    Apply policy + migrate files but leave KFM bindings alone. Useful
    when KFM is intentionally bound to a non-default account.

.NOTES
    Requires an elevated PowerShell session (Run as Administrator):
    the bundle writes HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
    (GPOSetUpdateRing). Pass -SkipElevationCheck only if the HKLM
    policy is already pre-applied via Group Policy.

    Restarts OneDrive.exe whenever a migration or fresh-sync unlink
    occurs (stops with /shutdown, restarts with /background).

    Cross-volume migrations hydrate Files-On-Demand placeholders
    unless -FreshSync is used to unlink the affected account before
    the move.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RootDir   = 'C:\OneDrive',
    [string] $KfmOwner  = 'Michaelis',
    [switch] $NoKfmRebind,
    [string[]] $FreshSync = @(),
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

function Format-OneDrivePlanBanner {
    <#
    .SYNOPSIS
        Build the structured, always-visible plan banner emitted before
        any side effects fire.
    .DESCRIPTION
        Pure function. Returns the banner as a string[] so unit tests
        can assert on individual lines without capturing host output.
        The orchestrator pipes the result to Write-Host.

        Reflects parameter impact:
          - -WhatIf       -> header reads '[PLAN | -WhatIf]'; otherwise '[APPLY]'
          - cross-volume  -> RootDir line warns about hydration
          - -NoKfmRebind  -> 'KFM:' line says 'suppressed (-NoKfmRebind)'
          - -FreshSync    -> per-account marker 'FRESH-SYNC (unlink)'
          - SkipElevationCheck w/o actual elevation -> WARNING line
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$KfmOwner,
        [switch]$NoKfmRebind,
        [AllowEmptyCollection()][AllowNull()][object[]]$FreshSyncAccounts,
        [switch]$WhatIfMode,
        [switch]$SkipElevationCheck,
        [bool]$IsElevated = $true,
        [string]$HomeDir = $env:USERPROFILE
    )

    $fsSlots = @()
    if ($FreshSyncAccounts) {
        $fsSlots = @($FreshSyncAccounts | ForEach-Object { $_.Slot })
    }

    $headerTag = if ($WhatIfMode) { '[PLAN | -WhatIf]' } else { '[APPLY]' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("=== MarkMichaelisOneDriveConfiguration  $headerTag ===") | Out-Null

    if ($IsElevated) {
        $lines.Add('Elevation:     OK (Administrator)') | Out-Null
    } elseif ($SkipElevationCheck) {
        $lines.Add('Elevation:     NOT ELEVATED (bypassed via -SkipElevationCheck)') | Out-Null
        $lines.Add('  WARNING: HKLM policy writes will fail; ensure GPO has already applied them.') | Out-Null
    } else {
        $lines.Add('Elevation:     NOT ELEVATED') | Out-Null
    }

    $rootLine = "RootDir:       $RootDir"
    if ($HomeDir) {
        $homeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($HomeDir))
        $rootRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($RootDir))
        if ($homeRoot -and $rootRoot -and -not [string]::Equals($homeRoot, $rootRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rootLine += "   (cross-volume from $homeRoot -- migrations hydrate cloud-only files unless -FreshSync)"
        }
    }
    $lines.Add($rootLine) | Out-Null

    if ($NoKfmRebind) {
        $lines.Add("KFM owner:     $KfmOwner  (Documents/Desktop/Pictures follow this account)") | Out-Null
        $lines.Add('KFM:           suppressed (-NoKfmRebind)') | Out-Null
    } else {
        $lines.Add("KFM owner:     $KfmOwner  (Documents/Desktop/Pictures follow this account)") | Out-Null
    }

    $lines.Add('Update ring:   Deferred (HKLM)') | Out-Null

    $count = if ($Accounts) { @($Accounts).Count } else { 0 }
    $lines.Add("Accounts ($count):") | Out-Null
    foreach ($a in $Accounts) {
        $typeTag = "[$($a.AccountType)]"
        $name = if ($a.DisplayName) { $a.DisplayName } else { $a.UserEmail }
        if (-not $name) { $name = $a.Slot }
        $isFresh = $fsSlots -contains $a.Slot
        if ($isFresh) {
            $target = Get-OneDriveTargetPath -Account $a -RootDir $RootDir
            $lines.Add(('  {0} {1,-14} -> FRESH-SYNC (unlink)  {2}  -> (re-created cloud-only at {3} after re-sign-in)' -f $typeTag, $name, $a.UserFolder, $target)) | Out-Null
        } else {
            $target = Get-OneDriveTargetPath -Account $a -RootDir $RootDir
            $action = if ($a.UserFolder -and ($a.UserFolder.TrimEnd('\') -ine $target.TrimEnd('\'))) {
                'robocopy migration  '
            } else {
                'no-op (already at target)'
            }
            $lines.Add(('  {0} {1,-14} -> {2} {3}  ->  {4}' -f $typeTag, $name, $action, $a.UserFolder, $target)) | Out-Null
        }
    }

    return $lines.ToArray()
}

function Format-OneDriveSummaryReport {
    <#
    .SYNOPSIS
        Build the structured completion banner emitted after all side
        effects have run (or would have run, under -WhatIf).
    .DESCRIPTION
        Pure function. Returns the banner as a string[] so unit tests
        can assert on individual lines without capturing host output.
        Phrasing adapts to -WhatIf ("Would have migrated:" vs
        "Migrated:").
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowNull()][object[]]$Migrations,
        [AllowEmptyCollection()][AllowNull()][object[]]$FreshSyncAccounts,
        [Parameter(Mandatory)][pscustomobject]$KfmDecision,
        [Parameter(Mandatory)][string]$RootDir,
        [bool]$RestartedOneDrive,
        [bool]$KfmOwnerInFreshSync,
        [switch]$WhatIfMode
    )

    $migVerb = if ($WhatIfMode) { 'Would migrate:  ' } else { 'Migrated:       ' }
    $fsVerb  = if ($WhatIfMode) { 'Would fresh-sync:' } else { 'Fresh-synced:   ' }
    $restartVerb = if ($WhatIfMode) { 'Would restart:  ' } else { 'Restart:        ' }

    $migCount = if ($Migrations) { @($Migrations).Count } else { 0 }
    $fsCount  = if ($FreshSyncAccounts) { @($FreshSyncAccounts).Count } else { 0 }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== Completed ===') | Out-Null

    $migPaths = if ($migCount -gt 0) {
        '(' + (($Migrations | ForEach-Object { $_.OldPath }) -join ', ') + ')'
    } else { '' }
    $lines.Add(("{0}{1} account(s)  {2}" -f $migVerb, $migCount, $migPaths)) | Out-Null

    $fsNames = if ($fsCount -gt 0) {
        '(' + (($FreshSyncAccounts | ForEach-Object { $_.DisplayName }) -join ', ') + ' -- ACTION REQUIRED: re-sign-in via OneDrive UI)'
    } else { '' }
    $lines.Add(("{0} {1} account(s)  {2}" -f $fsVerb, $fsCount, $fsNames)) | Out-Null

    $kfmLine = if ($KfmOwnerInFreshSync) {
        'KFM:            Skipped (owner in -FreshSync; reconfigure via OneDrive Settings -> Backup)'
    } elseif ($KfmDecision.Action -eq 'Rebind' -and $KfmDecision.OwnerAccount) {
        $target = Get-OneDriveTargetPath -Account $KfmDecision.OwnerAccount -RootDir $RootDir
        if ($WhatIfMode) {
            "KFM:            Would rebind to $target"
        } else {
            "KFM:            Rebound to $target"
        }
    } elseif ($KfmDecision.Action -eq 'Track' -and $KfmDecision.OwnerAccount) {
        "KFM:            Tracking $($KfmDecision.OwnerAccount.DisplayName)"
    } elseif ($KfmDecision.Action -eq 'WarnOnly') {
        'KFM:            Suppressed (-NoKfmRebind); current binding left alone'
    } else {
        "KFM:            $($KfmDecision.Action)"
    }
    $lines.Add($kfmLine) | Out-Null

    $restartLine = if ($RestartedOneDrive) {
        if ($WhatIfMode) { 'Would restart:  OneDrive.exe' } else { 'Restart:        OneDrive.exe restarted' }
    } else {
        "$restartVerb (no migrations -- OneDrive not restarted)"
    }
    $lines.Add($restartLine) | Out-Null

    return $lines.ToArray()
}

function Write-OneDrivePlanBanner {
    <#
    .SYNOPSIS
        Emit the plan banner to the host. Thin wrapper around
        Format-OneDrivePlanBanner.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Accounts,
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$KfmOwner,
        [switch]$NoKfmRebind,
        [AllowEmptyCollection()][AllowNull()][object[]]$FreshSyncAccounts,
        [switch]$WhatIfMode,
        [switch]$SkipElevationCheck,
        [bool]$IsElevated = $true
    )
    $lines = Format-OneDrivePlanBanner `
        -Accounts $Accounts -RootDir $RootDir -KfmOwner $KfmOwner `
        -NoKfmRebind:$NoKfmRebind -FreshSyncAccounts $FreshSyncAccounts `
        -WhatIfMode:$WhatIfMode -SkipElevationCheck:$SkipElevationCheck `
        -IsElevated $IsElevated
    foreach ($l in $lines) { Write-Host $l }
}

function Write-OneDriveSummaryReport {
    <#
    .SYNOPSIS
        Emit the completion banner to the host. Thin wrapper around
        Format-OneDriveSummaryReport.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowNull()][object[]]$Migrations,
        [AllowEmptyCollection()][AllowNull()][object[]]$FreshSyncAccounts,
        [Parameter(Mandatory)][pscustomobject]$KfmDecision,
        [Parameter(Mandatory)][string]$RootDir,
        [bool]$RestartedOneDrive,
        [bool]$KfmOwnerInFreshSync,
        [switch]$WhatIfMode
    )
    $lines = Format-OneDriveSummaryReport `
        -Migrations $Migrations -FreshSyncAccounts $FreshSyncAccounts `
        -KfmDecision $KfmDecision -RootDir $RootDir `
        -RestartedOneDrive $RestartedOneDrive `
        -KfmOwnerInFreshSync $KfmOwnerInFreshSync `
        -WhatIfMode:$WhatIfMode
    Write-Host ''
    foreach ($l in $lines) { Write-Host $l }
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
    if ($existingRing -ne 4) {
        if ($PSCmdlet.ShouldProcess("$hklmPolicy\GPOSetUpdateRing", 'Set DWord = 4 (Deferred ring)')) {
            try {
                Set-ItemProperty -Path $hklmPolicy -Name 'GPOSetUpdateRing' -Value 4 -Type DWord
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
        [AllowEmptyCollection()][AllowNull()][string[]]$FreshSync,
        [switch]$SkipElevationCheck,
        [bool]$IsElevated = $true
    )

    # 1. Pre-create $RootDir and harden its ACL to match $env:USERPROFILE.
    #    On alternate volumes (e.g. D:\OneDrive), a freshly-created
    #    directory inherits the volume-root ACL which grants Read+Execute
    #    to BUILTIN\Users. Copy the home-dir ACL so the sync root is
    #    user-only, matching what Windows provisions for C:\Users\<me>.
    if (-not (Test-Path $RootDir)) {
        if ($PSCmdlet.ShouldProcess($RootDir, 'Create directory')) {
            New-Item -ItemType Directory -Path $RootDir -Force | Out-Null
        }
        Write-Verbose "Applying home-directory ACL ($env:USERPROFILE) to '$RootDir'..."
        Set-RootDirAclFromHome -Path $RootDir
    }
    else {
        $homeAcl = Get-Acl -LiteralPath $env:USERPROFILE
        $rootAcl = Get-Acl -LiteralPath $RootDir
        if ($homeAcl.Sddl -ne $rootAcl.Sddl) {
            Write-Warning "$RootDir already exists; ACL differs from $env:USERPROFILE. Leaving ACL unchanged. Run icacls or re-create the directory to harden it."
        }
    }

    # 2. Discover accounts.
    $accounts = Get-OneDriveAccountList

    # 2a. Resolve -FreshSync entries against the discovered accounts.
    $freshSyncAccounts = Resolve-FreshSyncAccounts -Accounts $accounts -FreshSync $FreshSync
    $freshSyncSlots = @($freshSyncAccounts | ForEach-Object { $_.Slot })

    # 2b. Emit always-visible plan banner BEFORE any side effects.
    Write-OneDrivePlanBanner -Accounts $accounts -RootDir $RootDir -KfmOwner $KfmOwner `
        -NoKfmRebind:$NoKfmRebind -FreshSyncAccounts $freshSyncAccounts `
        -WhatIfMode:$WhatIfPreference -SkipElevationCheck:$SkipElevationCheck `
        -IsElevated $IsElevated

    Write-Verbose ("Discovered {0} account(s); {1} fresh-sync." -f $accounts.Count, $freshSyncAccounts.Count)

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
    Write-Verbose ("KFM: [{0}] {1}" -f $kfmDecision.Action, $kfmDecision.Reason)
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
                Write-Verbose "Migrating $($m.Account.DisplayName): $($m.OldPath) -> $($m.NewPath)"
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
                Write-Verbose "Fresh-sync unlink: $($fa.DisplayName) (Slot=$($fa.Slot))"
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

    # 8. Summary banner.
    Write-OneDriveSummaryReport -Migrations $migrations -FreshSyncAccounts $freshSyncAccounts `
        -KfmDecision $kfmDecision -RootDir $RootDir `
        -RestartedOneDrive $stoppedOneDrive `
        -KfmOwnerInFreshSync $kfmOwnerInFreshSync `
        -WhatIfMode:$WhatIfPreference

    if ($freshSyncAccounts.Count -gt 0) {
        Write-Host ''
        Write-Host 'FRESH-SYNC accounts unlinked:'
        foreach ($fa in $freshSyncAccounts) {
            Write-Host ("  - {0} ({1})" -f $fa.DisplayName, $fa.Slot)
        }
        Write-Host ''
        Write-Host 'To complete the migration:'
        Write-Host '  1. Open OneDrive Settings (right-click cloud icon -> Settings -> Account)'
        Write-Host "  2. Click 'Add an account'"
        foreach ($fa in $freshSyncAccounts) {
            $newTarget = Get-OneDriveTargetPath -Account $fa -RootDir $RootDir
            Write-Host ("  3. Sign in to: {0}" -f $fa.UserEmail)
            Write-Host ("     Policy will direct the new sync root to: {0}" -f $newTarget)
        }
        Write-Host '  4. OneDrive will create cloud-only placeholders (no bulk download).'
        Write-Host ''
    }

    Write-Warning "MRU staleness: Office recent docs / Snagit Recent File List / VS recent files may reference old OneDrive paths; reopen as needed."
}

# Only run when invoked as a script (Scoop's installer does
# `& "$dir\MarkMichaelisOneDriveConfiguration.ps1"`). When dot-sourced
# (Pester tests), expose the helpers without running migration.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MarkMichaelisOneDriveConfiguration -RootDir $RootDir -KfmOwner $KfmOwner `
        -NoKfmRebind:$NoKfmRebind -FreshSync $FreshSync `
        -SkipElevationCheck:$SkipElevationCheck -IsElevated $__mmodIsElevated
}
