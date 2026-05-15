# Shared PATH / environment helpers used by engine dispatchers and
# PostInstallScript scriptblocks. Kept here (Private/) so the module is
# self-contained and does not depend on bucket/Utils.ps1.

function Test-IsElevated {
    <#
    .SYNOPSIS
        Return $true when the current process is elevated (Windows admin
        or root on Unix-like). Used to decide whether completion
        registration / Machine-scope env updates are safe to attempt.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    if (-not $IsWindows -and ($PSVersionTable.PSEdition -eq 'Core')) {
        try { return ((whoami) -eq 'root') } catch { return $false }
    }
    try {
        $current = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($current)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Update-PathFromRegistry {
    <#
    .SYNOPSIS
        Refresh $env:Path from the Machine + User registry hives. After
        an installer drops a new shim folder onto Machine PATH the
        current process still has the stale value cached; calling this
        makes the freshly-installed CLI resolvable via Get-Command
        without spawning a new shell.
    #>
    [CmdletBinding()]
    param()
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @()
        if ($machine) { $parts += $machine }
        if ($user)    { $parts += $user }
        # De-dupe while preserving order.
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $unique = foreach ($p in ($parts -join ';' -split ';')) {
            if ($p -and $seen.Add($p)) { $p }
        }
        $env:Path = ($unique -join ';')
    } catch {
        Write-Verbose "Update-PathFromRegistry: $($_.Exception.Message)"
    }
}

function Add-MachinePath {
    <#
    .SYNOPSIS
        Idempotently append a directory to the Machine PATH environment
        variable AND the current process's $env:Path. No-op if the
        directory is already on Machine PATH (compared case-insensitively
        with trailing-slash normalization).
    .PARAMETER Path
        Absolute directory to add.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not $Path) { return }
    $norm = $Path.TrimEnd('\','/')
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $already = $false
    if ($machine) {
        $already = ($machine -split ';' | Where-Object { $_.TrimEnd('\','/') -ieq $norm } | Select-Object -First 1)
    }
    if ($already) {
        Write-Verbose "Add-MachinePath: '$Path' already present on Machine PATH."
    } else {
        if ($PSCmdlet.ShouldProcess($Path, 'Append to Machine PATH')) {
            $newPath = if ($machine) { "$machine;$Path" } else { $Path }
            try {
                [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
                Write-Verbose "Add-MachinePath: appended '$Path' to Machine PATH."
            } catch {
                Write-Warning "Add-MachinePath: could not write Machine PATH ($($_.Exception.Message)). Re-run elevated."
            }
        }
    }
    if (-not ($env:Path -split ';' | Where-Object { $_.TrimEnd('\','/') -ieq $norm } | Select-Object -First 1)) {
        $env:Path = if ($env:Path) { "$env:Path;$Path" } else { $Path }
    }
}

function Resolve-ScoopRoot {
    <#
    .SYNOPSIS
        Best-effort lookup of the active scoop root directory.
        Mirrors bucket/Utils.ps1's helper of the same name so the
        module is self-contained.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    if ($env:SCOOP -and (Test-Path (Join-Path $env:SCOOP 'apps\scoop\current'))) {
        return $env:SCOOP
    }
    $candidates = @(
        (Join-Path $env:ProgramData 'scoop'),
        (Join-Path $env:USERPROFILE 'scoop')
    )
    foreach ($root in $candidates) {
        if ($root -and (Test-Path (Join-Path $root 'apps\scoop\current'))) {
            return $root
        }
    }
    $shim = Get-Command 'scoop.ps1' -CommandType ExternalScript -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if (-not $shim) {
        $shim = Get-Command 'scoop.cmd' -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
    }
    if ($shim -and $shim.Source) {
        $root = Split-Path -Parent (Split-Path -Parent $shim.Source)
        if ($root -and (Test-Path (Join-Path $root 'apps\scoop\current'))) {
            return $root
        }
    }
    return $null
}
