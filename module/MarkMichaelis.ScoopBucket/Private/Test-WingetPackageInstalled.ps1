# Winget engine: shared "is this package installed?" probe for the install,
# update and uninstall paths.
#
# winget does not find Microsoft Store ids with `winget list --id <Id>`; only
# `--exact` finds them (#516, seen with winget v1.29). `--exact` is also
# case-sensitive, so `winget list --id git.git --exact` misses Git.Git. The
# probe therefore tries the exact match first and falls back to the plain
# match, so a Store id is found and a differently-cased id still is.
#
# Returns @{ Installed = <bool>; ExitCode = <int>; Command = <string> }, where
# ExitCode and Command describe the last list call made.

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
    foreach ($attemptArgs in @(, ($listArgs + '--exact')) + @(, $listArgs)) {
        $command = "winget $($attemptArgs -join ' ')"
        $null = & winget @attemptArgs 2>$null
        $exit = $LASTEXITCODE
        if ($exit -eq 0) {
            return @{ Installed = $true; ExitCode = $exit; Command = $command }
        }
    }
    return @{ Installed = $false; ExitCode = $exit; Command = $command }
}
