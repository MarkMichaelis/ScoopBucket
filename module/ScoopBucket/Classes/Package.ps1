# Declarative package descriptor for the ScoopBucket module.
#
# Bundle authors construct entries via the hashtable-cast syntax
# `[Package]@{ Name='ripgrep'; Installer='scoop'; Id='main/ripgrep'; ... }`
# which gives the readable hashtable call sites *and* compile-time-style
# property validation (typos in property names throw at load time, not
# silently no-op the way today's @{} lookups can).
#
# All scriptblock-typed fields use the `Script` suffix consistently:
# NativeCommandScript, CustomInstallScript, PostInstallScript, VerifyScript.

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

    [scriptblock] $NativeCommandScript
    [scriptblock] $CustomInstallScript
    [scriptblock] $PostInstallScript
    [scriptblock] $VerifyScript

    [string[]] $DependsOn = @()

    [string]   $CISkip = ''

    [string]   $Notes = ''

    # Cross-field invariants the type system can't express. Called by
    # Invoke-PackageInstall before any installer runs so schema errors
    # fail fast.
    [void] Validate() {
        if (-not $this.Name) {
            throw "Package: Name is required."
        }

        if ($this.CustomInstallScript -and -not $this.Installer) {
            $this.Installer = 'custom'
        }

        if (-not $this.Installer) {
            throw "Package '$($this.Name)': Installer is required unless CustomInstallScript is set."
        }

        if ($this.Installer -ne 'custom' -and -not $this.Id) {
            throw "Package '$($this.Name)': Id is required for installer '$($this.Installer)'."
        }

        if ($this.Installer -eq 'custom' -and -not $this.CustomInstallScript) {
            throw "Package '$($this.Name)': CustomInstallScript is required when Installer='custom'."
        }

        if ($this.Source -eq 'msstore' -and $this.Installer -ne 'winget') {
            throw "Package '$($this.Name)': Source='msstore' is only valid for Installer='winget'."
        }

        if ($this.Installer -eq 'scoop' -and $this.Id -notmatch '/') {
            throw "Package '$($this.Name)': scoop Id '$($this.Id)' must include an explicit '<bucket>/<name>' prefix. Scoop selects buckets by add-order, so unprefixed ids are machine-dependent."
        }

        if ($this.Completion -in @('native', 'auto') -and -not $this.NativeCommandScript) {
            throw "Package '$($this.Name)': NativeCommandScript is required when Completion='$($this.Completion)'."
        }

        if ($this.DependsOn -contains $this.Name) {
            throw "Package '$($this.Name)': DependsOn cannot reference itself."
        }
    }

    # Pretty-print for logs and Get-Package output.
    [string] ToString() {
        return "[$($this.Installer)] $($this.Name)$(if ($this.Id) { " ($($this.Id))" })"
    }
}
