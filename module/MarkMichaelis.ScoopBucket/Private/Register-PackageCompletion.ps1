# Module-internal CLI tab-completion registration.
#
# Mirrors the well-tested bucket/Utils.ps1 implementation but lives
# inside the module so a migrated bundle can simply
# `Import-Module MarkMichaelis.ScoopBucket` and let Invoke-PackageInstall route
# completion through Register-PackageCompletion below.
#
# Strategy:
#   - Sentinel-delimited block per CLI in $PROFILE.AllUsersAllHosts.
#   - Native scriptblock preferred; PSCompletions fallback when no
#     native output is available.
#   - Idempotent: existing blocks preserved unless -Force.
#   - Requires elevation to write to AllUsersAllHosts; honours
#     SupportsShouldProcess.

$script:CompletionSentinelVersion = 'v3'

# Default sidecar root for cached native completer payloads (v3+, #216).
# Each registered CLI gets <Dir>\<cli>.ps1 holding the raw payload --
# `.ps1` lets the payload's leading `using namespace ...` parse legally,
# which it cannot when inlined inside an OnIdle Action scriptblock.
$script:CompletionSidecarDirDefault = if ($env:ProgramData) {
    Join-Path $env:ProgramData 'ScoopBucket\completions'
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'ScoopBucket\completions'
}

function Get-PackageCompletionSidecarDirectory {
    <#
    .SYNOPSIS
        Resolve the directory that holds cached native completer payloads
        (one `<cli>.ps1` per registered CLI). v3+ (#216).
    .DESCRIPTION
        Resolution order:
          1. -OverrideDirectory wins (test hook).
          2. When -ProfilePath is supplied AND differs from
             $PROFILE.AllUsersAllHosts, use `<dir-of-ProfilePath>\completions`.
             This keeps Pester sandboxes self-contained without an
             additional explicit hook.
          3. Otherwise return $script:CompletionSidecarDirDefault
             ($env:ProgramData\ScoopBucket\completions).
        Creates the directory on demand. Elevation is enforced upstream by
        Get-PackageCompletionProfilePath -- the prod sidecar lives in
        ProgramData which already requires admin to write to, and test
        overrides bypass elevation.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string]$ProfilePath,
        [string]$OverrideDirectory
    )

    $dir = $OverrideDirectory
    if (-not $dir) {
        if ($ProfilePath -and $ProfilePath -ne $PROFILE.AllUsersAllHosts) {
            $dir = Join-Path (Split-Path -Parent $ProfilePath) 'completions'
        } else {
            $dir = $script:CompletionSidecarDirDefault
        }
    }
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Write-PackageCompletionSidecar {
    <#
    .SYNOPSIS
        Atomically write the raw native completer payload for $Cli to
        `<Directory>\<Cli>.ps1` as UTF-8 (no BOM).
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [Parameter(Mandatory)][string]$Directory
    )
    $target = Join-Path $Directory ($Cli + '.ps1')
    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $Payload, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $target -Force
    return $target
}

function Remove-PackageCompletionSidecar {
    <#
    .SYNOPSIS
        Delete `<Directory>\<Cli>.ps1` if it exists. Inverse of
        Write-PackageCompletionSidecar. Silent no-op when absent.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Directory
    )
    $target = Join-Path $Directory ($Cli + '.ps1')
    if (Test-Path $target) {
        Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        return $true
    }
    return $false
}

