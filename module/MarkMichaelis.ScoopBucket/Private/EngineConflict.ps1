# Cross-engine install detection (#464).
#
# THE DEFECT
#
# No engine can see another engine's inventory. When a package's declared
# `Installer` is reclassified (scoop -> winget, per the README's
# engine-preference rule), the new engine's AlreadyInstalled probe reports
# nothing on a machine that already has the old copy:
#
#   PS> winget list --id Rclone.Rclone --exact
#   No installed package found matching input criteria.   (exit -1978335212)
#
# so the install path adds a SECOND copy. Both shims then exist and PATH
# ordering between the shim directories -- which no package declaration
# controls -- decides which binary actually runs:
#
#   C:\ProgramData\scoop\shims            <-- first, so the STALE copy wins
#   C:\Program Files\WinGet\Links
#
# Update-Package then dutifully upgrades the copy that is NOT being executed,
# so the machine reports itself current while running an old binary.
#
# WHAT IS DETECTED, AND WHY THAT SIGNAL
#
# The signal is not "some other engine has a package by this name" (that needs
# an id we do not have for the other engine, and an inventory call per engine
# per package). It is the condition that actually causes the harm:
#
#   the CLI this package promises on PATH currently resolves to a path owned
#   by a DIFFERENT engine than the one declared.
#
# That is exactly the PATH-shadowing state, it is one Get-Command plus a prefix
# comparison, and it is self-clearing: after the stale copy is gone the command
# resolves into the declared engine's directory and detection goes quiet, so
# the check is idempotent and leaves re-runs alone.
#
# Deliberate non-detections (a false positive would block a working install):
#   - the winning path belongs to no known engine (a vendor installer that adds
#     its own PATH entry, e.g. C:\Program Files\Git\cmd) -- unknown, not foreign;
#   - the package declares no CliCommands -- nothing lands on PATH, so there is
#     no PATH outcome to make deterministic;
#   - Installer='custom' -- it owns no engine inventory.
#
# The npmGlobal root list is deliberately narrow for the same reason: a global
# npm prefix of %ProgramFiles%\nodejs puts tool shims in the same directory as
# node.exe itself, so listing it would flag the Node.js package as a conflict
# with itself. Under-detecting there is safe (it is today's behaviour); a false
# refusal is not.

function Get-EngineRootMap {
    <#
    .SYNOPSIS
        Engine name -> the directory roots that engine owns on this machine.

    .DESCRIPTION
        Any path beneath one of an engine's roots is owned by that engine --
        both its link/shim directory and its app payload directory, so a shim
        (C:\ProgramData\scoop\shims\rclone.exe) and a direct app binary
        (C:\ProgramData\scoop\apps\adb\current\fastboot.exe) both resolve.

        Impure by design (reads the environment); callers that need
        determinism inject their own map via Get-PackageEngineConflict's
        -EngineRoot. Roots that do not exist are harmless: a prefix comparison
        against a non-existent directory simply never matches.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param()

    # Join-Path throws under the module's $ErrorActionPreference='Stop' when
    # the base is empty (which it is for every %ProgramData%-style variable on
    # non-Windows), so guard rather than let a missing variable break a sweep.
    $under = {
        param([string]$Base, [string]$Leaf)
        if (-not $Base) { return $null }
        Join-Path $Base $Leaf
    }

    $map = @{}

    # scoop: SCOOP / SCOOP_GLOBAL plus the two default roots. Global installs
    # live under SCOOP_GLOBAL (C:\ProgramData\scoop by default) and user
    # installs under ~\scoop, and a machine can have both.
    $scoopRoots = [System.Collections.Generic.List[string]]::new()
    # Resolve-ScoopRoot predates this file and does its own UNGUARDED
    # Join-Path against %ProgramData% / %USERPROFILE%, so it can throw the very
    # empty-base error the $under guard exists to avoid. Contain it here rather
    # than let one probe take down the whole map.
    $resolvedScoopRoot = $null
    try { $resolvedScoopRoot = Resolve-ScoopRoot } catch {
        Write-Verbose "Get-EngineRootMap: Resolve-ScoopRoot failed (ignored): $($_.Exception.Message)"
    }
    $scoopCandidates = @(
        $env:SCOOP
        $env:SCOOP_GLOBAL
        $resolvedScoopRoot
        (& $under $env:ProgramData 'scoop')
        (& $under $env:USERPROFILE 'scoop')
    )
    foreach ($candidate in $scoopCandidates) {
        if (-not $candidate) { continue }
        $norm = ([string]$candidate).TrimEnd('\', '/')
        if (-not $norm) { continue }
        if (-not ($scoopRoots | Where-Object { $_ -ieq $norm })) { $scoopRoots.Add($norm) }
    }
    $map['scoop'] = $scoopRoots.ToArray()

    # winget: the machine-scope Links/Packages tree and the per-user one.
    $map['winget'] = @(
        (& $under $env:ProgramFiles 'WinGet')
        (& $under $env:LOCALAPPDATA 'Microsoft\WinGet')
    ) | Where-Object { $_ }

    $chocoRoot = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { & $under $env:ProgramData 'chocolatey' }
    $map['choco'] = @($chocoRoot) | Where-Object { $_ }

    # See the file header for why %ProgramFiles%\nodejs is NOT listed here.
    $map['npmGlobal'] = @((& $under $env:APPDATA 'npm')) | Where-Object { $_ }

    $map['dotnetTool'] = @((& $under $env:USERPROFILE '.dotnet\tools')) | Where-Object { $_ }

    return $map
}

function Get-CommandSourcePath {
    <#
    .SYNOPSIS
        Absolute path of the executable/script that currently WINS on PATH for
        a bare command name, or $null when nothing resolves.

    .DESCRIPTION
        Restricted to Application / ExternalScript on purpose: this module
        exports `scoop` and `choco` wrapper FUNCTIONS, and a package that
        declares either as a CliCommand must be measured against the real
        binary on PATH, not the wrapper shadowing it.

        Separate from Get-PackageEngineConflict so the detection logic stays
        pure and testable; this is the one impure probe.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cli)

    try {
        $cmd = Get-Command -Name $Cli -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    } catch {
        Write-Verbose "Get-CommandSourcePath: resolving '$Cli' failed: $($_.Exception.Message)"
    }
    return $null
}

