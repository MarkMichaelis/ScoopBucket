# The tree the package picker shows (#543), built from the bucket every time.
#
# Nothing here is a maintained list. The tree is derived from what the bucket
# holds right now, so a package or manifest added or removed appears or
# disappears on its own:
#
#   - Top level: the declarative bundles whose script sits at the bucket root
#     (OSBasePackages, ClientBasePackages, ...). A top-level bundle is never
#     also nested under another one, so a group only ever affects its own
#     children -- even where one bundle pulls another in (ClientBasePackages
#     links AIAgents).
#   - Nested: a bundle that is not top-level and that another bundle pulls in,
#     either through a package that links to it (Installer 'scoop', Id
#     'MarkMichaelis/<bundle>') or through the parent manifest's `depends`.
#   - Also available: declarative bundles and bare manifests that no bundle
#     uses go under the top-level group their folder is named after (ai ->
#     AIAgents, client -> ClientBasePackages, ...), in a group of their own.
#     A folder no top-level bundle's name starts with becomes a top-level
#     group itself (admin).
#
# A package whose Id names a bare manifest of this bucket ('MarkMichaelis/Tool')
# is an ordinary package: that manifest is how it installs, so the manifest is
# not listed again as an extra.

function ConvertTo-PickerDisplayName {
    # 'OSBasePackages' -> 'OS Base Packages', 'MicrosoftOffice365' -> 'Microsoft
    # Office 365'. A word starts at a capital followed by a lower-case letter
    # (or ending the name), so an acronym such as 'ChatGPT' stays whole.
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $Name -creplace '([a-z])(?=[A-Z](?:[a-z]|$))', '$1 ' -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2' -creplace '([A-Za-z])(\d)', '$1 $2'
}

function Get-PickerIdentity {
    # One identity per installable thing, shared by every declaration of it:
    # the same Installer and Id in two bundles is one package to the picker.
    # The same key Install-Package -Name '*' de-duplicates on
    # (Resolve-DefaultInstallSet), so the two agree on what a twin is.
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Package, [Parameter(Mandatory)][string]$Bundle)
    if ($Package.Id) { "$($Package.Installer)|$($Package.Id)" } else { "$Bundle|$($Package.Name)" }
}

function Get-PickerLinkTarget {
    # The bundle or manifest of THIS bucket a scoop package installs, or $null.
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Package)
    if ($Package.Installer -eq 'scoop' -and [string]$Package.Id -match '^MarkMichaelis/(?<target>[^/]+)$') { return $Matches['target'] }
    $null
}

