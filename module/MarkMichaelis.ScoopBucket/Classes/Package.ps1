# Declarative package descriptor for the ScoopBucket module.
#
# Bundle authors construct entries via the hashtable-cast syntax
# `[Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep'; ... }`
# which gives the readable hashtable call sites *and* compile-time-style
# property validation (typos in property names throw at load time, not
# silently no-op the way today's @{} lookups can).
#
# All scriptblock-typed fields use the `Script` suffix consistently:
# NativeCommandScript, CustomInstallScript, PostInstallScript, VerifyScript,
# PostUpdateScript.
#
# PostUpdateScript runs at the tail of an Update-Package pipeline (after
# the engine's upgrade succeeds and PATH is refreshed), mirroring the
# Install-time role of PostInstallScript. It is also the *only* update
# hook available to Installer='custom' packages — without it, custom
# installs surface as Skipped during Update-Package because there is no
# generic engine upgrade path.

class Package {
    [string]   $Name

    [ValidateSet('', 'winget', 'scoop', 'choco', 'npmGlobal', 'dotnetTool', 'custom')]
    [string]   $Installer = ''

    [string]   $Id = ''

    [ValidateSet('', 'msstore')]
    [string]   $Source = ''

    # 'global' is the default everywhere (machine-wide install requiring
    # admin). Bundles only specify Scope explicitly to opt into 'user' for
    # the rare per-user-only package. ('machine' is a legacy alias for
    # 'global' kept so existing winget-only entries keep parsing.)
    [ValidateSet('machine', 'global', 'user')]
    [string]   $Scope = 'global'

    [string[]] $CliCommands = @()

    [ValidateSet('none', 'native', 'pscompletions', 'auto')]
    [string]   $Completion = 'none'

    # Per-CLI expected-completion hashtable: CliName -> string[] of
    # subcommands the manifest promises TabExpansion2 will return for
    # that CLI after registration. Tested end-to-end by
    # CompletionEndToEnd.Tests.ps1 and statically by
    # CompletionContract.Tests.ps1. Required whenever Completion != 'none'.
    [hashtable] $ExpectedCompletions = @{}

    # Reporting-only classification of WHERE a native-completion block's
    # contents come from. Surfaced as the 'Mode' column of
    # Update-PackageCompletion so the output distinguishes:
    #   'native'  - sourced live from the tool's own completion engine
    #               (e.g. `dotnet complete`, `rg --generate
    #               complete-powershell`, `warp completions powershell`,
    #               `todoist completion powershell`); the registered block
    #               tracks whatever subcommands the installed build ships.
    #   'curated' - a hand-maintained subcommand/flag list shipped by this
    #               bucket because the tool has no PowerShell-native
    #               completion (e.g. bw, devenv, node, claude, 7z).
    # Only meaningful alongside a NativeCommandScript. Defaults to '' which
    # Update-PackageCompletion renders as 'curated' (the conservative,
    # under-claiming label) so authors only opt INTO 'native'.
    [ValidateSet('', 'native', 'curated')]
    [string]   $NativeCompletionKind = ''

    [scriptblock] $NativeCommandScript
    [scriptblock] $CustomInstallScript
    [scriptblock] $CustomUninstallScript
    [scriptblock] $PostInstallScript
    [scriptblock] $PostUpdateScript
    [scriptblock] $VerifyScript

    # Idempotent machine configuration for this package (e.g. writing tool
    # config files, persisting env vars, editing profiles). Unlike
    # PostInstallScript (install-only) and PostUpdateScript (update-only and
    # skipped on no-op upgrades), ConfigScript is re-applied on EVERY install
    # and EVERY update (including no-op updates where no newer version
    # exists), mirroring the way declarative Completion is always
    # (re)registered. Refresh on demand by running Update-Package against the
    # package by name. It must be idempotent because it runs repeatedly.
    # Receives the [Package] as $args[0], like the other *Script hooks. A
    # throw marks the package Failed, consistent with PostInstallScript /
    # PostUpdateScript.
    [scriptblock] $ConfigScript

    # Engine-specific extra arguments appended to the install command.
    # Currently only consumed by Install-WingetPackage. Use for cases
    # where winget needs a flag beyond the standard ones (e.g.
    # --skip-dependencies for packages with broken or already-satisfied
    # dependency manifests).
    [string[]] $WingetExtraArgs = @()

    [string[]] $DependsOn = @()

    # Forward-link to "always install together" companion packages in the
    # same bundle. Symmetric with DependsOn but the *other* direction:
    #
    #   A.Companions = @('B')   means
    #     install A  -> also install B (B scheduled AFTER A; implicit
    #                                   ordering edge in Resolve-PackageOrder)
    #     uninstall A -> also uninstall B (B removed BEFORE A)
    #
    # Cascade is restricted to the explicit Companions list so that
    # uninstalling a foundational package (e.g. '.NET SDK') does NOT
    # auto-yank every reverse-DependsOn (which would be too aggressive).
    # Same-bundle only for v1 (mirrors the DependsOn constraint).
    [string[]] $Companions = @()

    [string]   $CISkip = ''

    [string]   $Notes = ''

    # Per-package override for the winget upgrade timeout (minutes).
    # 0 (default) means "use the global default passed by the caller";
    # set this on heavy installers that legitimately need longer than
    # the default 5-minute cap (e.g. Visual Studio, Office 365). Only
    # consumed by Update-WingetPackage. See #269, #271.
    [int]      $UpdateTimeoutMinutes = 0

