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
    #
    # Repair recipe (#397). A 'Registered' entry also carries enough
    # information to RE-register the CLI without re-running its install
    # script -- which matters because those scripts also install software
    # (GitConfigure.ps1 installs GitKraken), so they are not usable as a
    # completion-repair vector. Update-PackageCompletion reads these:
    #
    #   NativeCommand -- shell command emitting a PowerShell completer
    #                    (e.g. `gh completion -s powershell`).
    #   Switches      -- hand-curated top-level switch list, for CLIs that
    #                    ship no completion subcommand at all. Rendered into
    #                    a Register-ArgumentCompleter -Native block.
    #
    # Exactly one of the two is required on every 'Registered' entry, and
    # CompletionCoverage.Tests.ps1 asserts the values still match what the
    # owning Script actually registers, so the two cannot silently diverge.
    # ------------------------------------------------------------------------
    Clis = @(
        @{ Cli = 'gh';         Status = 'Registered';      Script = 'GitConfigure.ps1'; NativeCommand = 'gh completion -s powershell' }
        @{ Cli = 'gk';         Status = 'Registered';      Script = 'GitConfigure.ps1'; NativeCommand = 'gk completion powershell' }
        @{ Cli = 'pwsh';       Status = 'Registered';      Script = 'PowerShell.ps1'
           Switches = @(
               '-File', '-Command', '-EncodedCommand', '-ConfigurationName', '-CustomPipeName',
               '-ExecutionPolicy', '-InputFormat', '-OutputFormat', '-Login', '-MTA', '-STA',
               '-NoExit', '-NoLogo', '-NoProfile', '-NoProfileLoadTime', '-NonInteractive',
               '-SettingsFile', '-Version', '-WindowStyle', '-WorkingDirectory', '-Help'
           ) }
        @{ Cli = 'powershell'; Status = 'Registered';      Script = 'PowerShell.ps1'
           Switches = @(
               '-File', '-Command', '-EncodedCommand', '-ConfigurationName', '-ExecutionPolicy',
               '-InputFormat', '-OutputFormat', '-Mta', '-Sta', '-NoExit', '-NoLogo', '-NoProfile',
               '-NonInteractive', '-PSConsoleFile', '-Version', '-WindowStyle', '-Help'
           ) }
        @{ Cli = 'wsl';        Status = 'Registered';      Script = 'PowerShell.ps1'
           Switches = @(
               '--install', '--list', '-l', '--set-default', '-s', '--set-version',
               '--set-default-version', '--shutdown', '--terminate', '-t', '--unregister',
               '--import', '--export', '--distribution', '-d', '--user', '-u', '--exec', '-e',
               '--status', '--update', '--help'
           ) }
        @{ Cli = 'git';        Status = 'ModuleActivated'; Script = 'GitConfigure.ps1'; Module = 'posh-git';          Activation = 'Add-PoshGitToProfile' }
        @{ Cli = 'choco';      Status = 'ModuleActivated'; Script = 'Chocolatey.ps1';   Module = 'chocolateyProfile'; Activation = 'Import-Module.*chocolateyProfile\.psm1' }
        @{ Cli = 'scoop';      Status = 'ModuleActivated'; Script = 'PowerShell.ps1';   Module = 'scoop-completion';  Activation = 'Import-Module\s+scoop-completion' }
    )
}
