# dotnetTool engine: uninstalls a .NET global tool via
# `dotnet tool uninstall --global <id>`.

function Uninstall-DotnetToolPackage {
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
        return @{ State = 'Failed'; Reason = "dotnet not on PATH." }
    }

    if (-not $WhatIf) {
        try {
            $listOut = & dotnet tool list -g 2>$null | Out-String
            if ($listOut -notmatch "(?im)^\s*$([regex]::Escape($id))\s+\S+") {
                return @{ State = 'NotInstalled'; Reason = "dotnet tool list -g does not list $id." }
            }
        } catch {
            Write-Verbose "Uninstall-DotnetToolPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $uninstallArgs = @('tool', 'uninstall', '--global', $id)

    if ($WhatIf) {
        Write-Host "  [WhatIf] dotnet $($uninstallArgs -join ' ')"
        return @{ State = 'Uninstalled'; Reason = '(WhatIf)' }
    }

    Write-Host "  dotnet $($uninstallArgs -join ' ')"
    $out = & dotnet @uninstallArgs 2>&1
    $exit = $LASTEXITCODE
    $joined = ($out -join "`n")
    if ($exit -eq 0) {
        return @{ State = 'Uninstalled'; Reason = $null }
    }
    if ($joined -match 'is not installed') {
        return @{ State = 'NotInstalled'; Reason = 'dotnet tool reported not installed.' }
    }
    return @{ State = 'Failed'; Reason = "dotnet tool uninstall --global $id exited with $exit. Output: $($joined.Trim())" }
}