function Format-DeferredCompletionBlock {
    <#
    .SYNOPSIS
        Wrap a completer-registration scriptblock string in a
        PowerShell.OnIdle one-shot deferred handler so the cost of
        Register-ArgumentCompleter (and any cached subprocess work
        baked into the inner code) is paid AFTER the prompt is drawn,
        not before. Profile-block only -- in-runspace activation via
        Import-PackageCompletion stays synchronous because the user
        explicitly asked to register NOW (#212).
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InnerCode)
    # `| Out-Null` keeps the returned PSEventJob off the success stream
    # so dot-sourcing the profile doesn't print a stray "Id Name ..."
    # banner. MaxTriggerCount=1 ensures we register the completer
    # exactly once -- after that the subscriber unregisters itself.
    return @"
`$null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
$InnerCode
} | Out-Null
"@
}

function Get-PackageCompletionProfilePath {
    [OutputType([string])]
    [CmdletBinding()]
    param([string]$OverridePath)

    if ($OverridePath) { return $OverridePath }

    $target = $PROFILE.AllUsersAllHosts
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Information "Host has no AllUsersAllHosts profile path; completion registration skipped." -InformationAction Continue
        return $null
    }
    if (-not (Test-IsElevated)) {
        throw "Completion registration requires an elevated PowerShell session (target: $target). Re-run from an Administrator prompt."
    }
    $dir = Split-Path -Parent $target
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        catch { throw "Cannot create AllUsersAllHosts profile directory '$dir': $($_.Exception.Message)" }
    }
    try {
        $fs = [System.IO.File]::Open($target, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        $fs.Dispose()
    } catch {
        throw "AllUsersAllHosts profile '$target' is not writable: $($_.Exception.Message). Re-run elevated."
    }
    return $target
}

function Resolve-PackageCompletionSource {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [scriptblock]$NativeCommand,
        [switch]$PreferPSCompletions
    )

    if ($NativeCommand -and -not $PreferPSCompletions) {
        $native = $null
        # Pass $Cli so multi-CLI packages (e.g. Sysinternals Suite) can emit
        # a per-CLI Register-ArgumentCompleter from a single shared
        # NativeCommandScript. Existing paramless scriptblocks (gh, rg, bw,
        # gcloud) simply ignore the extra argument.
        try { $native = & $NativeCommand $Cli 2>$null | Out-String } catch { }
        if ($native -and $native.Trim()) {
            $guarded = "if (Get-Command $Cli -ErrorAction SilentlyContinue) {`r`n$native}"
            # NativePayload is the RAW completer text (may start with
            # `using namespace ...`); callers that persist to a sidecar
            # .ps1 use it verbatim. `Code` is the legacy in-runspace form
            # wrapped in a Get-Command guard, still used by
            # Import-PackageCompletion's synchronous execution path.
            return @{ Source = 'Native'; Code = $guarded; PSCompletionsName = $null; NativePayload = $native }
        }
    }

    $pscModule = Get-Module -ListAvailable -Name PSCompletions | Select-Object -First 1
    if ($pscModule) {
        try {
            Import-Module PSCompletions -ErrorAction Stop
            $listOutput = & psc list 2>$null | Out-String
            if ($listOutput -match "(?im)^\s*$([regex]::Escape($Cli))(\s|$)") {
                $code = "if (Get-Command psc -ErrorAction SilentlyContinue) {`r`n    Import-Module PSCompletions -ErrorAction SilentlyContinue`r`n}"
                return @{ Source = 'PSCompletions'; Code = $code; PSCompletionsName = $Cli }
            }
        } catch { }
    }

    return @{ Source = 'Skipped'; Code = $null; PSCompletionsName = $null }
}

function Read-PackageCompletionProfileContent {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) {
        # Get-Content -Raw returns $null for an empty file; coalesce so
        # callers can pass the result straight to [regex]::IsMatch
        # without "Value cannot be null" exceptions.
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ($null -eq $raw) { return '' }
        return $raw
    }
    return ''
}

function Remove-PackageCompletionProfileBlock {
    <#
    .SYNOPSIS
        Strip the sentinel-delimited completion block for $Cli from $Content.
        Pure string transform — shares the regex shape with
        Set-PackageCompletionProfileBlock so the block format lives in
        exactly one place.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Cli
    )
    $pattern = "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:BEGIN \w+.*?^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:END\r?\n?"
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        return [pscustomobject]@{ Changed = $false; Content = $Content }
    }
    $before = $Content.Substring(0, $match.Index)
    $after  = $Content.Substring($match.Index + $match.Length)
    # Collapse the extra blank line we add when writing blocks (see
    # Set-PackageCompletionProfileBlock: appends `r`n`r`n before block).
    $combined = ($before.TrimEnd("`r","`n") + "`r`n" + $after.TrimStart("`r","`n"))
    if (-not $before -and -not $after.Trim()) { $combined = '' }
    return [pscustomobject]@{ Changed = $true; Content = $combined }
}

function Remove-PackageCompletionBlock {
    <#
    .SYNOPSIS
        Remove the sentinel-delimited completion block for $Cli from
        $PROFILE.AllUsersAllHosts (or -ProfilePath override). Inverse of
        Register-PackageCompletion.
    .DESCRIPTION
        Used by Uninstall-Package so removing a package also cleans up
        the completer it registered. Requires elevation to write to
        AllUsersAllHosts (mirrors Register-PackageCompletion). Honors
        SupportsShouldProcess. Returns a PSCustomObject describing the
        outcome (Action = 'Removed' | 'NotPresent' | 'Skipped' | 'WhatIf').
    .PARAMETER Cli
        Bare command name whose block to strip.
    .PARAMETER ProfilePath
        Test hook: read/write this file instead of AllUsersAllHosts.
        Bypasses the elevation check.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [string]$ProfilePath,
        # Test hook: read/delete sidecars from here instead of
        # $env:ProgramData\ScoopBucket\completions. v3+ (#216).
        [string]$SidecarDirectory
    )

    $target = Get-PackageCompletionProfilePath -OverridePath $ProfilePath
    if (-not $target) {
        return [pscustomobject]@{
            Cli = $Cli; Action = 'Skipped'; ProfilePath = $null
            Reason = 'No AllUsersAllHosts profile path available on this host.'
        }
    }
    if (-not (Test-Path $target)) {
        return [pscustomobject]@{
            Cli = $Cli; Action = 'NotPresent'; ProfilePath = $target
            Reason = 'Profile file does not exist.'
        }
    }

    $content  = Read-PackageCompletionProfileContent -Path $target
    $stripped = Remove-PackageCompletionProfileBlock -Content $content -Cli $Cli
    if (-not $stripped.Changed) {
        return [pscustomobject]@{
            Cli = $Cli; Action = 'NotPresent'; ProfilePath = $target
            Reason = "No completion block for '$Cli' in profile."
        }
    }

    if (-not $PSCmdlet.ShouldProcess($target, "Remove completion block for '$Cli'")) {
        return [pscustomobject]@{
            Cli = $Cli; Action = 'WhatIf'; ProfilePath = $target
            Reason = '-WhatIf or -Confirm declined.'
        }
    }

    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $stripped.Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $target -Force

    # v3 (#216): also delete the matching sidecar `<cli>.ps1` so we
    # don't leave orphaned cached payloads behind when a CLI is
    # uninstalled. Silent no-op if no sidecar exists (e.g. PSCompletions
    # source, or never registered under v3).
    try {
        $sidecarDir = Get-PackageCompletionSidecarDirectory -ProfilePath $target -OverrideDirectory $SidecarDirectory
        Remove-PackageCompletionSidecar -Cli $Cli -Directory $sidecarDir | Out-Null
    } catch {
        Write-Warning "Remove-PackageCompletionBlock: failed to remove sidecar for '$Cli': $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Cli = $Cli; Action = 'Removed'; ProfilePath = $target; Reason = $null
    }
}

function Set-PackageCompletionProfileBlock {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Block
    )
    $ver = $script:CompletionSentinelVersion
    $begin = "# ScoopBucket:CliCompletion:$Cli`:BEGIN $ver"
    $end   = "# ScoopBucket:CliCompletion:$Cli`:END"
    $pattern = "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:BEGIN \w+.*?^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:END\r?\n?"
    $newBlock = "$begin`r`n$Block`r`n$end`r`n"
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        $before = $Content.Substring(0, $match.Index)
        $after  = $Content.Substring($match.Index + $match.Length)
        return $before + $newBlock + $after
    }
    $trimmed = $Content.TrimEnd("`r","`n")
    if ($trimmed) { return "$trimmed`r`n`r`n$newBlock" }
    return $newBlock
}

