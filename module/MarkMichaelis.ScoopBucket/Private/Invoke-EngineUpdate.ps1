# Engine dispatch for "upgrade this one package".
#
# Extracted so the two callers stay in lockstep:
#   - Invoke-PackageUpdate : the normal `Update-Package` pipeline.
#   - Invoke-PackageInstall: the install-or-upgrade path, which routes an
#                            AlreadyInstalled engine result here so that
#                            "install" means "ensure latest", not merely
#                            "ensure present" (see #401).
#
# Installer='custom' has no generic engine upgrade path (its update story is
# PostUpdateScript / UpdateMode), so it is rejected here rather than silently
# treated as a no-op.

function Invoke-EngineUpdate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf,
        [int]$TimeoutMinutes = 5
    )

    switch ($Package.Installer) {
        'winget'     { return Update-WingetPackage     -Package $Package -WhatIf:$WhatIf -TimeoutMinutes $TimeoutMinutes }
        'scoop'      { return Update-ScoopPackage      -Package $Package -WhatIf:$WhatIf }
        'choco'      { return Update-ChocoPackage      -Package $Package -WhatIf:$WhatIf }
        'npmGlobal'  { return Update-NpmGlobalPackage  -Package $Package -WhatIf:$WhatIf }
        'dotnetTool' { return Update-DotnetToolPackage -Package $Package -WhatIf:$WhatIf }
        default      { throw "Invoke-EngineUpdate: unknown Installer '$($Package.Installer)' for '$($Package.Name)'." }
    }
}
