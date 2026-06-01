# De-Store helpers (#281). The Microsoft Store / MSIX build of PowerShell 7
# installs under C:\Program Files\WindowsApps\Microsoft.PowerShell_..._8wekyb3d8bbwe\,
# a TrustedInstaller-owned folder where BUILTIN\Administrators hold only
# ReadAndExecute. Because $PROFILE.AllUsersAllHosts == $PSHOME\profile.ps1, the
# AllUsers profile can't be written even when elevated, so machine-wide
# completion registration (Update-PackageCompletion) silently fails. Removing
# the Store build lets the first-party MSI build (C:\Program Files\PowerShell\7)
# win, restoring an admin-writable AllUsersAllHosts profile.

function Remove-StorePwshFromPathString {
    <#
    .SYNOPSIS
        Return $PathValue with any sealed Store/MSIX PowerShell package
        directory removed, preserving the order of all other entries.
    .DESCRIPTION
        Pure string transform (no environment side effects) so it is fully
        unit-testable. Drops segments that point inside a
        WindowsApps\Microsoft.PowerShell_... package directory -- the sealed
        path that shadows the MSI build on PATH.
    .PARAMETER PathValue
        A ';'-delimited PATH string (e.g. the Machine or User PATH).
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PathValue
    )
    if (-not $PathValue) { return $PathValue }
    $kept = foreach ($segment in ($PathValue -split ';')) {
        if (-not $segment) { continue }
        if ($segment -match '(?i)\\WindowsApps\\Microsoft\.PowerShell_') { continue }
        $segment
    }
    , ($kept -join ';') | Select-Object -First 1
}

function Resolve-StorePwshRemoval {
    <#
    .SYNOPSIS
        Decide whether the Store/MSIX PowerShell should be removed.
    .DESCRIPTION
        Pure decision function (no side effects) so the removal policy is
        unit-testable independent of the Appx cmdlets (which exist only on
        Windows). Removal is requested only when the Store build is present
        AND the MSI build exists -- never remove the Store build when it is
        the only pwsh on the machine.
    .PARAMETER StorePackage
        The Microsoft.PowerShell Appx package object, or $null when absent.
    .PARAMETER MsiPresent
        $true when C:\Program Files\PowerShell\7\pwsh.exe exists.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter()][object]$StorePackage,
        [Parameter()][bool]$MsiPresent
    )
    if (-not $StorePackage) {
        return [pscustomobject]@{
            ShouldRemove    = $false
            StoreBuildFound = $false
            Reason          = 'No Microsoft.PowerShell Store/MSIX package found.'
        }
    }
    if (-not $MsiPresent) {
        return [pscustomobject]@{
            ShouldRemove    = $false
            StoreBuildFound = $true
            Reason          = 'MSI PowerShell (C:\Program Files\PowerShell\7\pwsh.exe) not found; refusing to remove the Store build (would leave no pwsh).'
        }
    }
    return [pscustomobject]@{
        ShouldRemove    = $true
        StoreBuildFound = $true
        Reason          = $null
    }
}

function Remove-StorePwshPathEntry {
    <#
    .SYNOPSIS
        Remove the sealed Store/MSIX PowerShell directory from a persisted
        PATH scope (Machine or User), writing back only when it changed.
    .DESCRIPTION
        Isolates the environment side effect (the only non-pure step of the
        de-Store flow) behind a single mockable function so callers' tests can
        stub it out and never touch the real registry PATH.
    .PARAMETER Scope
        The environment-variable target: 'Machine' or 'User'.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope
    )
    try {
        $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
        if (-not $current) { return }
        $cleaned = Remove-StorePwshFromPathString -PathValue $current
        if ($cleaned -ne $current -and
            $PSCmdlet.ShouldProcess("$Scope PATH", 'Remove sealed WindowsApps PowerShell entry')) {
            [Environment]::SetEnvironmentVariable('Path', $cleaned, $Scope)
        }
    } catch {
        Write-Warning "Remove-StorePwshPathEntry: could not scrub $Scope PATH ($($_.Exception.Message))."
    }
}

function Remove-StorePwsh {
    <#
    .SYNOPSIS
        Remove the Microsoft Store / MSIX build of PowerShell 7 and scrub its
        sealed directory from PATH so the first-party MSI build wins.
    .DESCRIPTION
        Windows-only, idempotent and non-fatal. Detects the
        Microsoft.PowerShell Appx package and, when the MSI build is also
        present, removes the MSIX package for the current user (the running
        process keeps going even if it is the Store pwsh) and scrubs the sealed
        WindowsApps directory from the Machine and User PATH. Warns (never
        throws) when the Store build is absent, removal fails, or the MSI build
        is missing. Returns a result object describing what happened.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param()

    if (-not $IsWindows) {
        Write-Verbose 'Remove-StorePwsh: not Windows; the Store/MSIX PowerShell build does not apply.'
        return [pscustomobject]@{
            StoreBuildFound = $false
            Removed         = $false
            MsiPath         = $null
            Reason          = 'Not Windows; nothing to do.'
        }
    }

    $msiPwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $msiPresent = Test-Path -LiteralPath $msiPwsh

    $package = $null
    if (Get-Command -Name 'Get-AppxPackage' -ErrorAction Ignore) {
        try { $package = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop } catch { $package = $null }
    }

    $decision = Resolve-StorePwshRemoval -StorePackage $package -MsiPresent ([bool]$msiPresent)

    $result = [pscustomobject]@{
        StoreBuildFound = $decision.StoreBuildFound
        Removed         = $false
        MsiPath         = if ($msiPresent) { $msiPwsh } else { $null }
        Reason          = $decision.Reason
    }

    if (-not $decision.ShouldRemove) {
        if ($decision.StoreBuildFound) {
            Write-Warning "Remove-StorePwsh: $($decision.Reason)"
        } else {
            Write-Verbose "Remove-StorePwsh: $($decision.Reason)"
        }
        return $result
    }

    if ($PSCmdlet.ShouldProcess('Microsoft.PowerShell (Store/MSIX)', 'Remove-AppxPackage')) {
        try {
            $package | Remove-AppxPackage -ErrorAction Stop
            $result.Removed = $true
        } catch {
            $result.Reason = "Remove-AppxPackage failed: $($_.Exception.Message)"
            Write-Warning "Remove-StorePwsh: $($result.Reason)"
        }
    }

    Remove-StorePwshPathEntry -Scope 'Machine'
    Remove-StorePwshPathEntry -Scope 'User'

    try { Add-MachinePath -Path (Split-Path -Parent $msiPwsh) -Confirm:$false } catch { }

    return $result
}