function Register-PackageCompletion {
    <#
    .SYNOPSIS
        Register PowerShell tab-completion for a single CLI by embedding a
        sentinel-delimited block in the AllUsersAllHosts profile.
    .DESCRIPTION
        Module-internal helper called from Invoke-PackageInstall. Mirrors
        Register-CliCompletion in bucket/Utils.ps1 but reads/writes its
        own sentinel blocks (same sentinel format and v1 schema, so the
        two are interoperable — both produce identical block layout
        with `# ScoopBucket:CliCompletion:<cli>:BEGIN v1`).
    .PARAMETER Cli
        Bare command name (e.g. 'gh').
    .PARAMETER NativeCommand
        Scriptblock that emits the CLI's PowerShell completion source on
        stdout. When omitted (or empty output), the PSCompletions
        catalog probe runs as fallback.
    .PARAMETER Mode
        'native'        — only the native scriptblock, no PSCompletions fallback.
        'pscompletions' — skip native, go straight to PSCompletions probe.
        'auto'          — native first, fall back to PSCompletions.
        Defaults to 'auto'.
    .PARAMETER ProfilePath
        Test hook: write to this file instead of AllUsersAllHosts.
        Bypasses the elevation check.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [scriptblock]$NativeCommand,
        [ValidateSet('native','pscompletions','auto')][string]$Mode = 'auto',
        [string]$ProfilePath,
        # Pre-captured native completer text (the body of a
        # `Register-ArgumentCompleter -Native` block) as already
        # produced once by Get-BundlePackages in its child runspace.
        # When supplied AND -Mode is not 'pscompletions' AND the text
        # is non-empty, we skip Resolve-PackageCompletionSource's
        # native invocation entirely -- this is the fast path that
        # avoids re-spawning the CLI's `<cli> completions powershell`
        # at every install/update (#212).
        [string]$PreCapturedNative,
        # Test hook: write `<dir>\<cli>.ps1` sidecars here instead of
        # $env:ProgramData\ScoopBucket\completions. v3+ (#216).
        [string]$SidecarDirectory
    )

    $target = Get-PackageCompletionProfilePath -OverridePath $ProfilePath
    if (-not $target) {
        return [pscustomobject]@{
            Cli = $Cli; Source = 'Skipped'; Action = 'Skipped'; ProfilePath = $null
            Reason = 'No AllUsersAllHosts profile path available on this host.'
        }
    }

    $content  = Read-PackageCompletionProfileContent -Path $target
    $existed  = [regex]::IsMatch($content, "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($Cli))`:BEGIN \w+")

    # Fast path: cached native text bypasses Resolve-PackageCompletionSource.
    $resolved = $null
    if ($PreCapturedNative -and $PreCapturedNative.Trim() -and $Mode -ne 'pscompletions') {
        $guarded = "if (Get-Command $Cli -ErrorAction SilentlyContinue) {`r`n$PreCapturedNative}"
        $resolved = @{ Source = 'Native'; Code = $guarded; PSCompletionsName = $null; NativePayload = $PreCapturedNative }
    } else {
        $resolveSplat = @{ Cli = $Cli }
        if ($NativeCommand -and $Mode -ne 'pscompletions') {
            $resolveSplat['NativeCommand'] = $NativeCommand
        }
        if ($Mode -eq 'pscompletions') {
            $resolveSplat['PreferPSCompletions'] = $true
        }
        $resolved = Resolve-PackageCompletionSource @resolveSplat
    }

    # When Mode='native' (no fallback allowed) and resolution went to
    # PSCompletions, downgrade to Skipped.
    if ($Mode -eq 'native' -and $resolved.Source -eq 'PSCompletions') {
        $resolved = @{ Source = 'Skipped'; Code = $null; PSCompletionsName = $null }
    }

    if ($resolved.Source -eq 'Skipped') {
        $reason = if ($NativeCommand) {
            "Native command produced no output for '$Cli' and PSCompletions has no catalog entry."
        } else {
            "No -NativeCommand supplied and PSCompletions has no catalog entry for '$Cli'."
        }
        if ($NativeCommand -and $Mode -ne 'pscompletions') {
            Write-Warning "Register-PackageCompletion: $reason"
        }
        return [pscustomobject]@{
            Cli = $Cli; Source = 'Skipped'; Action = 'Skipped'; ProfilePath = $target
            Reason = $reason
        }
    }

    if ($resolved.Source -eq 'PSCompletions') {
        if ($PSCmdlet.ShouldProcess($Cli, "psc add $Cli")) {
            try {
                Import-Module PSCompletions -ErrorAction Stop
                & psc add $Cli 2>$null | Out-Null
            } catch {
                Write-Warning "psc add $Cli failed: $($_.Exception.Message)"
            }
        }
    }

    $shouldProcessAction = if ($existed) { "Replace completion block for '$Cli' ($($resolved.Source))" }
                           else         { "Add completion block for '$Cli' ($($resolved.Source))" }
    if (-not $PSCmdlet.ShouldProcess($target, $shouldProcessAction)) {
        return [pscustomobject]@{
            Cli = $Cli; Source = $resolved.Source; Action = 'WhatIf'
            ProfilePath = $target; Reason = '-WhatIf or -Confirm declined.'
        }
    }

    # Wrap the resolved code in a PowerShell.OnIdle one-shot deferred
    # handler so the cost of Register-ArgumentCompleter is paid AFTER
    # the prompt is drawn (#212). In-runspace activation via
    # Import-PackageCompletion deliberately bypasses this -- the user
    # there is asking to register NOW, not on next idle.
    #
    # v3 (#216): for Native sources, persist the raw payload to a
    # sidecar `<cli>.ps1` and make the deferred body a tiny dot-source.
    # `.ps1` files are the only place a leading `using namespace ...`
    # parses legally; inlining the payload inside the OnIdle Action
    # block (as v2 did) is a fatal parse error for clap/Rust completers
    # whose first line IS `using namespace System.Management.Automation`.
    if ($resolved.Source -eq 'Native' -and $resolved.NativePayload) {
        $sidecarDir  = Get-PackageCompletionSidecarDirectory -ProfilePath $target -OverrideDirectory $SidecarDirectory
        $sidecarPath = Write-PackageCompletionSidecar -Cli $Cli -Payload $resolved.NativePayload -Directory $sidecarDir
        $innerCode = "if (Get-Command $Cli -ErrorAction SilentlyContinue) {`r`n    . '$sidecarPath'`r`n}"
    } else {
        $innerCode = $resolved.Code
    }
    $deferred = Format-DeferredCompletionBlock -InnerCode $innerCode

    $newContent = Set-PackageCompletionProfileBlock -Content $content -Cli $Cli -Block $deferred
    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $newContent, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $target -Force

    return [pscustomobject]@{
        Cli = $Cli; Source = $resolved.Source
        Action = $(if ($existed) { 'Replaced' } else { 'Added' })
        ProfilePath = $target; Reason = $null
    }
}

