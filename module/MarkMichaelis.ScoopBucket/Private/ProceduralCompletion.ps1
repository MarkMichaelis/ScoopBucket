# Procedural completion repair (#397).
#
# Most CLIs get their completion registered declaratively: a [Package]
# declares CliCommands, and Invoke-PackageInstall registers right after the
# install. Update-PackageCompletion can therefore repair them by walking
# Get-BundlePackages.
#
# A handful are registered PROCEDURALLY instead -- a bare `winget install`
# line in an install script followed by Register-CliCompletion, deliberately
# co-located so adding or dropping the CLI touches one file. gh, gk, pwsh,
# powershell and wsl work this way.
#
# Those five were unreachable from any repair path: Get-BundlePackages does
# not see them, and re-running the owning script is not an option because
# those scripts also install software (GitConfigure.ps1 installs GitKraken).
# So once a profile was lost -- or migrated, as in #397 -- they stayed dead
# and the one command documented to fix that silently skipped them.
#
# CompletionCoverage.psd1 already enumerated them for coverage tests. It now
# also carries the recipe needed to re-register without the install script,
# and these helpers turn that data back into a registration.

function New-StaticCompleterCommand {
    <#
    .SYNOPSIS
        Build a scriptblock emitting a hand-curated
        `Register-ArgumentCompleter -Native` block for $Cli over $Switches.
    .DESCRIPTION
        For CLIs that ship no `<cli> completion powershell` subcommand at all
        (pwsh, powershell, wsl). Returned as a closure so the caller captures
        the rendered text verbatim, matching how the install scripts build it.
    #>
    [OutputType([scriptblock])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string[]]$Switches
    )

    $switchLiteral = ($Switches | ForEach-Object { "'$_'" }) -join ','
    $completerText = @"
Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @($switchLiteral) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
    return { $completerText }.GetNewClosure()
}

function Get-ProceduralCompletionDefinition {
    <#
    .SYNOPSIS
        Read CompletionCoverage.psd1 and return the 'Registered' entries with
        a ready-to-use NativeCommand scriptblock.
    .DESCRIPTION
        'ModuleActivated' entries (git, choco, scoop) are excluded: their
        completion comes from an upstream module activated by the install
        script, not from a sentinel block this module owns, so there is
        nothing here to repair.
    .PARAMETER BucketPath
        Directory holding CompletionCoverage.psd1.
    .OUTPUTS
        PSCustomObject with Cli, Script, NativeCommand (scriptblock).
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BucketPath)

    $catalogPath = Join-Path $BucketPath 'CompletionCoverage.psd1'
    if (-not (Test-Path $catalogPath)) {
        Write-Verbose "No completion coverage catalog at '$catalogPath'; procedural repair skipped."
        return
    }

    $catalog = Import-PowerShellDataFile -Path $catalogPath
    foreach ($entry in @($catalog.Clis)) {
        if ($entry.Status -ne 'Registered') { continue }

        $native = $null
        if ($entry.NativeCommand) {
            # Build a scriptblock that runs the catalogued command and
            # returns its text, matching what the install script passes.
            $cmd = [string]$entry.NativeCommand
            $native = [scriptblock]::Create("$cmd 2>`$null")
        } elseif ($entry.Switches) {
            $native = New-StaticCompleterCommand -Cli $entry.Cli -Switches @($entry.Switches)
        } else {
            Write-Warning "Completion catalog entry '$($entry.Cli)' is 'Registered' but carries neither NativeCommand nor Switches; cannot repair it."
            continue
        }

        [pscustomobject]@{
            Cli           = $entry.Cli
            Script        = $entry.Script
            NativeCommand = $native
        }
    }
}
