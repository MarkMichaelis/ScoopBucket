@{
    # ------------------------------------------------------------------------
    # Completion coverage catalog (#278).
    #
    # Source of truth for CLIs whose tab-completion is wired by a PROCEDURAL
    # install script or JSON manifest -- i.e. those NOT guarded by
    # Package.Validate (which already forces every declarative [Package] with
    # CliCommands to declare a Completion mode). Without this catalog, a CLI
    # installed by a `winget/choco/scoop install` line can silently ship with
    # no completion (exactly how pwsh/powershell slipped through).
    #
    # CompletionCoverage.Tests.ps1 enforces, in both directions:
    #   * every entry here has a real backing registration in its Script, and
    #   * every `Register-CliCompletion -Cli <x>` across bucket/*.ps1 is listed
    #     here (so a new procedural registration must be catalogued).
    #
    # Status values:
    #   Registered      -- wired via Register-CliCompletion -Cli <Cli> -NativeCommand.
    #   ModuleActivated -- completion comes from an upstream PowerShell module
    #                      activated by <Activation> in <Script>.
    # ------------------------------------------------------------------------
    Clis = @(
        @{ Cli = 'gh';         Status = 'Registered';      Script = 'GitConfigure.ps1' }
        @{ Cli = 'gk';         Status = 'Registered';      Script = 'GitConfigure.ps1' }
        @{ Cli = 'pwsh';       Status = 'Registered';      Script = 'PowerShell.ps1' }
        @{ Cli = 'powershell'; Status = 'Registered';      Script = 'PowerShell.ps1' }
        @{ Cli = 'wsl';        Status = 'Registered';      Script = 'PowerShell.ps1' }
        @{ Cli = 'git';        Status = 'ModuleActivated'; Script = 'GitConfigure.ps1'; Module = 'posh-git';          Activation = 'Add-PoshGitToProfile' }
        @{ Cli = 'choco';      Status = 'ModuleActivated'; Script = 'Chocolatey.ps1';   Module = 'chocolateyProfile'; Activation = 'Import-Module.*chocolateyProfile\.psm1' }
        @{ Cli = 'scoop';      Status = 'ModuleActivated'; Script = 'PowerShell.ps1';   Module = 'scoop-completion';  Activation = 'Import-Module\s+scoop-completion' }
    )
}
