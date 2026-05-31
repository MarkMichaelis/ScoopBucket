# dotnetTool engine: updates a .NET global tool via `dotnet tool update -g <id>`.

function Update-DotnetToolPackage {
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
            Write-Verbose "Update-DotnetToolPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $updateArgs = @('tool', 'update', '-g', $id)

    if ($WhatIf) {
        Write-Host "  [WhatIf] dotnet $($updateArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)' }
    }

    Write-Host "  dotnet $($updateArgs -join ' ')"
    $out = & dotnet @updateArgs 2>&1
    $exit = $LASTEXITCODE
    $joined = ($out -join "`n")
    if ($exit -eq 0) {
        # `dotnet tool update` returns 0 + a message like
        # "Tool 'xyz' was reinstalled with the latest stable version
        # (X.Y.Z), which was already installed." when no newer version
        # exists. Surface as AlreadyLatest when we see that signature.
        if ($joined -match '(?im)was already installed|is up to date') {
            return @{ State = 'AlreadyLatest'; Reason = 'dotnet tool reported already at latest version.' }
        }
        return @{ State = 'Updated'; Reason = $null }
    }
    if ($joined -match '(?im)is not installed|could not be found') {
        return @{ State = 'NotInstalled'; Reason = 'dotnet tool reported not installed.' }
    }
    return @{ State = 'Failed'; Reason = "dotnet tool update -g $id exited with $exit. Output: $($joined.Trim())" }
}
