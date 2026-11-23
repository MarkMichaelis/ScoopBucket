# What `Install-Package -Name '*'` installs (#454).
#
# '*' converges a machine: every default package of every declarative bundle is
# installed or upgraded, and an optional package (Default = $false) is upgraded
# only when it is already installed -- '*' never adds optional software the
# owner did not ask for, but it keeps what they did ask for current.
#
# Refinements that keep that rule honest:
#   - A package that only links to another declarative bundle of this bucket
#     (Installer 'scoop', Id 'MarkMichaelis/<bundle>') is not requested: '*'
#     processes that bundle directly, and installing the link would run the
#     whole bundle and ignore its packages' defaults. A link that a requested
#     package depends on is still installed, through the normal closure.
#   - One package declared by several bundles (same Installer and Id) is
#     installed once, and it is a default if ANY declaration says so.
#   - Packages already covered by an explicit request -- a named package, or a
#     bundle named in full -- are not requested again.
#   - An optional package that a requested package needs (DependsOn or
#     Companions) is installed with it, not reported as skipped.
#   - A bundle that cannot be planned (e.g. a DependsOn naming a package it
#     does not declare) yields a Failed row; the other bundles still converge
#     (the #272 / #451 resilience contract).
#
# Config-only bare manifests are never part of the set: only declarative
# bundles are walked.

function Resolve-DefaultInstallSet {
    <#
    .SYNOPSIS
        Work out the package names '*' requests per bundle, plus a Skipped
        result for each optional package it leaves out and a Failed result
        for each bundle it cannot plan.

    .PARAMETER Bundle
        Every declarative bundle (Bundle, BundlePath), as Get-BundlePackages
        returns them. All of them are used to recognise links and duplicates.

    .PARAMETER Requested
        BundlePath -> names already requested explicitly. Those packages are
        installed regardless of Default and are not requested twice.

    .PARAMETER FullBundlePath
        Bundles named explicitly, which install in full. '*' plans nothing in
        them, and their packages count as already covered.

    .OUTPUTS
        Hashtable @{ Names = @{ BundlePath -> string[] }; Skipped = PackageResult[];
        Failed = PackageResult[] }. Each Failed result carries its ErrorRecord
        in .Error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object[]]$Bundle,
        [hashtable]$Requested = @{},
        [string[]]$FullBundlePath = @()
    )

    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase
    $bundleNames = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($Bundle | ForEach-Object { $_.Bundle }), $ignoreCase)
    $skipped = New-Object System.Collections.Generic.List[object]
    $failed  = New-Object System.Collections.Generic.List[object]

    # The bucket's own scoop name, as Install-ScoopPackage routes it. A link's
    # Id must carry it: 'extras/<x>' is a real package even when a bundle of
    # this bucket happens to be called <x>.
    $isLink = {
        param($p)
        $p.Installer -eq 'scoop' -and $p.Id -match '^MarkMichaelis/(?<target>[^/]+)$' -and
            $bundleNames.Contains($Matches['target'])
    }
    $identityOf = {
        param($p, $bundleName)
        if ($p.Id) { "$($p.Installer)|$($p.Id)" } else { "$bundleName|$($p.Name)" }
    }
    $fail = {
        param($b, $message)
        $failed.Add((New-BundleDispatchFailure -Bundle $b.Bundle -Message "'*' could not plan this bundle: $message"))
    }

    # --- Load every bundle; note what explicit requests already cover. -----
    $loaded  = New-Object System.Collections.Generic.List[object]
    $claimed = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    foreach ($b in @($Bundle | Sort-Object Bundle)) {
        try {
            $packages = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)
        } catch {
            & $fail $b $_.Exception.Message
            continue
        }
        $full = $b.BundlePath -in $FullBundlePath
        $explicit = @(if ($Requested.ContainsKey($b.BundlePath)) { $Requested[$b.BundlePath] })
        foreach ($p in $packages) {
            if ($full -or $explicit -contains $p.Name) { [void]$claimed.Add((& $identityOf $p $b.Bundle)) }
        }
        if (-not $full) {
            $loaded.Add([pscustomobject]@{ Info = $b; Packages = $packages; Explicit = $explicit })
        }
    }

    # --- Pass 1: defaults. A package is a default if any declaration says so.
    $defaultIds = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    foreach ($entry in $loaded) {
        foreach ($p in $entry.Packages) {
            if ($p.Default -and -not (& $isLink $p)) { [void]$defaultIds.Add((& $identityOf $p $entry.Info.Bundle)) }
        }
    }

    $wanted  = @{}
    $decided = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    foreach ($id in $claimed) { [void]$decided.Add($id) }
    foreach ($entry in $loaded) {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($p in $entry.Packages) {
            if ($entry.Explicit -contains $p.Name -or (& $isLink $p)) { continue }
            $id = & $identityOf $p $entry.Info.Bundle
            if ($defaultIds.Contains($id) -and $decided.Add($id)) { $names.Add($p.Name) }
        }
        $wanted[$entry.Info.BundlePath] = $names
    }

    # --- Pass 2: what the requested packages pull in comes along. ----------
    $covered = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    # Iterate a snapshot: a bundle that cannot be planned is removed below.
    foreach ($entry in $loaded.ToArray()) {
        $seed = @($wanted[$entry.Info.BundlePath]) + @($entry.Explicit)
        if ($seed.Count -eq 0) { continue }
        try {
            # Resolve-PackageOrder emits its list as ONE array object; assign it
            # before iterating, as Invoke-PackageInstall does.
            $closure = Resolve-PackageOrder -Packages $entry.Packages -Name $seed
        } catch {
            & $fail $entry.Info $_.Exception.Message
            [void]$loaded.Remove($entry)
            continue
        }
        foreach ($p in $closure) { [void]$covered.Add((& $identityOf $p $entry.Info.Bundle)) }
    }

    # --- Pass 3: optional packages are upgraded only where installed. ------
    foreach ($entry in $loaded) {
        foreach ($p in $entry.Packages) {
            if ($entry.Explicit -contains $p.Name -or (& $isLink $p)) { continue }
            $id = & $identityOf $p $entry.Info.Bundle
            if ($covered.Contains($id) -or -not $decided.Add($id)) { continue }

            $presence = Get-PackagePresence -Package $p
            if ($presence.Present -eq $true) {
                $wanted[$entry.Info.BundlePath].Add($p.Name)
                continue
            }
            $howTo = "Install it by name: Install-Package -Name '$($p.Name)'"
            $reason = if ($null -eq $presence.Present) {
                "Optional (Default = `$false), and Install-Package could not tell whether it is installed ($($presence.Reason)), so '*' leaves it out. $howTo"
            } else {
                "Optional (Default = `$false) and not installed, so '*' leaves it out. $howTo"
            }
            $skipped.Add([PackageResult]@{
                Operation = 'Install'
                Status    = 'Skipped'
                Name      = $p.Name
                Installer = $p.Installer
                Scope     = $p.Scope
                Id        = $p.Id
                Bundle    = $entry.Info.Bundle
                Reason    = $reason
            })
        }
    }

    $names = @{}
    foreach ($entry in $loaded) {
        $list = $wanted[$entry.Info.BundlePath]
        if ($list.Count -gt 0) { $names[$entry.Info.BundlePath] = $list.ToArray() }
    }
    @{ Names = $names; Skipped = $skipped.ToArray(); Failed = $failed.ToArray() }
}
