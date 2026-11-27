#requires -Version 7.0
# The packages more than one bundle installs, each declared ONCE (#563).
#
# A bundle includes a group inside its own `$Packages = [Package[]]@(...)`
# assignment:
#
#     & "$PSScriptRoot\SharedPackages.ps1" -Name 'Visual Studio Code'
#
# Every bundle that includes a group therefore holds the same declaration, so
# the picker shows one checkbox for it ("also in ...") and Install-Package,
# Update-Package and Uninstall-Package behave the same whichever bundle a name
# resolves to. Two copies could drift; one cannot. SharedPackages.Tests.ps1
# fails when two bundle files declare the same Installer|Id.
#
# Rules for a group:
#   - Call it with the call operator (&), inside the $Packages assignment:
#     Get-BundlePackageObjects evaluates only that assignment.
#   - Sub-items (Companions / DependsOn) are same-bundle only, so a group
#     carries its companions with it, and a bundle that includes a group whose
#     package DependsOn another group includes that group too (GitHub Copilot
#     CLI -> Node.js).
#   - It lives at the bucket root, beside the bundles that include it, and
#     every one of their manifests ships it, so $PSScriptRoot finds it both in
#     a checkout and in a scoop app directory.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Name
)

$groups = [ordered]@{
'Git' = @(
    # Git's set-up, split out of the retired GitConfigure manifest so each
    # piece can be turned off on its own (#563). Installed with Git as its
    # companions; OS Base and Git Tools both show them under Git.
    [Package]@{ Name = 'ssh-agent';                    Installer = 'scoop'; Id = 'MarkMichaelis/GitSshAgent' }
    [Package]@{ Name = 'Global Git settings';          Installer = 'scoop'; Id = 'MarkMichaelis/GitGlobalSettings' }
    [Package]@{ Name = 'Debug diff tools';             Installer = 'scoop'; Id = 'MarkMichaelis/GitDebugDiffTools' }
    [Package]@{ Name = 'Share Git settings from Data'; Installer = 'scoop'; Id = 'MarkMichaelis/GitShareDataSettings' }
    # Off: it puts private SSH keys in the Data folder, which syncs to Dropbox.
    [Package]@{ Name = 'Link ~\.ssh to Data';          Installer = 'scoop'; Id = 'MarkMichaelis/GitLinkSshToData'; Default = $false }
    [Package]@{
        Name              = 'Git'
        Installer         = 'winget'
        Id                = 'Git.Git'
        # The bucket itself needs git: always installed, never unchecked (#559).
        Required          = $true
        # install.ps1 needs git before any bucket exists, so it installs this
        # predecessor; declaring it is what hands the machine over to this
        # package. Winget also recognizes a Program Files install from any
        # other source (#498).
        PreviousInstaller = 'scoop'
        PreviousId        = 'main/mingit'
        Companions        = @('ssh-agent', 'Global Git settings', 'Debug diff tools', 'Share Git settings from Data', 'Link ~\.ssh to Data')
        CliCommands       = @('git')
        Completion        = 'auto'
        Notes             = 'Git for Windows, machine scope. git has no PowerShell completion command. Git Tools'' posh-git item activates posh-git, which is far richer, so the hand-curated subcommand list below stands aside wherever posh-git is available; registering over it would make the profile order decide which completer wins.'
        ExpectedCompletions = @{ git = @('status','commit','push') }
        NativeCommandScript = {
            @"
if (-not (`$env:PSModulePath -split ';' | Where-Object { `$_ -and (Test-Path -LiteralPath (Join-Path `$_ 'posh-git')) })) {
    Register-ArgumentCompleter -Native -CommandName git -ScriptBlock {
        param(`$wordToComplete, `$commandAst, `$cursorPosition)
        @(
            'add','bisect','branch','checkout','cherry-pick','clone','commit','config','diff',
            'fetch','grep','init','log','merge','mv','pull','push','rebase','remote','reset',
            'restore','revert','rm','show','stash','status','switch','tag','worktree'
        ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
        }
    }
}
"@
        }
    }
)
'Visual Studio Code' = @(
    # Git's diff and merge tool settings for VS Code; installed with VS Code as
    # its companion, and can be turned off on its own (#559).
    [Package]@{ Name = 'Git settings for VS Code'; Installer = 'scoop'; Id = 'MarkMichaelis/GitConfigVSCode' }
    [Package]@{
        Name        = 'Visual Studio Code'
        Installer   = 'winget'
        Id          = 'Microsoft.VisualStudioCode'
        Companions  = @('Git settings for VS Code')
        CliCommands = @('code')
        Completion  = 'auto'
        Notes       = '`code --help` lists CLI switches but `code` has no completion subcommand and no PSCompletions catalog entry. Hand-curated flag list.'
        ExpectedCompletions = @{ code = @('--help','--diff','--new-window') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName code -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--diff','--merge','--add','--goto','--new-window','--reuse-window',
        '--wait','--locale','--user-data-dir','--profile','--extensions-dir','--list-extensions',
        '--install-extension','--uninstall-extension','--enable-proposed-api','--status',
        '--prof-startup','--disable-extensions','--disable-extension','--sync','--inspect-extensions',
        '--inspect-brk-extensions','--verbose','--log','--telemetry'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
        # EDITOR is the fallback every CLI tool reaches for when it needs the
        # user to edit a file: git with no core.editor, npm, gh, and most
        # POSIX-minded tooling. ConfigScript rather than PostInstallScript so
        # it is re-applied on updates too, not just first install.
        #
        # The decision (claim EDITOR only when unset or already pointing at
        # VS Code; never revert a deliberately chosen editor; warn rather than
        # throw when a machine-scope write needs elevation) lives in
        # Set-DefaultEditorVariable, next to the other desired-state hooks.
        # Because ConfigScript may call only exported functions (scoop runs a
        # bundle outside the module, #524).
        ConfigScript = { Set-DefaultEditorVariable | Out-Null }
    }
)
'Node.js' = @(
    [Package]@{
        Name        = 'Node.js'
        Installer   = 'choco'
        Id          = 'nodejs'
        CliCommands = @('node','npm','npx')
        Completion  = 'auto'
        Notes       = 'STAYS ON CHOCO DELIBERATELY -- do not "correct" this to winget without re-checking the versions below (#465). README rule 1 prefers winget, and winget does carry Node.js from the OpenJS Foundation with a machine-scope wix MSI, but rule 2''s "when winget lacks the package" extends to materially lagging it, and it does lag: as observed 2026-10-03, choco nodejs was 26.10.0 while winget OpenJS.NodeJS was 26.7.0 (three minors behind) and OpenJS.NodeJS.LTS was 24.19.0. Moving would be a downgrade, and every npx-based MCP server below depends on this entry, so the owner ruled it stays. Re-check those four numbers before revisiting; if winget catches up, the exception expires -- that is exactly how ripgrep''s own version-based exception expired and had to be corrected in #465. Required for every npx-based MCP server (context7, playwright, filesystem, github). node/npm have PSCompletions entries but npx does not, so ship a shared hand-curated NativeCommandScript that registers all three uniformly here.'
        ExpectedCompletions = @{
            node = @('--help','--version','--eval')
            npm  = @('install','run','version')
            npx  = @('--help','--version','--package')
        }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName node -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--eval','--print','--check','--interactive','--require','--inspect',
        '--inspect-brk','--enable-source-maps','--experimental-modules','--experimental-vm-modules',
        '--unhandled-rejections','--use-openssl-ca','--no-warnings','--trace-warnings'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
Register-ArgumentCompleter -Native -CommandName npm -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'install','uninstall','update','run','start','test','version','init','publish','pack',
        'config','cache','audit','outdated','ls','list','link','unlink','search','view','prune',
        'rebuild','restart','stop','adduser','login','logout','whoami','--help','--version'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
Register-ArgumentCompleter -Native -CommandName npx -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--package','--call','--no-install','--ignore-existing','--yes','--no',
        '--shell','--cache','--prefer-offline','--prefer-online','--offline','--quiet','--verbose'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
)
'GitHub Copilot CLI' = @(
    [Package]@{
        Name        = 'GitHub Copilot CLI'
        # #547: declared under winget like the DeveloperBasePackages copy, for
        # the same reason as 'Claude Code CLI' above -- the retired
        # MarkMichaelis/GitHubCopilotCli scoop manifest only wrapped winget
        # GitHub.Copilot (a portable copilot.exe), so the wrapper declaration
        # hid new versions and made the #464 gate refuse the real install.
        Installer   = 'winget'
        Id          = 'GitHub.Copilot'
        PreviousInstaller = 'scoop'
        PreviousId  = 'MarkMichaelis/GitHubCopilotCli'
        CliCommands = @('copilot')
        DependsOn   = @('Node.js')
        Completion  = 'auto'
        Notes       = '`copilot completion` only supports bash/zsh/fish; not in PSCompletions catalog (#73). Hand-curated top-level flag/command list.'
        ExpectedCompletions = @{ copilot = @('--help','--version','--model') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName copilot -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--model','--prompt','--allow-tool','--deny-tool',
        '--allow-all-tools','--add-dir','--no-color','--banner','--resume','--continue',
        '--screen-reader','--log-level','--log-dir','-p','--allow-all-paths'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
)
'Playwright' = @(
    [Package]@{
        Name        = 'Playwright'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/Playwright'
        CliCommands = @('playwright')
        DependsOn   = @('Node.js')
        Completion  = 'auto'
        Notes       = 'Browser automation runtime for the playwright MCP server; the member manifest performs the global npm install and the Chromium download. playwright has no completion subcommand and no PSCompletions entry; hand-curated command/flag list, kept identical to the Playwright member bundle so name-resolution order cannot change uninstall/update behavior.'
        ExpectedCompletions = @{ playwright = @('test','install','codegen','show-report') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName playwright -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'open','codegen','install','install-deps','uninstall','screenshot','pdf',
        'show-trace','trace','cli','mcp','test','show-report','merge-reports',
        'clear-cache','init-agents','init-skills','help',
        '--help','-h','--version','-V',
        '--browser','--headed','--project','--reporter','--workers','--debug','--ui','--grep',
        '--list','--repeat-each','--retries','--timeout','--update-snapshots','--trace','--config'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
)
}

foreach ($n in $Name) {
    if (-not $groups.Contains($n)) {
        throw "SharedPackages.ps1: no shared group named '$n'. Known groups: $($groups.Keys -join ', ')."
    }
    $groups[$n]
}