function Test-PackageCompletionWorks {
    <#
    .SYNOPSIS
        End-to-end check that tab-completion is actually producing
        suggestions for $Cli. Spawns a fresh `pwsh -NoProfile`, loads
        the profile we just wrote, and asks PowerShell's completion
        engine to complete "$Cli ".
    .DESCRIPTION
        Closes the gap noted in the plan: the existing
        CliCompletionOutput.Tests.ps1 only checks generator output text;
        it never asks the completion engine itself whether the wiring
        actually produces matches. This helper does that by calling
        [System.Management.Automation.CommandCompletion]::CompleteInput
        in a child runspace that has dot-sourced the target profile.
    .PARAMETER Cli
        The CLI command name to probe.
    .PARAMETER ProfilePath
        The profile to load before probing. Defaults to AllUsersAllHosts.
    .OUTPUTS
        PSCustomObject with Cli, Verified (bool), MatchCount, FirstMatches.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [string]$ProfilePath
    )

    if (-not $ProfilePath) { $ProfilePath = $PROFILE.AllUsersAllHosts }
    if (-not (Test-Path $ProfilePath)) {
        return [pscustomobject]@{
            Cli = $Cli; Verified = $false; MatchCount = 0; FirstMatches = @()
            Reason = "Profile not found: $ProfilePath"
        }
    }

    # Skip when the CLI isn't on PATH — we can't meaningfully test
    # completion for a CLI we can't even invoke.
    if (-not (Get-Command $Cli -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Cli = $Cli; Verified = $false; MatchCount = 0; FirstMatches = @()
            Reason = "$Cli not on PATH; cannot probe completion."
        }
    }

    $pwsh = (Get-Process -Id $PID).Path
    if (-not $pwsh) { $pwsh = 'pwsh' }

    # The probe script: dot-source the profile, then ask the completion
    # engine to complete `$Cli ` (trailing space triggers argument
    # completion). Emit JSON so the parent process can deserialize.
    $probe = @"
