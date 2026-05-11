[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # Overwrite existing per-CLI completion blocks. Default OFF (PowerShell
    # convention: explicit opt-in). Scoop bucket bundle scripts pass -Force
    # explicitly so an install refreshes completions to match.
    [switch]$Force,

    # Test/diagnostic hook: redirect profile writes to this file instead of
    # the AllUsersAllHosts profile. Bypasses the elevation check.
    [string]$ProfilePath,

    # Optional explicit list of CLIs to register. Defaults to every
    # CommandType=Application on PATH.
    [string[]]$Names
)

Write-Host 'Configuring PowerShell tab completion for installed CLI tools...'
. "$PSScriptRoot\Utils.ps1"

# Ensure the PSCompletions fallback module is present (AllUsers). Idempotent.
Install-PSCompletionsModule -Force:$Force -WhatIf:$WhatIfPreference

# Drive the scan. Register-AllCliCompletions handles enumeration when -Names
# is empty, and propagates -WhatIf / -Confirm via SupportsShouldProcess.
$splat = @{ Force = [bool]$Force }
if ($ProfilePath) { $splat['ProfilePath'] = $ProfilePath }
if ($Names)       { $splat['Names']       = $Names }

$results = Register-AllCliCompletions @splat -WhatIf:$WhatIfPreference

# Emit a markdown-friendly summary table on the host stream (CI step-summary
# can pick it up via redirection if desired).
if ($results) {
    $results |
        Sort-Object Source, Cli |
        Format-Table -AutoSize Cli, Source, Action, Reason |
        Out-String |
        Write-Host
}
