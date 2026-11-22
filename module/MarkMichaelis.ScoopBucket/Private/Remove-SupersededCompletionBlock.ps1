function Resolve-SupersededCompletionProfilePath {
    <#
    .SYNOPSIS
        The machine profile that may still hold completion blocks written
        before #397, or $null when it must not be touched.
    .DESCRIPTION
        Returns $PROFILE.AllUsersAllHosts ($PSHOME\profile.ps1). Returns $null
        when -OverridePath is given: a caller that redirected the current-user
        profile to a sandbox (the -ProfilePath test hook) must never edit the
        real machine profile.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$OverridePath)

    if ($OverridePath) { return $null }
    $path = $PROFILE.AllUsersAllHosts
    if ([string]::IsNullOrWhiteSpace($path) -or $path -eq $PROFILE.CurrentUserAllHosts) { return $null }
    return $path
}

function Remove-SupersededCompletionBlock {
    <#
    .SYNOPSIS
        Remove completion blocks from the machine profile that a block in the
        current-user profile supersedes (#540).
    .DESCRIPTION
        Before #397, completion blocks were written to
        $PROFILE.AllUsersAllHosts. #397 moved them to
        $PROFILE.CurrentUserAllHosts without removing the old copies, so a
        machine that registered completions earlier loads two blocks per CLI,
        the stale machine copy first.

        A ScoopBucket:CliCompletion:<cli> block is removed from
        -LegacyProfilePath only when -CurrentUserContent has a block for the
        same CLI; a machine block with no current-user counterpart may be the
        only registration and is left alone, as is everything that is not a
        completion block. Every copy of a superseded block is removed.

        Idempotent: once the copies are gone there is nothing to report.
        Writing $PSHOME\profile.ps1 needs elevation; when the write is refused
        nothing changes and a single warning gives the count and the path.
    .OUTPUTS
        One row per superseded CLI, shaped like Update-PackageCompletion's
        rows: Action is Removed, WhatIf, or Skipped (write refused or
        declined).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentUserContent,
        [Parameter(Mandatory)][string]$LegacyProfilePath
    )

    if (-not (Test-Path -LiteralPath $LegacyProfilePath)) { return }

    $content = Read-PackageCompletionProfileContent -Path $LegacyProfilePath
    $beginPattern = '(?m)^# ScoopBucket:CliCompletion:(?<cli>[^:\r\n]+):BEGIN\b'
    $userClis = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@([regex]::Matches($CurrentUserContent, $beginPattern) | ForEach-Object { $_.Groups['cli'].Value }),
        [StringComparer]::OrdinalIgnoreCase)
    $candidates = @([regex]::Matches($content, $beginPattern) |
        ForEach-Object { $_.Groups['cli'].Value } |
        Where-Object { $userClis.Contains($_) } |
        Select-Object -Unique)
    if (-not $candidates) { return }

    $newContent = $content
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($cli in $candidates) {
        $any = $false
        do {
            $strip = Remove-PackageCompletionProfileBlock -Content $newContent -Cli $cli
            if ($strip.Changed) { $newContent = $strip.Content; $any = $true }
        } while ($strip.Changed)
        # A block whose END sentinel was lost does not match and stays put:
        # guessing its extent could cut into the user's own code.
        if ($any) { $removed.Add($cli) }
    }
    if ($removed.Count -eq 0) { return }

    $row = {
        param($Cli, $Action, $Reason)
        [pscustomobject]@{
            Cli = $Cli; Package = '(machine profile)'; Bundle = 'AllUsersAllHosts'
            Mode = ''; Action = $Action; Source = 'Superseded'; Reason = $Reason
        }
    }

    # -WhatIf preview without ShouldProcess's host line, as
    # Update-PackageCompletion does (#287): the rows are the record.
    if ($WhatIfPreference) {
        foreach ($cli in $removed) { & $row $cli 'WhatIf' '' }
        return
    }
    $operation = "Remove $($removed.Count) completion block(s) superseded by $($PROFILE.CurrentUserAllHosts)"
    if (-not $PSCmdlet.ShouldProcess($LegacyProfilePath, $operation)) {
        foreach ($cli in $removed) { & $row $cli 'Skipped' 'Declined at the confirmation prompt.' }
        return
    }

    $tmp = "$LegacyProfilePath.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $newContent, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $LegacyProfilePath -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -ErrorAction Ignore
        Write-Warning ("ScoopBucket: {0} completion block(s) in '{1}' duplicate blocks in your profile and could not be removed ({2}). Re-run Update-PackageCompletion from an elevated shell to remove them." -f $removed.Count, $LegacyProfilePath, $_.Exception.GetBaseException().Message)
        foreach ($cli in $removed) { & $row $cli 'Skipped' "Could not write '$LegacyProfilePath'; needs an elevated shell." }
        return
    }

    foreach ($cli in $removed) {
        & $row $cli 'Removed' "Removed the stale copy from '$LegacyProfilePath'; the block in your profile replaces it (#540)."
    }
}
