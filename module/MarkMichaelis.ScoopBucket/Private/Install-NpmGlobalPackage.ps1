# npmGlobal engine: installs a single package via `npm install --global`.
# Used for tools like @playwright/test, @anthropic-ai/claude-code, etc.
#
# Scope field is ignored — npm --global is by definition machine-wide
# (or user-wide depending on the npm prefix configuration).

function Install-NpmGlobalPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "npmGlobal: Id is empty for '$($Package.Name)'." }
    }

    if (-not (Get-Command npm -ErrorAction SilentlyContinue) -and
        -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        return @{ State = 'Failed'; Reason = "npm not on PATH. Install Node.js first (DependsOn='Node.js')." }
    }

    if (-not $WhatIf) {
        # `npm list -g --depth=0`, ignoring semver differences (npm itself
        # short-circuits a redundant install).
        $presence = Get-PackagePresence -Package $Package
        if ($presence.Present) { return @{ State = 'AlreadyInstalled'; Reason = $presence.Reason } }
    }

    $installArgs = @('install', '--global', $id)
    if ($WhatIf) {
        Write-Host "  [WhatIf] npm $($installArgs -join ' ')"
        return @{ State = 'Installed'; Reason = '(WhatIf)' }
    }

    Write-Host "  npm $($installArgs -join ' ')"
    & npm.cmd @installArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Installed'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "npm install --global $id exited with $exit." }
}
