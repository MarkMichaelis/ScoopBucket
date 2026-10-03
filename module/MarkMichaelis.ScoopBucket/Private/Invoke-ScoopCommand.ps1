# Out-of-process dispatcher for scoop subcommands that run manifest scripts (#451).
#
# WHY A CHILD PROCESS
#
# Every bundle manifest in this bucket declares an `installer.script` that runs
# a `bucket\**\<Bundle>.ps1`, and every one of those scripts opens with
# `Import-Module MarkMichaelis.ScoopBucket -Force`. `-Force` is Remove-Module
# followed by Import-Module.
#
# Scoop's on-PATH `scoop.ps1` is a *shim* that dot-sources scoop's real entry
# script in the caller's process, so `& scoop install ...` from inside this
# module ran scoop inside THIS module's session state. Scoop then:
#
#   bin\scoop.ps1 -> exec 'install' -> libexec\scoop-install.ps1
#       . lib\install.ps1              # defines install_app AND
#                                      # ensure_install_dir_not_in_path
#       install_app
#           Invoke-Installer           # runs the manifest installer.script,
#                                      # i.e. Import-Module ... -Force
#           ensure_install_dir_not_in_path   # <-- next line
#
# The `-Force` re-import removes the module, which disposes the session state
# scoop-install.ps1 is still executing inside. Every function scoop dot-sourced
# vanishes, and `install_app` dies on the very next statement with
# "The term 'ensure_install_dir_not_in_path' is not recognized". The cascade
# then took out the module's own helpers (Write-UpdateStatus) and aborted the
# whole sweep.
#
# Adding 'lib\install.ps1' to Initialize-ScoopEnvironment's $required does NOT
# help: scoop-install.ps1 already dot-sources it. The file list was never the
# problem -- the session state was.
#
# Running scoop's entry script in a child process is the fix: scoop loads its
# own libraries into a session state we do not own and cannot unload, exactly
# as a plain `scoop install` from a shell does (which is why the bootstrap path
# always worked while the module path did not).
#
# Read-only subcommands (`scoop list`, `scoop status`) deliberately stay
# in-process: they cannot execute a manifest script, so they cannot trigger the
# teardown, and a child process per package would add seconds to every sweep.

function Resolve-ScoopEntryScript {
    <#
    .SYNOPSIS
        Absolute path to scoop's real entry script
        (<scoopRoot>\apps\scoop\current\bin\scoop.ps1), or the on-PATH
        scoop.ps1 shim as a fallback. $null when scoop cannot be located.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()

    $root = Resolve-ScoopRoot
    if ($root) {
        $entry = Join-Path $root 'apps\scoop\current\bin\scoop.ps1'
        if (Test-Path -LiteralPath $entry) { return $entry }
    }
    # Fall back to the shim on PATH. It forwards to the same bin\scoop.ps1, so
    # a child process running it is equally isolated.
    $shim = Get-Command 'scoop.ps1' -CommandType ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($shim -and $shim.Source) { return $shim.Source }
    return $null
}

function Get-PowerShellHostPath {
    <#
    .SYNOPSIS
        Path to the PowerShell executable hosting this session, so a child
        process runs the same edition (pwsh vs powershell) the caller is on.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()

    try {
        $path = (Get-Process -Id $PID).Path
        if ($path) { return $path }
    } catch {
        Write-Verbose "Get-PowerShellHostPath: could not resolve the host executable: $($_.Exception.Message)"
    }
    return 'pwsh'
}

function Invoke-ScoopCommand {
    <#
    .SYNOPSIS
        Run a scoop subcommand in a child PowerShell process.

    .DESCRIPTION
        Use for every scoop subcommand that can execute a manifest's
        installer / uninstaller script -- install, uninstall, update. See the
        file header for why in-process dispatch corrupts the run (#451).

        Scoop's own output (it writes progress via Write-Host) arrives on the
        child's stdout, so callers can stream it to the host or capture it with
        `*>&1` exactly as before. $LASTEXITCODE carries scoop's exit code, so
        the existing exit-code handling in every engine is unchanged.

    .PARAMETER ArgumentList
        The scoop argument vector, e.g. @('install', '-g', 'main/ripgrep').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$ArgumentList
    )

    $entry = Resolve-ScoopEntryScript
    if (-not $entry) {
        throw "Invoke-ScoopCommand: could not locate scoop's entry script (looked under `$env:SCOOP and for scoop.ps1 on PATH). Is scoop installed?"
    }

    # The module runs with $ErrorActionPreference = 'Stop' (see the .psm1).
    # Relax it for the native call so scoop's stderr chatter and a non-zero
    # exit code come back as output + an exit code -- which is what every
    # caller inspects -- instead of a terminating error. The same goes for
    # $PSNativeCommandUseErrorActionPreference, which a user profile may have
    # switched on (absent on Windows PowerShell; assigning it is harmless).
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false

    $psHost = Get-PowerShellHostPath
    Write-Verbose "Invoke-ScoopCommand: $psHost -NoProfile -File $entry $($ArgumentList -join ' ')"
    & $psHost -NoProfile -ExecutionPolicy Bypass -File $entry @ArgumentList
    # Capture before anything else can clobber it, then republish so callers
    # reading $LASTEXITCODE straight after this call see scoop's code.
    $exit = $LASTEXITCODE
    $global:LASTEXITCODE = $exit
}
