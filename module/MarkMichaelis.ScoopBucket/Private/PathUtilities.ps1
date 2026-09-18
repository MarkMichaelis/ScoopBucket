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

function Get-ScoopShimDirectory {
    <#
    .SYNOPSIS
        Resolve the scoop `shims` directory that packages should write
        their .cmd shims into.

    .DESCRIPTION
        Scoop installs either per-user (~\scoop) or globally
        (C:\ProgramData\scoop). This bucket's own install.ps1 sets SCOOP
        to the ProgramData root at Machine scope, so the global layout is
        the one the repo itself creates -- a package that assumes the
        per-user default throws "Scoop shim directory ... not found" on
        exactly the machine the repo provisioned.

        Candidate roots are probed in order and the first whose `shims`
        subdirectory EXISTS wins:

          1. $env:SCOOP\shims
          2. $env:SCOOP_GLOBAL\shims
          3. $env:USERPROFILE\scoop\shims
          4. $env:ProgramData\scoop\shims

        Same order as bucket/developer/GitConfigBeyondCompare.ps1 uses to
        find scoop-installed binaries.

        Distinct from Resolve-ScoopRoot, which answers "is scoop itself
        installed here" by probing apps\scoop\current. A machine can have
        a populated shims directory on PATH without scoop's own app dir
        (shims dropped by other installers), and that directory is still
        the right place to write a shim.

        Note the two helpers also differ in fallback ORDER: Resolve-ScoopRoot
        tries ProgramData before USERPROFILE, this one the reverse (it follows
        GitConfigBeyondCompare.ps1). They agree whenever $env:SCOOP is set --
        which is how this repo's install.ps1 configures a machine -- and only
        diverge when both env vars are unset AND both a per-user and a global
        root exist. Preferring the per-user root there is deliberate: a shim
        is a per-user convenience, and writing to ProgramData needs admin.

        Does NOT check whether the resolved directory is on PATH; a shim
        written somewhere off PATH will not resolve. Existence is used as a
        proxy because scoop creates its own scoop.ps1/scoop.cmd shims during
        bootstrap, so an active root always has the folder.

    .OUTPUTS
        The resolved shims directory path, or $null when no candidate root
        has one. Callers decide whether that is fatal.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()

    $roots = @(
        $env:SCOOP
        $env:SCOOP_GLOBAL
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'scoop' })
        $(if ($env:ProgramData) { Join-Path $env:ProgramData 'scoop' })
    )

    foreach ($root in $roots) {
        if (-not $root) { continue }
        $shims = Join-Path $root 'shims'
        if (Test-Path -LiteralPath $shims -PathType Container) { return $shims }
    }
    return $null
}
