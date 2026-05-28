function Resolve-PackageOrder {
    <#
    .SYNOPSIS
        Topologically sort packages by DependsOn and apply -Name / -Skip filters.

    .DESCRIPTION
        Internal helper for Invoke-PackageInstall. Validates that all
        DependsOn names resolve, applies the transitive closure when
        -Name is set, drops entries listed in -Skip, then returns the
        packages in dependency-respecting order. Deterministic tie-break
        by original array index.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        # Use [object[]] (not [Package[]]) so callers from a different
        # scope chain don't trip the dual-class-identity issue: the
        # [Package] class is loaded both by ScriptsToProcess (caller
        # scope) and the psm1 (module scope), and a [Package] from one
        # scope is not assignment-compatible with [Package] in the
        # other. Invoke-PackageInstall already validates each element
        # has GetType().Name -eq 'Package' before reaching us.
        [Parameter(Mandatory)][object[]] $Packages,
        [string[]] $Name,
        [string[]] $Skip
    )

    $byName = @{}
    $index = @{}
    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $p = $Packages[$i]
        if ($byName.ContainsKey($p.Name)) {
            throw "Resolve-PackageOrder: duplicate Package Name '$($p.Name)'."
        }
        $byName[$p.Name] = $p
        $index[$p.Name] = $i
    }

    foreach ($p in $Packages) {
        foreach ($dep in $p.DependsOn) {
            if (-not $byName.ContainsKey($dep)) {
                throw "Resolve-PackageOrder: Package '$($p.Name)' DependsOn '$dep' which is not defined in this bundle."
            }
        }
        foreach ($comp in $p.Companions) {
            if (-not $byName.ContainsKey($comp)) {
                throw "Resolve-PackageOrder: Package '$($p.Name)' Companions '$comp' which is not defined in this bundle."
            }
        }
    }

    # Build an effective-DependsOn map combining declared DependsOn with
    # implicit ordering edges from Companions (companion DependsOn owner).
    # These edges live ONLY in the resolver's working graph; the [Package]
    # instances themselves are never mutated.
    $effectiveDeps = @{}
    foreach ($p in $Packages) {
        $set = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($p.DependsOn),
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $effectiveDeps[$p.Name] = $set
    }
    foreach ($p in $Packages) {
        foreach ($comp in $p.Companions) {
            # Companion gets an implicit DependsOn -> owner so Kahn
            # schedules the owner first and the companion after.
            [void]$effectiveDeps[$comp].Add($p.Name)
        }
    }

    # Selective install: compute transitive closure of -Name across BOTH
    # DependsOn (needed prerequisites) and Companions (always-with).
    if ($Name) {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($n in $Name) {
            if (-not $byName.ContainsKey($n)) {
                throw "Resolve-PackageOrder: -Name '$n' does not match any Package in this bundle."
            }
            [void]$queue.Enqueue($n)
        }
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if (-not $wanted.Add($cur)) { continue }
            foreach ($dep in $byName[$cur].DependsOn) {
                [void]$queue.Enqueue($dep)
            }
            foreach ($comp in $byName[$cur].Companions) {
                [void]$queue.Enqueue($comp)
            }
        }
        $filtered = @($Packages | Where-Object { $wanted.Contains($_.Name) })
    }
    else {
        $filtered = @($Packages)
    }

    if ($Skip) {
        $skipSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$Skip,
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $filtered = @($filtered | Where-Object { -not $skipSet.Contains($_.Name) })
    }

    # Kahn's algorithm with deterministic tie-break by original index.
    # Uses $effectiveDeps so Companions ordering edges participate.
    $remaining = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($filtered | ForEach-Object { $_.Name }),
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $result = [System.Collections.Generic.List[object]]::new()

    while ($remaining.Count -gt 0) {
        $ready = @($filtered |
            Where-Object {
                $name = $_.Name
                $remaining.Contains($name) -and
                -not ($effectiveDeps[$name] | Where-Object { $remaining.Contains($_) })
            } |
            Sort-Object { $index[$_.Name] })

        if (-not $ready) {
            $stuck = $remaining -join ', '
            throw "Resolve-PackageOrder: dependency cycle or unresolved dependency in: $stuck"
        }

        foreach ($p in $ready) {
            [void]$result.Add($p)
            [void]$remaining.Remove($p.Name)
        }
    }

    return ,$result.ToArray()
}