function Get-PackageCatalog {
    <#
    .SYNOPSIS
        Build the picker's tree from the bucket.

    .PARAMETER BucketPath
        The bucket directory.

    .PARAMETER Bundle
        Get-BundlePackages output, when the caller already has it (it takes
        seconds to produce). Loaded here otherwise.

    .OUTPUTS
        PSCustomObject: Roots (group nodes), Bundles (bundle name -> Bundle,
        BundlePath, Packages), Order (bundle names, name order).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BucketPath,
        [object[]]$Bundle
    )

    $bucketFull = (Resolve-Path -LiteralPath $BucketPath).ProviderPath.TrimEnd('\')
    # Get-BundlePackages emits its list as ONE array object: assign it (which
    # unwraps it) rather than piping it, as Install-Package does.
    if (-not $Bundle) { $Bundle = Get-BundlePackages -BucketPath $bucketFull }
    $declarative = foreach ($candidate in $Bundle) { if (@($candidate.Packages).Count -gt 0) { $candidate } }
    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase
    $folderOf = {
        param([string]$Path)
        $dir = (Split-Path -Parent $Path).TrimEnd('\')
        if ($dir -ieq $bucketFull) { '' } else { $dir.Substring($bucketFull.Length).TrimStart('\') }
    }

    # Every manifest, with the folder it lives in and what it depends on.
    $manifests = [System.Collections.Generic.Dictionary[string, object]]::new($ignoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $bucketFull -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue) {
        $depends = @()
        try { $depends = @((Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json).depends | Where-Object { $_ }) } catch { }
        $manifests[$file.BaseName] = [pscustomobject]@{
            Name = $file.BaseName; Path = $file.FullName; Folder = & $folderOf $file.FullName; Depends = $depends
        }
    }

    # Every declarative bundle, loaded once.
    $bundles = [System.Collections.Generic.Dictionary[string, object]]::new($ignoreCase)
    foreach ($b in @($declarative | Sort-Object Bundle)) {
        $packages = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)
        $folder = & $folderOf $b.BundlePath
        $bundles[$b.Bundle] = [pscustomobject]@{
            Bundle     = $b.Bundle
            BundlePath = $b.BundlePath
            Packages   = $packages
            Folder     = $folder
            IsRoot     = $folder -eq ''
            Depends    = @(if ($manifests.ContainsKey($b.Bundle)) { $manifests[$b.Bundle].Depends })
        }
    }

    # What the bundles use: linked or depended-on bundles, and bare manifests
    # that packages install through.
    $usedBundles   = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    $usedManifests = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    foreach ($b in $bundles.Values) {
        $targets = @($b.Packages | ForEach-Object { Get-PickerLinkTarget -Package $_ } | Where-Object { $_ }) + @($b.Depends)
        foreach ($t in $targets) {
            if ($bundles.ContainsKey($t)) { [void]$usedBundles.Add($t) } else { [void]$usedManifests.Add($t) }
        }
    }

    # A manifest that a package installs is that package wherever it shows up,
    # so checking it in one place cannot install it twice.
    $manifestPackage = [System.Collections.Generic.Dictionary[string, string]]::new($ignoreCase)
    foreach ($b in $bundles.Values) {
        foreach ($p in $b.Packages) {
            $t = Get-PickerLinkTarget -Package $p
            if ($t -and -not $bundles.ContainsKey($t) -and -not $manifestPackage.ContainsKey($t)) {
                $manifestPackage[$t] = Get-PickerIdentity -Package $p -Bundle $b.Bundle
            }
        }
    }

    # Sub-items (#559). A package's Companions and DependsOn are shown under
    # it. A companion is only ever shown there. A dependency stays an item of
    # its group too, unless another bundle lists the same package as an item
    # of its own -- Node.js is AIAgents' dependency but DeveloperBasePackages'
    # item. Every choco package needs Chocolatey, shown as its dependency.
    # One key per thing a package installs: a link to another bundle is keyed
    # by that bundle (two bundles linking it list the same thing).
    function Get-SubItemKey([object]$Package, [string]$Bundle) {
        $target = Get-PickerLinkTarget -Package $Package
        if ($target -and $bundles.ContainsKey($target)) { "bundle|$target" } else { Get-PickerIdentity -Package $Package -Bundle $Bundle }
    }
    $subNames = @{}      # bundle -> names shown only as sub-items
    $ownedBy = @{}       # identity -> bundles that list it as an item of their own
    foreach ($b in $bundles.Values) {
        $companions = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        $dependencies = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        foreach ($p in $b.Packages) {
            foreach ($c in @($p.Companions)) { if ($c) { [void]$companions.Add($c) } }
            foreach ($d in @($p.DependsOn)) { if ($d) { [void]$dependencies.Add($d) } }
        }
        $subNames[$b.Bundle] = [pscustomobject]@{ Companions = $companions; Dependencies = $dependencies }
        foreach ($p in $b.Packages) {
            if ($companions.Contains($p.Name) -or $dependencies.Contains($p.Name)) { continue }
            $id = Get-SubItemKey $p $b.Bundle
            if (-not $ownedBy.ContainsKey($id)) { $ownedBy[$id] = [System.Collections.Generic.List[string]]::new() }
            $ownedBy[$id].Add($b.Bundle)
        }
    }
    $chocoManifest = if ($manifests.ContainsKey('Chocolatey')) { $manifests['Chocolatey'] } else { $null }
    if ($chocoManifest -and @($bundles.Values | ForEach-Object { $_.Packages } | Where-Object { $_.Installer -eq 'choco' }).Count -gt 0) {
        [void]$usedManifests.Add('Chocolatey')
    }

    $groups = [System.Collections.Generic.Dictionary[string, object]]::new($ignoreCase)
    $building = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    function New-PackageNode([object]$Package, [string]$Bundle, [string]$Role, [string[]]$Path) {
        $info = $bundles[$Bundle]
        $node = [pscustomobject]@{
            Kind = 'Package'; Name = $Package.Name; Key = "pkg:$Bundle/$($Package.Name)"
            Bundle = $Bundle; BundlePath = $info.BundlePath
            Identity = Get-PickerIdentity -Package $Package -Bundle $Bundle
            Default = [bool]$Package.Default; Package = $Package; Role = $Role
            Children = [System.Collections.Generic.List[object]]::new()
        }
        $here = @($Path) + $Package.Name
        $byName = { param($n) $info.Packages | Where-Object { $_.Name -eq $n } | Select-Object -First 1 }
        foreach ($pair in @(@(@($Package.Companions), 'Companion'), @(@($Package.DependsOn), 'Dependency'))) {
            foreach ($n in $pair[0]) {
                $sub = if ($n -and $here -notcontains $n) { & $byName $n }
                if (-not $sub) { continue }
                $target = Get-PickerLinkTarget -Package $sub
                if ($target -and $bundles.ContainsKey($target)) {
                    # A sub-item that is another bundle: shown as that bundle
                    # (a copy, so the role is not written onto the shared node).
                    $linked = (Get-NestedNode $target).PSObject.Copy()
                    $linked | Add-Member -NotePropertyName Role -NotePropertyValue $pair[1] -Force
                    $node.Children.Add($linked)
                } else {
                    $node.Children.Add((New-PackageNode $sub $Bundle $pair[1] $here))
                }
            }
        }
        if ($Package.Installer -eq 'choco' -and $chocoManifest) {
            $choco = New-ManifestNode $chocoManifest
            $choco | Add-Member -NotePropertyName Role -NotePropertyValue 'Dependency'
            $node.Children.Add($choco)
        }
        $node
    }
    function New-ManifestNode([object]$Manifest) {
        $identity = if ($manifestPackage.ContainsKey($Manifest.Name)) { $manifestPackage[$Manifest.Name] } else { "manifest|$($Manifest.Name)" }
        [pscustomobject]@{
            Kind = 'Manifest'; Name = $Manifest.Name; Key = "manifest:$($Manifest.Name)"
            Identity = $identity; Default = $false; Folder = $Manifest.Folder
        }
    }
    function Get-BundleNode([string]$Name) {
        if ($groups.ContainsKey($Name)) { return $groups[$Name] }
        $info = $bundles[$Name]
        $node = [pscustomobject]@{
            Kind = 'Group'; Name = ConvertTo-PickerDisplayName $Name; Key = "bundle:$Name"
            Bundle = $Name; Children = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$Name] = $node   # before the children, so a link cycle terminates
        [void]$building.Add($Name)
        foreach ($p in $info.Packages) {
            $target = Get-PickerLinkTarget -Package $p
            if ($target -and $bundles.ContainsKey($target)) {
                $sub = $subNames[$Name]
                if ($sub.Companions.Contains($p.Name)) { continue }
                if ($sub.Dependencies.Contains($p.Name) -and $ownedBy.ContainsKey("bundle|$target") -and @($ownedBy["bundle|$target"] | Where-Object { $_ -ne $Name }).Count -gt 0) { continue }
                # A top-level bundle is shown once, at the top.
                if (-not $bundles[$target].IsRoot) { $node.Children.Add((Get-NestedNode $target)) }
                continue
            }
            # A companion is shown only under its package; a dependency only
            # there too when another bundle lists it as an item of its own.
            $sub = $subNames[$Name]
            if ($sub.Companions.Contains($p.Name)) { continue }
            if ($sub.Dependencies.Contains($p.Name)) {
                $id = Get-SubItemKey $p $Name
                if ($ownedBy.ContainsKey($id) -and @($ownedBy[$id] | Where-Object { $_ -ne $Name }).Count -gt 0) { continue }
            }
            $node.Children.Add((New-PackageNode $p $Name $null @()))
        }
        foreach ($d in $info.Depends) {
            if ($bundles.ContainsKey($d)) { if (-not $bundles[$d].IsRoot) { $node.Children.Add((Get-NestedNode $d)) } }
            elseif ($manifests.ContainsKey($d)) { $node.Children.Add((New-ManifestNode $manifests[$d])) }
        }
        [void]$building.Remove($Name)
        $node
    }
    # A bundle shown inside another place: a one-package bundle is shown as
    # that package rather than as a group of one. A bundle still being built
    # (a link cycle) is not complete yet, so it stays a group.
    function Get-NestedNode([string]$Name) {
        $group = Get-BundleNode $Name
        if (-not $building.Contains($Name) -and $group.Children.Count -eq 1 -and $group.Children[0].Kind -ne 'Group') {
            return $group.Children[0]
        }
        $group
    }

    $roots = [System.Collections.Generic.List[object]]::new()
    foreach ($b in @($bundles.Values | Where-Object IsRoot)) { $roots.Add((Get-BundleNode $b.Bundle)) }

    $byFolder = [System.Collections.Generic.SortedDictionary[string, object]]::new($ignoreCase)
    $addStandalone = {
        param([string]$Folder, $Node)
        $key = if ($Folder) { $Folder } else { '(bucket root)' }
        if (-not $byFolder.ContainsKey($key)) { $byFolder[$key] = [System.Collections.Generic.List[object]]::new() }
        $byFolder[$key].Add($Node)
    }
    foreach ($b in $bundles.Values) {
        if (-not $b.IsRoot -and -not $usedBundles.Contains($b.Bundle)) { & $addStandalone $b.Folder (Get-NestedNode $b.Bundle) }
    }
    foreach ($m in $manifests.Values) {
        if (-not $bundles.ContainsKey($m.Name) -and -not $usedManifests.Contains($m.Name)) { & $addStandalone $m.Folder (New-ManifestNode $m) }
    }
    # Each folder's unused items join the top-level group named like the
    # folder; a folder no top-level bundle matches becomes a group itself.
    $rootInfo = @($bundles.Values | Where-Object IsRoot)
    $ownGroups = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $byFolder.GetEnumerator()) {
        $items = @($entry.Value | Sort-Object Name)
        $first = ($entry.Key -split '\\')[0]
        # A plain, case-insensitive prefix: a folder name is never a wildcard.
        $match = @($rootInfo | Where-Object { $first -and $_.Bundle.StartsWith($first, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($match.Count -eq 1) {
            $extra = [pscustomobject]@{
                Kind = 'Group'; Name = 'Also available'; Key = "extras:$($match[0].Bundle)"; Bundle = $null
                Children = [System.Collections.Generic.List[object]]::new()
            }
            foreach ($n in $items) { $extra.Children.Add($n) }
            $groups[$match[0].Bundle].Children.Add($extra)
        } else {
            $own = [pscustomobject]@{
                Kind = 'Group'; Name = (Get-Culture).TextInfo.ToTitleCase($entry.Key); Key = "folder:$($entry.Key)"; Bundle = $null
                Children = [System.Collections.Generic.List[object]]::new()
            }
            foreach ($n in $items) { $own.Children.Add($n) }
            $ownGroups.Add($own)
        }
    }
    foreach ($g in @($ownGroups | Sort-Object Name)) { $roots.Add($g) }

    [pscustomobject]@{
        Roots   = $roots.ToArray()
        Bundles = $bundles
        Order   = @($bundles.Keys | Sort-Object)
    }
}