function Get-ScoopScopeRoot {
    <#
    .SYNOPSIS
        Scoop's global and user roots, kept apart: @{ Global = @(...); User = @(...) }.

    .DESCRIPTION
        Get-EngineRootMap deliberately flattens every scoop root into one array,
        because attribution only asks "is this path scoop's?". Choosing between
        `scoop uninstall -g <app>` and `scoop uninstall <app>` asks a different
        question, and getting it wrong produces a command that exits non-zero
        having removed nothing. %USERPROFILE% is not a sound proxy for the
        answer: SCOOP_GLOBAL can be redirected inside the user profile and SCOOP
        outside it, and both are supported scoop layouts.

        Global is checked first by callers, because that is the arrangement that
        actually holds a machine-wide install when the two roots coincide (which
        they do when SCOOP is pointed at the ProgramData root).
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param()

    $under = {
        param([string]$Base, [string]$Leaf)
        if (-not $Base) { return $null }
        Join-Path $Base $Leaf
    }

    $norm = {
        param($Candidates)
        $seen = [System.Collections.Generic.List[string]]::new()
        foreach ($c in @($Candidates)) {
            if (-not $c) { continue }
            $n = ([string]$c).Replace('/', '\').TrimEnd('\')
            if ($n -and -not ($seen | Where-Object { $_ -ieq $n })) { $seen.Add($n) }
        }
        return $seen.ToArray()
    }

    return @{
        Global = & $norm @($env:SCOOP_GLOBAL, (& $under $env:ProgramData 'scoop'))
        User   = & $norm @($env:SCOOP, (& $under $env:USERPROFILE 'scoop'))
    }
}

function Get-ScoopShimTarget {
    <#
    .SYNOPSIS
        The real executable a scoop shim forwards to, read from the sidecar
        `<name>.shim` scoop writes beside it. $null when there is none.

    .DESCRIPTION
        Needed because a shim's name does not identify the app that owns it:
        scoop's '7zip' app shims 7z.exe, so inferring the app from the shim
        name produces `scoop uninstall -g 7z`, which names an app that does not
        exist and fails for the user. The sidecar is one line:

            path = "C:\ProgramData\scoop\apps\7zip\current\7z.exe"

        Best-effort by design: this only sharpens a message, so a missing or
        malformed sidecar falls back to the shim name rather than failing.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $sidecar = [System.IO.Path]::ChangeExtension($Path, '.shim')
        if (-not $sidecar -or -not (Test-Path -LiteralPath $sidecar)) { return $null }
        foreach ($line in @(Get-Content -LiteralPath $sidecar -ErrorAction Stop)) {
            $m = [regex]::Match([string]$line, '^\s*path\s*=\s*"?(?<p>[^"]+?)"?\s*$')
            if ($m.Success) { return $m.Groups['p'].Value }
        }
    } catch {
        Write-Verbose "Get-ScoopShimTarget: could not read a shim sidecar for '$Path': $($_.Exception.Message)"
    }
    return $null
}