`$ErrorActionPreference='SilentlyContinue'
. '$ProfilePath' 2>`$null
# The profile blocks written by Register-PackageCompletion defer their
# Register-ArgumentCompleter calls to PowerShell.OnIdle (#212). The
# OnIdle event does not auto-fire in non-interactive `pwsh -File`
# runs, so manually invoke any pending subscribers' actions before
# probing the completion engine.
foreach (`$sub in @(Get-EventSubscriber -SourceIdentifier 'PowerShell.OnIdle' -ErrorAction SilentlyContinue)) {
    try {
        `$cmd = `$sub.Action.Command
        if (`$cmd) { & ([scriptblock]::Create(`$cmd)) 2>`$null | Out-Null }
    } catch { }
}
`$line = '$Cli '
`$cc = [System.Management.Automation.CommandCompletion]::CompleteInput(`$line, `$line.Length, `$null)
`$results = @(`$cc.CompletionMatches | Select-Object -First 25 -ExpandProperty CompletionText)
@{ Count = `$cc.CompletionMatches.Count; Matches = `$results } | ConvertTo-Json -Compress
"@
    $probeFile = Join-Path $env:TEMP "ScoopBucket-completion-probe-$Cli-$PID.ps1"
    try {
        Set-Content -Path $probeFile -Value $probe -Encoding UTF8
        $json = & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probeFile 2>$null
        if (-not $json) {
            return [pscustomobject]@{
                Cli = $Cli; Verified = $false; MatchCount = 0; FirstMatches = @()
                Reason = 'Probe produced no output.'
            }
        }
        $obj = $json | ConvertFrom-Json -ErrorAction Stop
        $count = [int]$obj.Count
        $matches = @($obj.Matches)
        return [pscustomobject]@{
            Cli = $Cli
            Verified = ($count -ge 1)
            MatchCount = $count
            FirstMatches = $matches
            Reason = if ($count -ge 1) { $null } else { 'Completion engine returned 0 matches.' }
        }
    } catch {
        return [pscustomobject]@{
            Cli = $Cli; Verified = $false; MatchCount = 0; FirstMatches = @()
            Reason = "Probe error: $($_.Exception.Message)"
        }
    } finally {
        Remove-Item -Path $probeFile -ErrorAction Ignore
    }
}
