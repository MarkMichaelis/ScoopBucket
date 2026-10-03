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

        Falls back to 'pwsh' on PATH when the hosting process is not itself a
        PowerShell executable -- the module can be imported into a runspace
        embedded in an arbitrary host (a .NET app, an editor extension host),
        and `& <that host> -File scoop.ps1` would be nonsense.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()

    try {
        $path = (Get-Process -Id $PID).Path
        if ($path) {
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($path)
            if ($leaf -in @('pwsh', 'powershell')) { return $path }
            Write-Verbose "Get-PowerShellHostPath: hosting process '$leaf' is not a PowerShell executable; falling back to pwsh on PATH."
        }
    } catch {
        Write-Verbose "Get-PowerShellHostPath: could not resolve the host executable: $($_.Exception.Message)"
    }
    # Prefer pwsh, but accept Windows PowerShell when that is all there is.
    foreach ($candidate in 'pwsh', 'powershell') {
        $cmd = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return 'pwsh'
}

function Test-ScoopCommandRunsManifestScript {
    <#
    .SYNOPSIS
        Does this scoop subcommand execute a manifest's installer / uninstaller
        script (and therefore have to run out of process)?

    .DESCRIPTION
        The list is not a guess. In scoop 0.6.0 exactly three libexec commands
        reach install_app / uninstall_app / Invoke-HookScript --
        scoop-install.ps1, scoop-uninstall.ps1 and scoop-update.ps1 -- and
        scoop-import.ps1 dot-sources scoop-install.ps1 to do its work. Verify
        with:

            Select-String -Pattern 'install_app|uninstall_app|Invoke-HookScript' `
                -Path (Join-Path $env:SCOOP 'apps/scoop/current/libexec/scoop-*.ps1')

        Everything else (list, status, info, which, prefix, search, cat, home,
        export, bucket, hold, cleanup, cache, ...) is read-only with respect to
        app contents and stays in-process, where it costs nothing.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param([string]$Command)

    return ([string]$Command).ToLowerInvariant() -in @('install', 'uninstall', 'update', 'import')
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
    [OutputType([string])]
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
    # Quote each argument in the log so a path containing a space doesn't render
    # as a command line that isn't what actually ran (the real invocation splats
    # the array, so every element is passed as one argument regardless).
    $quoted = ($ArgumentList | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    Write-Verbose "Invoke-ScoopCommand: $psHost -NoProfile -File ""$entry"" $quoted"
    # Clear first: if the host executable itself cannot be launched, `&` throws
    # without ever setting $LASTEXITCODE, and republishing a stale value from an
    # unrelated earlier command would read as a successful scoop run.
    $global:LASTEXITCODE = $null
    & $psHost -NoProfile -ExecutionPolicy Bypass -File $entry @ArgumentList
    # Capture before anything else can clobber it, then republish so callers
    # reading $LASTEXITCODE straight after this call see scoop's code.
    $exit = $LASTEXITCODE
    $global:LASTEXITCODE = $exit
}
