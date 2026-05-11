#Requires -Version 5.1
<#
.SYNOPSIS
    Apply idempotent post-install fixes to make installed CLIs reachable in CI.

.DESCRIPTION
    Test-Installs.ps1 parses bundle .ps1 files and re-issues installer commands;
    it does NOT dot-source the bundles, so any sidecar PATH/shim logic embedded
    in the bundle .ps1 (e.g. OSBasePackages.ps1's sysinternals PATH-add) never
    runs in CI.  This script reproduces those side effects so the downstream
    cli-availability discovery (#45 Phase 2) sees an accurate picture.

    All operations are idempotent and best-effort; missing prerequisites only
    emit warnings.

.NOTES
    Hooks applied (each guarded so a single failure does not cascade):
      1. Refresh $env:Path from registry (Machine + User) so newly-installed
         shim/install dirs are visible in this process.
      2. Sysinternals: append `scoop prefix sysinternals` directory to Machine
         PATH so individual tools (procexp, procmon, psexec, handle, ...) are
         callable without per-tool shims.
      3. Visual Studio 2026: locate devenv.exe via vswhere and create a scoop
         shim named `devenv` so the editor is reachable from the command line.
      4. BeyondCompare: replace scoop's default `bcomp` shim (which targets
         BComp.exe — a GUI launcher that returns immediately) with one that
         targets BComp.com (console-waiting variant, correct for VCS hooks
         and scripts).  Also append the BC install directory to Machine PATH
         so `bcomp.exe` and `BCompare.exe` remain reachable by explicit name.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Update-PathFromRegistry {
    [CmdletBinding()]
    param()
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $merged  = @($machine, $user) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd(';') } | Where-Object { $_ } | Join-String -Separator ';'
        if ($merged) {
            $env:Path = $merged
            Write-Host "  PATH refreshed from registry ($($merged.Length) chars)"
        }
    } catch {
        Write-Warning "  PATH refresh failed: $($_.Exception.Message)"
    }
}

function Add-MachinePathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-Path $Dir)) {
        Write-Warning "  Skipping PATH-add: directory not found: $Dir"
        return
    }
    try {
        $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $present = ($current -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') })
        if ($present) {
            Write-Host "  Already on Machine PATH: $Dir"
            return
        }
        [Environment]::SetEnvironmentVariable('Path', "$current;$Dir", 'Machine')
        Write-Host "  Added to Machine PATH: $Dir"
    } catch {
        Write-Warning "  Failed to add Machine PATH entry '$Dir': $($_.Exception.Message)"
    }
}

function Invoke-Hook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block
    )
    Write-Host "::group::Post-install hook: $Name"
    try {
        & $Block
    } catch {
        Write-Warning "Hook '$Name' threw: $($_.Exception.Message)"
    } finally {
        Write-Host '::endgroup::'
    }
}

# --- 1. PATH refresh ----------------------------------------------------------
Invoke-Hook -Name 'PATH refresh from registry' -Block {
    Update-PathFromRegistry
}

# --- 2. Sysinternals install dir on Machine PATH ------------------------------
Invoke-Hook -Name 'Sysinternals dir on Machine PATH' -Block {
    if (-not (Get-Command scoop -ErrorAction Ignore)) {
        Write-Warning '  scoop not on PATH; cannot resolve sysinternals install dir'
        return
    }
    $siDir = $null
    try { $siDir = (& scoop prefix sysinternals 2>$null | Select-Object -First 1) } catch { }
    if (-not $siDir) {
        Write-Warning '  `scoop prefix sysinternals` returned nothing (package not installed?)'
        return
    }
    Add-MachinePathEntry -Dir $siDir
}

# --- 3. devenv shim (Visual Studio 2026 Enterprise) ---------------------------
Invoke-Hook -Name 'devenv shim via vswhere' -Block {
    $vswhere = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe",
        "${env:ChocolateyInstall}\bin\vswhere.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if (-not $vswhere) {
        Write-Warning '  vswhere.exe not found in any standard location'
        return
    }
    $devenv = & $vswhere -latest -prerelease -property productPath 2>$null | Select-Object -First 1
    if (-not $devenv -or -not (Test-Path $devenv)) {
        Write-Warning "  vswhere returned no productPath (or path missing): '$devenv'"
        return
    }
    if (-not (Get-Command scoop -ErrorAction Ignore)) {
        Write-Warning '  scoop not on PATH; cannot create devenv shim'
        return
    }
    # `scoop shim add` is idempotent only insofar as it overwrites an existing
    # shim with the same name; calling it repeatedly is safe.
    & scoop shim add devenv "$devenv" 2>&1 | ForEach-Object { Write-Host "    $_" }
    Write-Host "  devenv shim points at: $devenv"
}

# --- 4. BeyondCompare: bcomp -> BComp.com remap + BC dir on Machine PATH ------
Invoke-Hook -Name 'BeyondCompare bcomp.com remap + PATH' -Block {
    if (-not (Get-Command scoop -ErrorAction Ignore)) {
        Write-Warning '  scoop not on PATH; cannot manipulate BeyondCompare shims'
        return
    }
    $bcDir = $null
    try { $bcDir = (& scoop prefix beyondcompare 2>$null | Select-Object -First 1) } catch { }
    if (-not $bcDir -or -not (Test-Path $bcDir)) {
        Write-Warning '  `scoop prefix beyondcompare` returned nothing (package not installed?)'
        return
    }
    $bcompCom = Join-Path $bcDir 'BComp.com'
    if (-not (Test-Path $bcompCom)) {
        Write-Warning "  BComp.com not found at: $bcompCom"
        return
    }
    # Remove existing `bcomp` shim (default scoop manifest points it at
    # BComp.exe — the GUI launcher that returns immediately).  `scoop shim rm`
    # is non-fatal if the shim doesn't exist, but we ignore output either way.
    & scoop shim rm bcomp 2>&1 | Out-Null
    & scoop shim add bcomp "$bcompCom" 2>&1 | ForEach-Object { Write-Host "    $_" }
    Write-Host "  bcomp shim now -> $bcompCom"

    # Add the install dir to Machine PATH so `bcomp.exe` and `BCompare.exe`
    # are reachable by explicit name (the .exe shims would otherwise collide
    # with the `bcomp` shim above).
    Add-MachinePathEntry -Dir $bcDir
}

# Final refresh so the immediately-following CLI-availability discovery picks
# up everything we just touched without needing a separate process.
Invoke-Hook -Name 'Final PATH refresh' -Block {
    Update-PathFromRegistry
}

Write-Host 'Post-install hooks complete.'
