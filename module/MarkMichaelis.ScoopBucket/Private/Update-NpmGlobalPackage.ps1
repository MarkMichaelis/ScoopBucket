# npmGlobal engine: updates a single package via `npm install -g <pkg>@latest`.
#
# We prefer `npm install -g <pkg>@latest` over `npm update -g <pkg>` because
# `npm update` respects the semver range cached in the global package's
# package.json (which for a fresh -g install pins to ~current), so a pure
# `npm update -g` is a frequent no-op on majors. Pinning to @latest is what
# users actually mean by "update this global tool".

function Update-NpmGlobalPackage {
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

    # Invocation hard-codes `npm.cmd` (not bare `npm`) to dodge the
    # `npm.ps1` arg-mangling bug fixed in #249, so the presence probe
    # checks for `npm.cmd` specifically — keeping probe and invocation
    # aligned. Node.js installs ship both `npm.cmd` and `npm.ps1`
    # together, so this is not a portability regression.
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        return @{ State = 'Failed'; Reason = "npm.cmd not on PATH. Install Node.js first (DependsOn='Node.js')." }
    }

    if (-not $WhatIf) {
        try {
            $listOut = & npm.cmd list -g --depth=0 2>$null | Out-String
            if ($listOut -notmatch "(?im)^\S+\s+$([regex]::Escape($id))@") {
                return @{ State = 'NotInstalled'; Reason = "npm list -g does not list $id." }
            }
        } catch {
            Write-Verbose "Update-NpmGlobalPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $installArgs = @('install', '--global', "$id@latest")

    if ($WhatIf) {
        Write-Host "  [WhatIf] npm $($installArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)' }
    }

    Write-Host "  npm $($installArgs -join ' ')"
    & npm.cmd @installArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "npm install --global $id@latest exited with $exit." }
}
