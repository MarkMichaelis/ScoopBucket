# dotnetTool engine: installs a single .NET global tool via
# `dotnet tool install -g <id>`. Used for poshmcp, aspire, etc.

function Install-DotnetToolPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "dotnetTool: Id is empty for '$($Package.Name)'." }
    }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        return @{ State = 'Failed'; Reason = "dotnet not on PATH. Install the .NET SDK first (DependsOn='dotnet')." }
    }

    if (-not $WhatIf) {
        $presence = Get-PackagePresence -Package $Package
        if ($presence.Present) { return @{ State = 'AlreadyInstalled'; Reason = $presence.Reason } }
    }

    $installArgs = @('tool', 'install', '-g', $id)
    if ($WhatIf) {
        Write-Host "  [WhatIf] dotnet $($installArgs -join ' ')"
        return @{ State = 'Installed'; Reason = '(WhatIf)' }
    }

    Write-Host "  dotnet $($installArgs -join ' ')"
    $out = & dotnet @installArgs 2>&1
    $exit = $LASTEXITCODE
    $joined = ($out -join "`n")
    if ($exit -eq 0) {
        return @{ State = 'Installed'; Reason = $null }
    }
    # dotnet returns 1 on "already installed" — read the output to
    # distinguish a benign "already installed" from a real failure.
    if ($joined -match 'already installed') {
        return @{ State = 'AlreadyInstalled'; Reason = 'dotnet tool reported already installed.' }
    }
    return @{ State = 'Failed'; Reason = "dotnet tool install -g $id exited with $exit. Output: $($joined.Trim())" }
}