    # How Update-Package should try to update this package. Only meaningful
    # for Installer='custom' (engine packages are always 'Auto'):
    #   Auto                - engine update for engine installers; for
    #                         custom, run PostUpdateScript if present, else
    #                         report NoAutoUpdateSupport.
    #   Reinstall           - re-run the (idempotent) CustomInstallScript as
    #                         the update path, gated by VerifyScript.
    #   SelfManaged         - the package updates itself / is managed
    #                         externally (e.g. a hosted Office web add-in or
    #                         a self-updating client); nothing to do.
    #   NoAutoUpdateSupport - there is no mechanism this tool can drive.
    [ValidateSet('Auto', 'Reinstall', 'SelfManaged', 'NoAutoUpdateSupport')]
    [string]   $UpdateMode = 'Auto'

    # Cross-field invariants the type system can't express. Returns the
    # first violation as a string, or $null when the declaration is valid.
    #
    # This is the NON-throwing core so batch drivers can probe a package
    # without paying the class-method-throw tax: a PowerShell class method
    # that `throw`s under an advanced function leaks a spurious
    # non-terminating ErrorRecord onto the caller's error stream EVEN when
    # the throw is caught, which would double-report every invalid package.
    # Validate() (below) layers the throwing contract on top for callers
    # that want fail-fast semantics.
    [string] GetValidationError() {
        if (-not $this.Name) {
            return "Package: Name is required."
        }

        if ($this.CustomInstallScript -and -not $this.Installer) {
            $this.Installer = 'custom'
        }

        if (-not $this.Installer) {
            return "Package '$($this.Name)': Installer is required unless CustomInstallScript is set."
        }

        if ($this.Installer -ne 'custom' -and -not $this.Id) {
            return "Package '$($this.Name)': Id is required for installer '$($this.Installer)'."
        }

        if ($this.Installer -eq 'custom' -and -not $this.CustomInstallScript) {
            return "Package '$($this.Name)': CustomInstallScript is required when Installer='custom'."
        }

        # CustomUninstallScript is optional — not every install is reversible.
        # If present it must only accompany Installer='custom'.
        if ($this.CustomUninstallScript -and $this.Installer -ne 'custom') {
            return "Package '$($this.Name)': CustomUninstallScript is only valid when Installer='custom' (got '$($this.Installer)')."
        }

        if ($this.Source -eq 'msstore' -and $this.Installer -ne 'winget') {
            return "Package '$($this.Name)': Source='msstore' is only valid for Installer='winget'."
        }

        if ($this.Installer -eq 'scoop' -and $this.Id -notmatch '/') {
            return "Package '$($this.Name)': scoop Id '$($this.Id)' must include an explicit '<bucket>/<name>' prefix. Scoop selects buckets by add-order, so unprefixed ids are machine-dependent."
        }

        if ($this.Completion -in @('native', 'auto') -and -not $this.NativeCommandScript) {
            return "Package '$($this.Name)': NativeCommandScript is required when Completion='$($this.Completion)'."
        }

        if ($this.NativeCompletionKind -and -not $this.NativeCommandScript) {
            return "Package '$($this.Name)': NativeCompletionKind='$($this.NativeCompletionKind)' is only valid alongside a NativeCommandScript."
        }

        # Inverse direction: if a Package exposes CLIs on PATH, it MUST register
        # completion for them (one of native/pscompletions/auto). Leaving
        # Completion at its 'none' default while declaring CliCommands silently
        # ships a CLI with no Tab-completion -- the gap that hid Everything CLI
        # and 24 other packages before this guard existed.
        if ($this.CliCommands.Count -gt 0 -and $this.Completion -eq 'none') {
            return "Package '$($this.Name)': Completion='none' is not allowed when CliCommands is non-empty (CLIs: $($this.CliCommands -join ', ')). Either declare Completion='native'|'pscompletions'|'auto' and supply ExpectedCompletions, or remove CliCommands if the tool truly has no tab-completable surface."
        }

        if ($this.Completion -ne 'none') {
            if ($this.CliCommands.Count -eq 0) {
                return "Package '$($this.Name)': CliCommands must be non-empty when Completion='$($this.Completion)'."
            }
            if (-not $this.ExpectedCompletions -or $this.ExpectedCompletions.Count -eq 0) {
                return "Package '$($this.Name)': ExpectedCompletions hashtable is required when Completion='$($this.Completion)' so completion can be verified end-to-end (no mocks)."
            }
            foreach ($cli in $this.CliCommands) {
                if (-not $this.ExpectedCompletions.ContainsKey($cli)) {
                    return "Package '$($this.Name)': ExpectedCompletions is missing a key for CLI '$cli'."
                }
                $items = @($this.ExpectedCompletions[$cli])
                if ($items.Count -eq 0) {
                    return "Package '$($this.Name)': ExpectedCompletions['$cli'] is empty; supply at least one subcommand TabExpansion2 must produce."
                }
            }
        }

        if ($this.DependsOn -contains $this.Name) {
            return "Package '$($this.Name)': DependsOn cannot reference itself."
        }

        if ($this.Companions -contains $this.Name) {
            return "Package '$($this.Name)': Companions cannot reference itself."
        }

        # UpdateMode beyond the default 'Auto' only makes sense for custom
        # installs; engine packages always update through their engine.
        if ($this.UpdateMode -ne 'Auto' -and $this.Installer -ne 'custom') {
            return "Package '$($this.Name)': UpdateMode='$($this.UpdateMode)' is only valid when Installer='custom' (got '$($this.Installer)')."
        }

        return $null
    }

    # Throwing wrapper over GetValidationError() for callers that want
    # fail-fast semantics (e.g. bundle authoring / tests).
    [void] Validate() {
        $err = $this.GetValidationError()
        if ($err) {
            throw $err
        }
    }

    # Pretty-print for logs and Get-Package output.
    [string] ToString() {
        return "[$($this.Installer)] $($this.Name)$(if ($this.Id) { " ($($this.Id))" })"
    }
}
