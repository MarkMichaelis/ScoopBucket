# Winget engine: shared "is this package installed?" probe for the install,
# update and uninstall paths.
#
# winget does not find Microsoft Store ids with `winget list --id <Id>`; only
# `--exact` finds them (#516, seen with winget v1.29). `--exact` is also
# case-sensitive, so `winget list --id git.git --exact` misses Git.Git. The
# probe therefore tries the exact match first and falls back to the plain
# match, so a Store id is found and a differently-cased id still is.
#
# The plain match is a substring match over every identity winget knows,
# including a Store app's package family: with the ChatGPT Store app (family
# OpenAI.Codex_2p2nqsd0c76g0) installed, `winget list --id OpenAI.Codex` exits
# 0 and lists ChatGPT (#553). So a plain-match hit counts only when a listed
# row's Id is the declared Id, ignoring case.
#
# Returns @{ Installed = <bool>; Id = <string>; ExitCode = <int>;
# Command = <string>; Reason = <string> }. Id is the installed package's id as
# winget lists it, so callers can target it with --exact (empty when not
# installed). ExitCode and Command describe the last list call made; Reason
# says in one sentence what that call showed.

function Test-WingetPackageInstalled {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package
    )

    $listArgs = @('list', '--id', $Package.Id, '--accept-source-agreements')
    if ($Package.Source -eq 'msstore') {
        $listArgs += @('--source', 'msstore')
    }

    $exit = $null
    $command = $null
    $reason = $null
    foreach ($exact in $true, $false) {
        $attemptArgs = if ($exact) { $listArgs + '--exact' } else { $listArgs }
        $command = "winget $($attemptArgs -join ' ')"
        $output = @(& winget @attemptArgs 2>$null | ForEach-Object { [string]$_ })
        $exit = $LASTEXITCODE
        $reason = "$command returned $exit."
        if ($exit -ne 0) { continue }
        if ($exact) {
            return @{ Installed = $true; Id = [string]$Package.Id; ExitCode = $exit; Command = $command; Reason = $reason }
        }

        $listed = ConvertFrom-WingetVersionTable $output
        if ($listed.Count -eq 0) {
            # No table to check (an output layout the parser does not know):
            # trust the exit code, as this probe did before #553. Callers name
            # the declared id with --exact, so they still cannot act on a
            # different package.
            return @{ Installed = $true; Id = [string]$Package.Id; ExitCode = $exit; Command = $command; Reason = $reason }
        }
        $row = $listed[([string]$Package.Id).ToLowerInvariant()]
        if ($row) {
            return @{ Installed = $true; Id = $row.Id; ExitCode = $exit; Command = $command; Reason = $reason }
        }
        $others = @($listed.Values | ForEach-Object { $_.Id } | Sort-Object)
        $reason = "$command listed only $($others -join ', '), not $($Package.Id)."
    }
    return @{ Installed = $false; Id = ''; ExitCode = $exit; Command = $command; Reason = $reason }
}