function Resolve-PathOwningEngine {
    <#
    .SYNOPSIS
        Which engine owns an absolute path, or $null when none does.

    .DESCRIPTION
        Longest matching root wins, so nested roots (a SCOOP pointed inside a
        chocolatey tree, say) attribute to the more specific one rather than
        whichever key the hashtable happened to enumerate first.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string]$Path,
        [Parameter(Mandatory)][hashtable]$EngineRoot
    )

    if (-not $Path) { return $null }

    # Compare on a single separator so a root and a path that disagree about
    # '/' vs '\' (a $env:SCOOP set with forward slashes, say) still match.
    $normPath = $Path.Replace('/', '\')

    $best = $null
    $bestLength = -1
    foreach ($engine in $EngineRoot.Keys) {
        foreach ($root in @($EngineRoot[$engine])) {
            if (-not $root) { continue }
            $norm = ([string]$root).Replace('/', '\').TrimEnd('\')
            if (-not $norm) { continue }
            # Require a separator after the root so C:\...\scoop never matches
            # a sibling directory whose name merely starts with 'scoop'.
            if ($normPath.StartsWith("$norm\", [System.StringComparison]::OrdinalIgnoreCase) -and
                $norm.Length -gt $bestLength) {
                $bestLength = $norm.Length
                $best = [string]$engine
            }
        }
    }
    return $best
}

function Resolve-EngineUninstallCommand {
    <#
    .SYNOPSIS
        The command a user must run to remove a foreign-engine install, as a
        copy-pasteable one-liner.

    .PARAMETER Id
        The declared PreviousId when the bucket recorded one. Authoritative
        when present; otherwise the target is inferred from $Path (the owning
        scoop app directory when the path exposes one, else the command's own
        base name).

    .PARAMETER ShimTargetResolver
        Scriptblock taking a path and returning what a shim at that path
        forwards to (or $null). Injected so the inference is testable without
        writing shim sidecars; defaults to Get-ScoopShimTarget.

    .PARAMETER ScoopScopeRoot
        @{ Global = @(...); User = @(...) } as Get-ScoopScopeRoot returns, used
        to decide scoop's -g. Injected so the decision is testable against
        layouts other than this machine's.

    .PARAMETER UserProfile
        Last-resort fallback for the -g decision when neither configured scoop
        root matched the path. `scoop uninstall <app>` against a -g install
        exits non-zero without removing anything, so this is not cosmetic.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Cli,
        [string]$Id,
        [scriptblock]$ShimTargetResolver,
        [hashtable]$ScoopScopeRoot,
        [string]$UserProfile
    )

    # Id may carry an engine prefix ('main/rclone'); every engine's uninstall
    # takes the bare trailing segment.
    $target = if ($Id) { ($Id -split '/')[-1] } else { [System.IO.Path]::GetFileNameWithoutExtension($Path) }
    $normPath = $Path.Replace('/', '\')

    switch ($Engine) {
        'scoop' {
            if (-not $Id) {
                # A path inside apps\<app>\ names the owning app exactly, which
                # the shim's own name does not: scoop's 'adb' app shims
                # fastboot.exe too, and `scoop uninstall fastboot` finds nothing.
                # When PATH resolved to the shim rather than the app binary,
                # follow the shim sidecar to the same answer -- 7z.exe belongs
                # to the '7zip' app, so the shim name alone is wrong.
                $appPattern = '[\\/]apps[\\/](?<app>[^\\/]+)[\\/]'
                $m = [regex]::Match($Path, $appPattern)
                if (-not $m.Success) {
                    $shimTarget = if ($ShimTargetResolver) { [string](& $ShimTargetResolver $Path) } else { Get-ScoopShimTarget -Path $Path }
                    if ($shimTarget) { $m = [regex]::Match($shimTarget, $appPattern) }
                }
                if ($m.Success) { $target = $m.Groups['app'].Value }
            }
            # Decide -g from scoop's ACTUAL configured roots, longest match
            # wins -- the same rule Resolve-PathOwningEngine uses, and the only
            # one that survives nesting: with SCOOP_GLOBAL=C:\scoop and
            # SCOOP=C:\scoop\user, a global-first check would claim every user
            # install too. Global breaks an exact-length tie, because when the
            # two roots are literally the same directory -g is the arrangement
            # holding a machine-wide install (and what a bundle install creates,
            # since Install-ScoopPackage passes -g for any non-user scope).
            $scopes = if ($ScoopScopeRoot) { $ScoopScopeRoot } else { Get-ScoopScopeRoot }
            $longestUnder = {
                param([string]$Subject, $Roots)
                $best = -1
                foreach ($r in @($Roots)) {
                    if (-not $r) { continue }
                    $n = ([string]$r).Replace('/', '\').TrimEnd('\')
                    if ($n -and $Subject.StartsWith("$n\", [System.StringComparison]::OrdinalIgnoreCase) -and
                        $n.Length -gt $best) {
                        $best = $n.Length
                    }
                }
                return $best
            }
            $globalDepth = & $longestUnder $normPath $scopes['Global']
            $userDepth   = & $longestUnder $normPath $scopes['User']
            if ($globalDepth -ge 0 -and $globalDepth -ge $userDepth) { return "scoop uninstall -g $target" }
            if ($userDepth -ge 0) { return "scoop uninstall $target" }

            # Neither configured root matched (an unusual layout, or roots we
            # could not read). Fall back to the user-profile heuristic rather
            # than guess blind.
            if ($UserProfile) {
                $up = $UserProfile.Replace('/', '\').TrimEnd('\')
                if ($normPath.StartsWith("$up\", [System.StringComparison]::OrdinalIgnoreCase)) {
                    return "scoop uninstall $target"
                }
            }
            return "scoop uninstall -g $target"
        }
        'winget' {
            if ($Id) { return "winget uninstall --exact --id $Id" }
            return "winget uninstall --exact $target"
        }
        'choco'      { return "choco uninstall -y $(if ($Id) { $Id } else { $target })" }
        'npmGlobal'  { return "npm uninstall --global $(if ($Id) { $Id } else { $target })" }
        'dotnetTool' { return "dotnet tool uninstall -g $(if ($Id) { $Id } else { $target })" }
        default      { return "<remove the $Engine install of '$Cli' at $Path>" }
    }
}

function Get-PackageEngineConflict {
    <#
    .SYNOPSIS
        Detect that a package's CLI is currently served by an engine OTHER than
        the one declared. Returns $null when there is no conflict.

    .DESCRIPTION
        Pure given its inputs: -CommandResolver supplies "what wins on PATH for
        this CLI" and -EngineRoot supplies "which directories each engine owns",
        so every case is testable without a real cross-engine install. The
        defaults (Get-CommandSourcePath / Get-EngineRootMap) are the live
        machine.

        Only the FIRST conflicting CLI is reported: the remedy is the same
        command for every CLI a single foreign install provides, and one clear
        instruction beats a list of near-duplicates.

    .PARAMETER Package
        The [Package] being installed (or a metadata-only PSCustomObject stand-in,
        hence the PSObject property probes).

    .PARAMETER EngineRoot
        Engine -> owned directory roots. Defaults to Get-EngineRootMap.

    .PARAMETER CommandResolver
        Scriptblock taking a CLI name and returning the absolute path that wins
        on PATH (or $null). Defaults to Get-CommandSourcePath.

    .PARAMETER ShimTargetResolver
        Forwarded to Resolve-EngineUninstallCommand; see it for why a shim's
        name is not a reliable app name.

    .PARAMETER UserProfile
        Forwarded to Resolve-EngineUninstallCommand for scoop's -g decision.

    .OUTPUTS
        $null, or a PSCustomObject with:
          Cli               the CLI whose resolution is foreign
          Path              where it resolves today (the evidence)
          Engine            the engine that owns that path
          DeclaredInstaller the package's declared Installer
          Declared          $true when Package.PreviousInstaller names this
                            same engine, i.e. the bucket predicted this
                            migration and an automatic removal is safe
          PreviousId        the declared PreviousId ('' when undeclared)
          UninstallCommand  copy-pasteable removal command
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [hashtable]$EngineRoot,
        [scriptblock]$CommandResolver,
        [scriptblock]$ShimTargetResolver,
        [hashtable]$ScoopScopeRoot,
        [string]$UserProfile = $env:USERPROFILE
    )

    $declared = [string]$Package.Installer
    # 'custom' owns no engine inventory and '' is an invalid declaration the
    # caller already reports; neither can be compared against an engine root.
    if (-not $declared -or $declared -eq 'custom') { return $null }

    $clis = @($Package.CliCommands)
    if ($clis.Count -eq 0) { return $null }

    if (-not $EngineRoot) { $EngineRoot = Get-EngineRootMap }
    # Without roots for the DECLARED engine we cannot tell "already correct"
    # from "foreign", and guessing would refuse working installs.
    if (-not $EngineRoot.ContainsKey($declared)) { return $null }

    # Metadata-only stand-ins (the Get-BundlePackages JSON round-trip) may not
    # carry these properties at all.
    $prevInstaller = ''
    $prevId        = ''
    if ($Package.PSObject.Properties['PreviousInstaller']) { $prevInstaller = [string]$Package.PreviousInstaller }
    if ($Package.PSObject.Properties['PreviousId'])        { $prevId        = [string]$Package.PreviousId }

    foreach ($cli in $clis) {
        if (-not $cli) { continue }
        $path = if ($CommandResolver) { [string](& $CommandResolver $cli) } else { Get-CommandSourcePath -Cli $cli }
        if (-not $path) { continue }

        $owner = Resolve-PathOwningEngine -Path $path -EngineRoot $EngineRoot
        if (-not $owner -or $owner -ieq $declared) { continue }

        $isDeclared = [bool]($prevInstaller -and ($prevInstaller -ieq $owner))
        $idForCommand = if ($isDeclared) { $prevId } else { '' }

        $commandArgs = @{
            Engine      = $owner
            Path        = $path
            Cli         = $cli
            Id          = $idForCommand
            UserProfile = $UserProfile
        }
        if ($ShimTargetResolver) { $commandArgs['ShimTargetResolver'] = $ShimTargetResolver }
        if ($ScoopScopeRoot)     { $commandArgs['ScoopScopeRoot']     = $ScoopScopeRoot }

        return [pscustomobject]@{
            Cli               = $cli
            Path              = $path
            Engine            = $owner
            DeclaredInstaller = $declared
            Declared          = $isDeclared
            PreviousId        = $idForCommand
            UninstallCommand  = Resolve-EngineUninstallCommand @commandArgs
        }
    }

    return $null
}

function New-PredecessorPackage {
    <#
    .SYNOPSIS
        A throwaway [Package] describing the predecessor install, so the
        existing Uninstall-<Engine>Package drivers can remove it unchanged.

    .DESCRIPTION
        Scope is inherited from the current declaration: bundle installs are
        machine-wide ('global') unless a package opts into 'user', and the
        predecessor was installed by this same tool from the same declaration,
        so its scope matches. CliCommands/Completion are deliberately left
        empty -- this object exists only to be uninstalled, and completion
        blocks belong to the package name, which is unchanged.
    #>
    [OutputType([object])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    return [Package]@{
        Name      = [string]$Package.Name
        Installer = [string]$Package.PreviousInstaller
        Id        = [string]$Package.PreviousId
        Scope     = if ($Package.Scope) { [string]$Package.Scope } else { 'global' }
    }
}

function Invoke-PredecessorUninstall {
    <#
    .SYNOPSIS
        Remove the declared predecessor install via its own engine's uninstall
        driver. Returns the driver's @{ State; Reason } hashtable.

    .DESCRIPTION
        Routed through the same drivers Uninstall-Package uses, so -WhatIf
        preview, presence probes and exit-code handling are identical and there
        is no second implementation of "how do I remove a scoop app".
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $previous = New-PredecessorPackage -Package $Package

    switch ($previous.Installer) {
        'winget'     { return Uninstall-WingetPackage     -Package $previous -WhatIf:$WhatIf }
        'scoop'      { return Uninstall-ScoopPackage      -Package $previous -WhatIf:$WhatIf }
        'choco'      { return Uninstall-ChocoPackage      -Package $previous -WhatIf:$WhatIf }
        'npmGlobal'  { return Uninstall-NpmGlobalPackage  -Package $previous -WhatIf:$WhatIf }
        'dotnetTool' { return Uninstall-DotnetToolPackage -Package $previous -WhatIf:$WhatIf }
        default      { return @{ State = 'Failed'; Reason = "Unknown PreviousInstaller '$($previous.Installer)' for '$($previous.Name)'." } }
    }
}
