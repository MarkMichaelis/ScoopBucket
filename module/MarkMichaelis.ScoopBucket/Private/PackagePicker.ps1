# The hierarchical package picker (#543): `Install-Package` with no arguments.
#
# Everything except Show-PackagePicker's console loop is pure -- state in,
# state or text out -- so the tree, the boxes, the keys and the plan are
# tested without a console.
#
# Boxes. An installed item never looks like a new install:
#   [ ]  not installed, not checked          [x]  will be installed
#   [*]  installed, will be upgraded         [=]  installed, left as it is
#   [!]  not checked, but something checked needs it (DependsOn/Companions)
#   [~]  a group with some of its items checked
#
# Install only: unchecking an installed item leaves it alone; nothing is ever
# uninstalled from here.

function Get-PickerLeaves {
    # The items under a node, one per identity, guarding against link cycles.
    param([Parameter(Mandatory)][object]$Node)
    $ids = [System.Collections.Generic.List[object]]::new()
    # Identities compare without case, as Install-Package -Name '*' compares them.
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenGroups = [System.Collections.Generic.HashSet[string]]::new()
    $walk = {
        param($n)
        if ($n.Kind -eq 'Group') {
            if ($seenGroups.Add($n.Key)) { foreach ($c in $n.Children) { & $walk $c } }
        } elseif ($seenIds.Add($n.Identity)) {
            $ids.Add($n)
            foreach ($c in (Get-PickerSubItems -Node $n)) { & $walk $c }
        }
    }
    & $walk $Node
    # Emitted one by one (no leading comma), so @(Get-PickerLeaves ...) is the
    # list of leaves rather than a list holding the list.
    $ids.ToArray()
}

function Get-PickerSubItems {
    # A package's sub-items (#559): its companions and dependencies, and
    # Chocolatey under a choco package. Groups keep their own Children.
    param([Parameter(Mandatory)][object]$Node)
    if ($Node.Kind -ne 'Group' -and $Node.PSObject.Properties['Children'] -and $Node.Children) { $Node.Children.ToArray() }
}

function Test-PickerOpenable {
    # A row that unfolds: a group, or a package with sub-items.
    param([Parameter(Mandatory)][object]$Node)
    $Node.Kind -eq 'Group' -or @(Get-PickerSubItems -Node $Node).Count -gt 0
}

function Get-PickerRowChildren {
    param([Parameter(Mandatory)][object]$Node)
    if ($Node.Kind -eq 'Group') { $Node.Children.ToArray() } else { Get-PickerSubItems -Node $Node }
}

function Get-PickerShownLeaves {
    # The items under a node that a filter shows -- the same rule as
    # Get-PickerRows: an item whose name matches, or anything inside a group
    # whose name matches.
    param([Parameter(Mandatory)][object]$Node, [Parameter(Mandatory)][string]$Filter)
    $shown = [System.Collections.Generic.List[object]]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenGroups = [System.Collections.Generic.HashSet[string]]::new()
    $walk = {
        param($n, [bool]$all)
        if ($n.Kind -eq 'Group') {
            if (-not $seenGroups.Add($n.Key)) { return }
            $inside = $all -or $n.Name -like "*$Filter*"
            foreach ($c in $n.Children) { & $walk $c $inside }
        } else {
            $hit = $all -or $n.Name -like "*$Filter*"
            if ($hit -and $seenIds.Add($n.Identity)) { $shown.Add($n) }
            foreach ($c in (Get-PickerSubItems -Node $n)) { & $walk $c $hit }
        }
    }
    & $walk $Node $false
    $shown.ToArray()
}

function New-PickerState {
    <#
    .SYNOPSIS
        Picker state over a catalog, starting from the default set plus what
        is installed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [hashtable]$Installed = @{}
    )

    # One leaf per identity. A package's own node wins over a manifest node for
    # the same thing, so labels and details describe the package.
    $leaves = @{}
    foreach ($root in $Catalog.Roots) {
        foreach ($leaf in (Get-PickerLeaves -Node $root)) {
            $existing = $leaves[$leaf.Identity]
            if (-not $existing -or ($existing.Kind -eq 'Manifest' -and $leaf.Kind -eq 'Package')) { $leaves[$leaf.Identity] = $leaf }
        }
    }

    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase
    # A package is a default if any declaration of it says so.
    $defaults = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    $always = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    $owner = @{}
    foreach ($name in $Catalog.Order) {
        $info = $Catalog.Bundles[$name]
        foreach ($p in $info.Packages) {
            # A link to another bundle is that bundle's packages, not a package.
            # A scoop package installed through a bare manifest of this bucket
            # ('MarkMichaelis/ClaudeCode') is an ordinary package.
            $target = Get-PickerLinkTarget -Package $p
            if ($target -and $Catalog.Bundles.ContainsKey($target)) { continue }
            $id = Get-PickerIdentity -Package $p -Bundle $name
            if ($p.Default -and $leaves.ContainsKey($id)) { [void]$defaults.Add($id) }
            if ($p.Required -and $leaves.ContainsKey($id)) { [void]$always.Add($id) }
            # The first bundle (name order, as Install-Package -Name '*' walks
            # them) installs a package several bundles declare.
            if (-not $owner.ContainsKey($id)) { $owner[$id] = [pscustomobject]@{ Bundle = $name; BundlePath = $info.BundlePath; Name = $p.Name } }
        }
    }

    # Which top-level groups each item appears under, so a row can say where
    # else toggling it shows up (one package, one checkbox).
    $topGroups = @{}
    $rootNames = @{}
    foreach ($root in $Catalog.Roots) {
        $rootNames[$root.Key] = $root.Name
        foreach ($leaf in (Get-PickerLeaves -Node $root)) {
            if (-not $topGroups.ContainsKey($leaf.Identity)) { $topGroups[$leaf.Identity] = [System.Collections.Generic.List[string]]::new() }
            if (-not $topGroups[$leaf.Identity].Contains($root.Name)) { $topGroups[$leaf.Identity].Add($root.Name) }
        }
    }

    # Each package's companions (#559), and the Chocolatey item every choco
    # package needs.
    $companions = @{}
    $chocoId = $null
    foreach ($leaf in $leaves.Values) {
        if ($leaf.Kind -eq 'Manifest' -and $leaf.Name -eq 'Chocolatey') { $chocoId = $leaf.Identity }
    }
    $seenNodes = [System.Collections.Generic.HashSet[string]]::new()
    $walkNodes = {
        param($n)
        if ($n.Kind -eq 'Group') { if ($seenNodes.Add($n.Key)) { foreach ($c in $n.Children) { & $walkNodes $c } }; return }
        foreach ($c in (Get-PickerSubItems -Node $n)) {
            if ($c.Role -eq 'Companion' -and $c.PSObject.Properties['Identity'] -and $c.Identity) {
                if (-not $companions.ContainsKey($n.Identity)) { $companions[$n.Identity] = [System.Collections.Generic.HashSet[string]]::new($ignoreCase) }
                [void]$companions[$n.Identity].Add($c.Identity)
            }
            & $walkNodes $c
        }
    }
    foreach ($root in $Catalog.Roots) { & $walkNodes $root }
    # The other direction: the packages each companion accompanies.
    $companionOf = @{}
    foreach ($accompanied in $companions.Keys) {
        foreach ($id in $companions[$accompanied]) {
            if (-not $companionOf.ContainsKey($id)) { $companionOf[$id] = [System.Collections.Generic.List[string]]::new() }
            $companionOf[$id].Add($accompanied)
        }
    }

    $state = [pscustomobject]@{
        Catalog     = $Catalog
        Always      = $always
        Companions  = $companions
        CompanionOf = $companionOf
        ChocoId     = $chocoId
        Installed   = $Installed
        Leaves      = $leaves
        Defaults    = $defaults
        Owner       = $owner
        Selected    = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        Required    = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        Expanded    = [System.Collections.Generic.HashSet[string]]::new()
        Cursor      = 0
        Top         = 0
        ReviewTop   = 0
        Cycle       = $null
        TopGroups   = $topGroups
        RootNames   = $rootNames
        Filter      = ''
        Mode        = 'Tree'
        ShowDetails = $false
    }
    Set-PickerSelection -State $state -Mode Defaults
    $state
}

function Test-PickerCompanionDefault {
    # Not a companion, or a companion of a package that is on by default.
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][string]$Identity)
    if (-not $State.CompanionOf.ContainsKey($Identity)) { return $true }
    [bool](@($State.CompanionOf[$Identity] | Where-Object { $State.Defaults.Contains($_) -or $State.Always.Contains($_) }).Count)
}

function Test-PickerInstalled {
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][string]$Identity)
    $State.Installed.ContainsKey($Identity) -and $State.Installed[$Identity] -eq $true
}

function Update-PickerRequired {
    # What the checked packages pull in (DependsOn / Companions), per the
    # bundle that installs each of them.
    param([Parameter(Mandatory)][object]$State)
    $State.Required.Clear()
    foreach ($id in $State.Always) { if (-not $State.Selected.Contains($id)) { [void]$State.Required.Add($id) } }
    foreach ($name in $State.Catalog.Order) {
        $info = $State.Catalog.Bundles[$name]
        $names = @(foreach ($id in @($State.Selected) + @($State.Always)) {
                $o = $State.Owner[$id]
                if ($o -and $o.Bundle -eq $name) { $o.Name }
            })
        if ($names.Count -eq 0) { continue }
        try {
            # Resolve-PackageOrder emits its list as ONE array object; assign
            # before iterating. An unchecked companion is left out (#559).
            $skip = @(Get-PickerSkippedCompanions -State $State -Bundle $name)
            $closure = Resolve-PackageOrder -Packages $info.Packages -Name $names -Skip $skip
        } catch {
            continue   # an unplannable bundle is reported when it is installed
        }
        foreach ($p in $closure) { Add-PickerRequired -State $State -Package $p -Bundle $name }
    }
    # Every choco package needs Chocolatey.
    if ($State.ChocoId -and -not $State.Selected.Contains($State.ChocoId)) {
        foreach ($id in @($State.Selected) + @($State.Required)) {
            $leaf = $State.Leaves[$id]
            if ($leaf -and $leaf.Kind -eq 'Package' -and $leaf.Package.Installer -eq 'choco') { [void]$State.Required.Add($State.ChocoId); break }
        }
    }
}

function Get-PickerSkippedCompanions {
    # The companions in one bundle that are not checked: installing their
    # package leaves them out (#559).
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][string]$Bundle)
    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase
    # What the checked packages of this bundle need through DependsOn is
    # never skipped, even when it is also some package's unchecked companion.
    $info = $State.Catalog.Bundles[$Bundle]
    $needed = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    if ($info) {
        $byName = @{}
        foreach ($p in $info.Packages) { if (-not $byName.ContainsKey($p.Name)) { $byName[$p.Name] = $p } }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($id in @($State.Selected) + @($State.Always)) {
            $o = $State.Owner[$id]
            if ($o -and $o.Bundle -eq $Bundle) { $queue.Enqueue($o.Name) }
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        while ($queue.Count -gt 0) {
            $n = $queue.Dequeue()
            if (-not $seen.Add($n) -or -not $byName.ContainsKey($n)) { continue }
            foreach ($d in @($byName[$n].DependsOn)) { if ($d) { [void]$needed.Add($d); $queue.Enqueue($d) } }
        }
    }
    $names = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    foreach ($set in $State.Companions.Values) {
        foreach ($id in $set) {
            if ($State.Selected.Contains($id)) { continue }
            $o = $State.Owner[$id]
            if ($o -and $o.Bundle -eq $Bundle -and -not $needed.Contains($o.Name)) { [void]$names.Add($o.Name) }
        }
    }
    @($names)
}

function Add-PickerRequired {
    # Mark what installing one package will install. A link to another bundle
    # installs that whole bundle (its script runs every package it declares),
    # so every item of that bundle is marked, never the link itself.
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][string]$Bundle,
        [System.Collections.Generic.HashSet[string]]$Visited
    )
    $target = Get-PickerLinkTarget -Package $Package
    if ($target -and $State.Catalog.Bundles.ContainsKey($target)) {
        if (-not $Visited) { $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
        if (-not $Visited.Add($target)) { return }
        foreach ($p in $State.Catalog.Bundles[$target].Packages) {
            Add-PickerRequired -State $State -Package $p -Bundle $target -Visited $Visited
        }
        return
    }
    $id = Get-PickerIdentity -Package $Package -Bundle $Bundle
    if (-not $State.Selected.Contains($id)) { [void]$State.Required.Add($id) }
}

function Set-PickerSelection {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][ValidateSet('Defaults', 'All', 'None')][string]$Mode
    )
    $State.Selected.Clear()
    foreach ($id in $State.Leaves.Keys) {
        $on = switch ($Mode) {
            'All'      { $true }
            'None'     { $false }
            # An installed config-only manifest is not re-run, matching
            # Install-Package -Name '*', which never runs manifests. A
            # companion is a default only with a package it accompanies
            # (#563: Visual Studio's Git settings wait for Visual Studio).
            'Defaults' {
                ($State.Defaults.Contains($id) -and (Test-PickerCompanionDefault -State $State -Identity $id)) -or
                    ($State.Leaves[$id].Kind -ne 'Manifest' -and (Test-PickerInstalled -State $State -Identity $id))
            }
        }
        if ($on) { [void]$State.Selected.Add($id) }
    }
    Update-PickerRequired -State $State
}

function Get-PickerGroupIds {
    # The identities Space on a group acts on: everything under it, or, while
    # a filter is active, only what the filter shows.
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Node)
    $leaves = if ($State.Filter) { @(Get-PickerShownLeaves -Node $Node -Filter $State.Filter) } else { @(Get-PickerLeaves -Node $Node) }
    @($leaves | ForEach-Object { $_.Identity })
}

$script:PickerGroupStepNames = @{
    1 = 'add everything not installed'
    2 = 'everything, upgrades too'
    3 = 'only what is installed'
    4 = 'back to how it was'
}

function Get-PickerGroupTarget {
    # The items one cycle step leaves checked, among a group's $Ids.
    param(
        [Parameter(Mandatory)][object]$State,
        [AllowEmptyCollection()][string[]]$Ids,
        [Parameter(Mandatory)][int]$Step,
        [AllowEmptyCollection()][string[]]$Before
    )
    foreach ($id in $Ids) {
        $installed = Test-PickerInstalled -State $State -Identity $id
        $on = switch ($Step) {
            1 { if ($installed) { $State.Selected.Contains($id) } else { $true } }   # installed items keep their box
            2 { $true }
            3 { $installed -and $State.Leaves[$id].Kind -ne 'Manifest' }              # a config manifest is not re-run
            4 { $Before -contains $id }
        }
        if ($on) { $id }
    }
}

function Get-PickerGroupCycle {
    # The cycle Space on this group continues, or a new one. A cycle continues
    # only for the same group, under the same filter, while its items are
    # exactly as the previous step left them; any other change starts over.
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Node)
    $ids = @(Get-PickerGroupIds -State $State -Node $Node)
    $checked = @($ids | Where-Object { $State.Selected.Contains($_) })
    $now = ($checked | Sort-Object) -join "`n"
    $key = "$($Node.Key)|$($State.Filter)"
    $c = $State.Cycle
    if ($c -and $c.Key -eq $key -and $c.Last -eq $now) {
        return [pscustomobject]@{ Key = $key; Ids = $ids; Now = $now; Step = $c.Step + 1; Before = $c.Before }
    }
    [pscustomobject]@{ Key = $key; Ids = $ids; Now = $now; Step = 1; Before = $checked }
}

function Get-PickerGroupStep {
    # The step Space on this group takes next, skipping any step that would
    # change nothing (step 4 always ends the cycle).
    [OutputType([int])]
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Node)
    $cycle = Get-PickerGroupCycle -State $State -Node $Node
    $step = $cycle.Step
    while ($step -lt 4) {
        $target = (@(Get-PickerGroupTarget -State $State -Ids $cycle.Ids -Step $step -Before $cycle.Before) | Sort-Object) -join "`n"
        if ($target -ne $cycle.Now) { break }
        $step++
    }
    $step
}

function Switch-PickerNode {
    <#
    .SYNOPSIS
        Space on an item toggles it. Space on a group steps through:
          1. add everything not installed (installed items keep their box)
          2. everything, upgrading what is installed too
          3. only what is installed (pick new installs one by one)
          4. back to how it was before step 1
        A step that would change nothing is skipped, and a group only touches
        its own items (only those a filter shows, while one is active).
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Node)
    if ($Node.Kind -ne 'Group') {
        $on = -not $State.Selected.Contains($Node.Identity)
        if ($on) { [void]$State.Selected.Add($Node.Identity) } else { [void]$State.Selected.Remove($Node.Identity) }
        # A package's companions go with it: off with it, and back on by
        # their own default (#559).
        if ($State.Companions.ContainsKey($Node.Identity)) {
            foreach ($id in $State.Companions[$Node.Identity]) {
                if (-not $on) { [void]$State.Selected.Remove($id) }
                elseif ($State.Defaults.Contains($id)) { [void]$State.Selected.Add($id) }
            }
        }
        Update-PickerRequired -State $State
        return
    }

    $cycle = Get-PickerGroupCycle -State $State -Node $Node
    $step = Get-PickerGroupStep -State $State -Node $Node
    $target = @(Get-PickerGroupTarget -State $State -Ids $cycle.Ids -Step $step -Before $cycle.Before)
    foreach ($id in $cycle.Ids) {
        if ($target -contains $id) { [void]$State.Selected.Add($id) } else { [void]$State.Selected.Remove($id) }
    }
    Update-PickerRequired -State $State
    if ($step -ge 4) {
        $State.Cycle = $null
    } else {
        $State.Cycle = [pscustomobject]@{
            Key    = $cycle.Key
            Step   = $step
            Before = $cycle.Before
            Last   = (@($cycle.Ids | Where-Object { $State.Selected.Contains($_) }) | Sort-Object) -join "`n"
        }
    }
}

function Get-PickerBoxColor {
    # One color per box, shared by the rows and the legend.
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Box)
    switch ($Box) {
        '[x]' { 'Green' }
        '[*]' { 'Cyan' }
        '[=]' { 'DarkGray' }
        '[!]' { 'Yellow' }
        '[~]' { 'White' }
        default { 'Gray' }
    }
}

function Get-PickerBox {
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Node)
    if ($Node.Kind -eq 'Group') {
        $ids = @((Get-PickerLeaves -Node $Node) | ForEach-Object { $_.Identity })
        $on = @($ids | Where-Object { $State.Selected.Contains($_) -or $State.Required.Contains($_) }).Count
        if ($on -eq 0) { return '[ ]' }
        if ($on -eq $ids.Count) { return '[x]' }
        return '[~]'
    }
    $id = $Node.Identity
    $wanted = $State.Selected.Contains($id) -or $State.Required.Contains($id)
    if (Test-PickerInstalled -State $State -Identity $id) {
        if ($wanted) { return '[*]' } else { return '[=]' }
    }
    if ($State.Selected.Contains($id)) { return '[x]' }
    if ($State.Required.Contains($id)) { return '[!]' }
    '[ ]'
}

function Get-PickerRows {
    # The visible rows: groups are collapsed until expanded, and a filter
    # shows only matching items with every group above them open. A group
    # whose own name matches shows everything in it.
    param([Parameter(Mandatory)][object]$State)
    $rows = [System.Collections.Generic.List[object]]::new()
    $filter = $State.Filter
    $isMatch = {
        param($n, $seen)
        if ($n.Name -like "*$filter*") { return $true }
        if (-not (Test-PickerOpenable -Node $n) -or -not $seen.Add($n.Key)) { return $false }
        foreach ($c in (Get-PickerRowChildren -Node $n)) { if (& $isMatch $c $seen) { return $true } }
        $false
    }
    $walk = {
        param($nodes, [int]$depth, [string]$parent, $onPath, [bool]$showAll)
        foreach ($n in $nodes) {
            if ($filter -and -not $showAll -and -not (& $isMatch $n ([System.Collections.Generic.HashSet[string]]::new()))) { continue }
            $path = "$parent/$($n.Key)"
            $rows.Add([pscustomobject]@{ Node = $n; Depth = $depth; Path = $path; Parent = $parent })
            $open = (Test-PickerOpenable -Node $n) -and ($filter -or $State.Expanded.Contains($path))
            $childrenAll = $showAll -or ($filter -and $n.Name -like "*$filter*")
            if ($open -and $onPath -notcontains $n.Key) { & $walk @(Get-PickerRowChildren -Node $n) ($depth + 1) $path (@($onPath) + $n.Key) $childrenAll }
        }
    }
    & $walk $State.Catalog.Roots 0 '' @() $false
    , $rows.ToArray()
}

function Get-PickerPlan {
    <#
    .SYNOPSIS
        What to install: package names per bundle (each package sent to the
        bundle that declares it, so same-named packages in different bundles
        never mix), bare manifest names, and the lists the review shows.
    #>
    param([Parameter(Mandatory)][object]$State)
    $byBundle = @{}
    $manifests = [System.Collections.Generic.List[string]]::new()
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($State.Selected) + @($State.Always)) { [void]$wanted.Add($id) }
    # A needed bare manifest (Chocolatey) is installed when it is missing, and
    # FIRST: the packages that need it are installed with it.
    $first = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($State.Required | Sort-Object)) {
        $leaf = $State.Leaves[$id]
        if ($leaf -and $leaf.Kind -eq 'Manifest' -and -not $State.Owner[$id] -and -not (Test-PickerInstalled -State $State -Identity $id)) { $first.Add($leaf.Name) }
    }
    foreach ($id in @($wanted | Sort-Object)) {
        # A package goes to the bundle that declares it -- even when it was
        # checked through a manifest node for the same thing; only a manifest
        # no package installs is run as a bare manifest.
        $o = $State.Owner[$id]
        if (-not $o) {
            $leaf = $State.Leaves[$id]
            if ($leaf -and $leaf.Kind -eq 'Manifest') { $manifests.Add($leaf.Name) }
            continue
        }
        if (-not $byBundle.ContainsKey($o.BundlePath)) {
            $byBundle[$o.BundlePath] = [pscustomobject]@{
                BundlePath = $o.BundlePath; Bundle = $o.Bundle
                Names = [System.Collections.Generic.List[string]]::new()
                Skip  = @(Get-PickerSkippedCompanions -State $State -Bundle $o.Bundle)
            }
        }
        $byBundle[$o.BundlePath].Names.Add($o.Name)
    }
    $label = { param($id) if ($State.Leaves.ContainsKey($id)) { $State.Leaves[$id].Name } else { ($id -split '\|', 2)[-1] } }
    $new = [System.Collections.Generic.List[string]]::new()
    $upgrade = [System.Collections.Generic.List[string]]::new()
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($State.Leaves.Keys | Sort-Object)) {
        $installed = Test-PickerInstalled -State $State -Identity $id
        if ($State.Selected.Contains($id)) {
            if ($installed) { $upgrade.Add((& $label $id)) } else { $new.Add((& $label $id)) }
        } elseif ($installed -and -not $State.Required.Contains($id)) {
            $kept.Add((& $label $id))
        }
    }
    [pscustomobject]@{
        ByBundle  = $byBundle
        First     = $first.ToArray()
        Manifests = $manifests.ToArray()
        New       = @($new | Sort-Object)
        Upgrade   = @($upgrade | Sort-Object)
        Required  = @($State.Required | ForEach-Object { & $label $_ } | Sort-Object)
        Kept      = @($kept | Sort-Object)
    }
}

function Format-PickerScreen {
    <#
    .SYNOPSIS
        The screen as lines of @{ Text; Color; Highlight }, exactly Height - 1
        of them, each padded or cut to Width.
    #>
    param(
        [Parameter(Mandatory)][object]$State,
        [int]$Width = 100,
        [int]$Height = 30
    )
    $lines = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Text, [string]$Color = 'Gray', [bool]$Highlight = $false, [object[]]$Segments = $null)
        # A line cut to fit is drawn in one color, so it keeps its '~' marker.
        if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, [Math]::Max(0, $Width - 1)) + '~'; $Segments = $null }
        $line = [pscustomobject]@{ Text = $Text.PadRight($Width); Color = $Color; Highlight = $Highlight }
        if ($Segments) { $line | Add-Member -NotePropertyName Segments -NotePropertyValue $Segments }
        $lines.Add($line)
    }

    if ($State.Mode -eq 'Review') {
        # The body scrolls inside the window; the header and the footer stay.
        $plan = Get-PickerPlan -State $State
        $body = [System.Collections.Generic.List[object]]::new()
        $sections = @(
            @{ Title = 'New installs'; Items = $plan.New; Color = 'Green' }
            @{ Title = 'Upgrades (installed, checked)'; Items = $plan.Upgrade; Color = 'Cyan' }
            @{ Title = 'Needed by what you checked'; Items = $plan.Required; Color = 'Yellow' }
            @{ Title = 'Left as they are (installed, unchecked)'; Items = $plan.Kept; Color = 'DarkGray' }
        )
        if (@($plan.New).Count + @($plan.Upgrade).Count + @($plan.Required).Count -eq 0) {
            $body.Add(@('  Nothing is checked, so nothing will be installed.', 'Yellow'))
        }
        foreach ($s in $sections) {
            if (@($s.Items).Count -eq 0) { continue }
            $body.Add(@("  $($s.Title) ($(@($s.Items).Count)):", $s.Color))
            foreach ($i in $s.Items) { $body.Add(@("      $i", $s.Color)) }
        }
        $room = [Math]::Max(1, $Height - 3)
        $State.ReviewTop = [Math]::Min([Math]::Max(0, $State.ReviewTop), [Math]::Max(0, $body.Count - $room))
        & $add 'Review -- y installs this, Esc goes back, Up/Down scroll' 'White'
        for ($i = $State.ReviewTop; $i -lt [Math]::Min($body.Count, $State.ReviewTop + $room); $i++) { & $add $body[$i][0] $body[$i][1] }
        while ($lines.Count -lt $room + 1) { & $add '' }
        $below = $body.Count - ($State.ReviewTop + $room)
        $footer = @()
        if ($State.ReviewTop -gt 0) { $footer += "$($State.ReviewTop) more above" }
        if ($below -gt 0) { $footer += "$below more below" }
        & $add ($(if ($footer) { '  (' + ($footer -join ', ') + ' -- Up/Down/PageUp/PageDown)' } else { '' })) 'DarkGray'
    } else {
        # Both lines fit an 80-column console; '? details' and 'Esc cancel'
        # sit on the bottom line.
        & $add 'Space check  Left/Right fold  / filter  d/a/n defaults/all/none  Enter review' 'White'
        # The legend: every box, drawn in the color its rows use.
        $legend = foreach ($entry in @(
                @('[x]', 'install'), @('[*]', 'upgrade'), @('[=]', 'keep as is'),
                @('[!]', 'needed'), @('[~]', 'some'), @('[ ]', 'skip'))) {
            [pscustomobject]@{ Text = "$($entry[0]) $($entry[1])  "; Color = Get-PickerBoxColor -Box $entry[0] }
        }
        $legendText = -join @($legend | ForEach-Object { $_.Text })
        $lines.Add([pscustomobject]@{ Text = $legendText.PadRight($Width).Substring(0, $Width); Color = 'Gray'; Highlight = $false; Segments = @($legend) })
        $rows = Get-PickerRows -State $State
        if ($rows.Count -eq 0) { $State.Cursor = 0 } else { $State.Cursor = [Math]::Min([Math]::Max(0, $State.Cursor), $rows.Count - 1) }
        $treeHeight = [Math]::Max(3, $Height - 5)
        # A collapse or a filter can shrink the rows below the scroll position.
        $State.Top = [Math]::Min($State.Top, [Math]::Max(0, $rows.Count - $treeHeight))
        if ($State.Cursor -lt $State.Top) { $State.Top = $State.Cursor }
        if ($State.Cursor -ge $State.Top + $treeHeight) { $State.Top = $State.Cursor - $treeHeight + 1 }
        for ($i = $State.Top; $i -lt [Math]::Min($rows.Count, $State.Top + $treeHeight); $i++) {
            $row = $rows[$i]
            $box = Get-PickerBox -State $State -Node $row.Node
            $suffix = ''
            $note = ''
            if ($row.Node.Kind -eq 'Group') {
                $ids = @((Get-PickerLeaves -Node $row.Node) | ForEach-Object { $_.Identity })
                $on = @($ids | Where-Object { $State.Selected.Contains($_) -or $State.Required.Contains($_) }).Count
                $sign = if ($row.Node.Kind -eq 'Group' -and -not ($State.Filter -or $State.Expanded.Contains($row.Path))) { '+' } else { '-' }
                $suffix = "  $sign $on/$($ids.Count)"
            } else {
                # A package with sub-items unfolds like a group (#559).
                if (Test-PickerOpenable -Node $row.Node) {
                    $suffix = if ($State.Filter -or $State.Expanded.Contains($row.Path)) { '  -' } else { '  +' }
                }
                if ($box -in '[*]', '[=]') { $suffix += '  installed' }
                elseif ($box -eq '[!]' -and -not $State.Always.Contains($row.Node.Identity)) { $suffix += '  needed' }
                if ($State.Always.Contains($row.Node.Identity)) { $suffix += '  required' }
                if ($row.Node.Kind -eq 'Manifest') { $suffix += '  (manifest)' }
                # The same package under another top-level group shares this checkbox.
                $homeGroup = $State.RootNames[($row.Path -split '/')[1]]
                $elsewhere = @($State.TopGroups[$row.Node.Identity] | Where-Object { $_ -ne $homeGroup })
                if ($elsewhere.Count -gt 0) { $note = "  (also in $($elsewhere -join ', '))" }
            }
            $color = Get-PickerBoxColor -Box $box
            $marker = if ($i -eq $State.Cursor) { '>' } else { ' ' }
            $text = "{0} {1}{2} {3}{4}" -f $marker, ('  ' * $row.Depth), $box, $row.Node.Name, $suffix
            # The "also in" note is a side remark: dimmed, unless the cursor
            # row's highlight already draws the whole line in one color.
            $segments = $null
            if ($note -and $i -ne $State.Cursor) {
                $segments = @([pscustomobject]@{ Text = $text; Color = $color }, [pscustomobject]@{ Text = $note; Color = 'DarkGray' })
            }
            & $add ($text + $note) $color ($i -eq $State.Cursor) $segments
        }
        while ($lines.Count -lt $treeHeight + 2) { & $add '' }
        $plan = Get-PickerPlan -State $State
        if ($State.Mode -eq 'Filter') {
            & $add "Filter: $($State.Filter)_   Enter keeps it   Esc clears it" 'White'
        } else {
            $hint = ''
            if ($rows.Count -gt 0 -and $rows[$State.Cursor].Node.Kind -eq 'Group') {
                $next = $script:PickerGroupStepNames[(Get-PickerGroupStep -State $State -Node $rows[$State.Cursor].Node)]
                $hint = "     Space: $next"
            }
            & $add ("{0} new   {1} upgrades   {2} needed{3}" -f `
                    @($plan.New).Count, @($plan.Upgrade).Count, @($plan.Required).Count, $hint) 'White'
        }
        $detail = '? details  Esc cancel'
        if ($State.ShowDetails -and $rows.Count -gt 0) {
            $n = $rows[$State.Cursor].Node
            $detail = switch ($n.Kind) {
                'Package'  { "$($n.Package.Installer) $($n.Package.Id) -- $($n.Package.Notes)" }
                'Manifest' { "Bare manifest '$($n.Name)' in $($n.Folder); installs with scoop install $($n.Name)." }
                default    { "$($n.Name): $(@(Get-PickerLeaves -Node $n).Count) items." }
            }
        }
        & $add $detail 'DarkGray'
    }
    while ($lines.Count -lt $Height - 1) { & $add '' }
    # Never more than the window holds, or the console scrolls under the cursor.
    if ($lines.Count -gt [Math]::Max(1, $Height - 1)) { $lines.RemoveRange([Math]::Max(1, $Height - 1), $lines.Count - [Math]::Max(1, $Height - 1)) }
    , $lines.ToArray()
}

function Invoke-PickerKey {
    <#
    .SYNOPSIS
        Apply one key. Returns 'Continue', 'Cancel', or 'Confirm'.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][System.ConsoleKeyInfo]$Key)

    if ($State.Mode -eq 'Review') {
        if ($Key.KeyChar -in 'y', 'Y') { return 'Confirm' }
        switch ($Key.Key) {
            ([ConsoleKey]::UpArrow)   { $State.ReviewTop -= 1 }
            ([ConsoleKey]::DownArrow) { $State.ReviewTop += 1 }
            ([ConsoleKey]::PageUp)    { $State.ReviewTop -= 10 }
            ([ConsoleKey]::PageDown)  { $State.ReviewTop += 10 }
            ([ConsoleKey]::Home)      { $State.ReviewTop = 0 }
            ([ConsoleKey]::End)       { $State.ReviewTop = [int]::MaxValue }   # clamped when drawn
        }
        if ($Key.Key -in [ConsoleKey]::Escape, [ConsoleKey]::Backspace -or $Key.KeyChar -in 'n', 'N') { $State.Mode = 'Tree' }
        return 'Continue'
    }

    if ($State.Mode -eq 'Filter') {
        switch ($Key.Key) {
            ([ConsoleKey]::Enter)     { $State.Mode = 'Tree' }
            ([ConsoleKey]::Escape)    { $State.Filter = ''; $State.Mode = 'Tree' }
            ([ConsoleKey]::Backspace) { if ($State.Filter) { $State.Filter = $State.Filter.Substring(0, $State.Filter.Length - 1) } }
            default { if (-not [char]::IsControl($Key.KeyChar)) { $State.Filter += $Key.KeyChar } }
        }
        $State.Cursor = 0
        $State.Top = 0
        return 'Continue'
    }

    $rows = Get-PickerRows -State $State
    $row = if ($rows.Count -gt 0) { $rows[[Math]::Min($State.Cursor, $rows.Count - 1)] }
    switch ($Key.Key) {
        ([ConsoleKey]::UpArrow)    { $State.Cursor = [Math]::Max(0, $State.Cursor - 1); return 'Continue' }
        ([ConsoleKey]::DownArrow)  { $State.Cursor = [Math]::Min($rows.Count - 1, $State.Cursor + 1); return 'Continue' }
        ([ConsoleKey]::PageUp)     { $State.Cursor = [Math]::Max(0, $State.Cursor - 10); return 'Continue' }
        ([ConsoleKey]::PageDown)   { $State.Cursor = [Math]::Min($rows.Count - 1, $State.Cursor + 10); return 'Continue' }
        ([ConsoleKey]::Home)       { $State.Cursor = 0; return 'Continue' }
        ([ConsoleKey]::End)        { $State.Cursor = $rows.Count - 1; return 'Continue' }
        ([ConsoleKey]::RightArrow) {
            if ($row -and (Test-PickerOpenable -Node $row.Node)) { [void]$State.Expanded.Add($row.Path) }
            return 'Continue'
        }
        ([ConsoleKey]::LeftArrow) {
            if ($row -and (Test-PickerOpenable -Node $row.Node) -and $State.Expanded.Contains($row.Path)) {
                [void]$State.Expanded.Remove($row.Path)
            } elseif ($row -and $row.Parent) {
                for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Path -eq $row.Parent) { $State.Cursor = $i; break } }
            }
            return 'Continue'
        }
        ([ConsoleKey]::Spacebar)   { if ($row) { Switch-PickerNode -State $State -Node $row.Node }; return 'Continue' }
        ([ConsoleKey]::Enter)      { $State.Mode = 'Review'; $State.ReviewTop = 0; return 'Continue' }
        ([ConsoleKey]::Escape) {
            # Esc clears a kept filter first; with no filter it cancels.
            if ($State.Filter) { $State.Filter = ''; $State.Cursor = 0; $State.Top = 0; return 'Continue' }
            return 'Cancel'
        }
    }
    switch -CaseSensitive ([string]$Key.KeyChar) {
        'd' { Set-PickerSelection -State $State -Mode Defaults }
        'a' { Set-PickerSelection -State $State -Mode All }
        'n' { Set-PickerSelection -State $State -Mode None }
        '/' { $State.Mode = 'Filter'; $State.Filter = '' }
        '?' { $State.ShowDetails = -not $State.ShowDetails }
    }
    'Continue'
}

function Test-PickerInteractive {
    # The picker needs a real console: keyboard input that is not redirected,
    # in a session not started with -NonInteractive.
    [OutputType([bool])]
    param()
    try {
        [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
            $Host.Name -eq 'ConsoleHost' -and
            -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni(nteractive)?$' })
    } catch {
        $false
    }
}

function Show-PackagePicker {
    <#
    .SYNOPSIS
        Run the picker in the console. Returns the plan (Get-PickerPlan), or
        $null when the owner cancels.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [hashtable]$Installed = @{}
    )
    $state = New-PickerState -Catalog $Catalog -Installed $Installed
    $cursorWasVisible = $true
    try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
    try {
        Clear-Host
        while ($true) {
            $height = 30; $width = 100
            try { $height = [Console]::WindowHeight; $width = [Console]::WindowWidth - 1 } catch { }
            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
            foreach ($line in (Format-PickerScreen -State $state -Width $width -Height $height)) {
                if ($line.Highlight) {
                    Write-Host $line.Text -ForegroundColor Black -BackgroundColor $line.Color
                } elseif ($line.PSObject.Properties['Segments'] -and $line.Segments) {
                    # A line drawn in several colors (the legend).
                    $used = 0
                    foreach ($segment in $line.Segments) {
                        $piece = $segment.Text
                        if ($used + $piece.Length -gt $width) { $piece = $piece.Substring(0, [Math]::Max(0, $width - $used)) }
                        Write-Host $piece -ForegroundColor $segment.Color -NoNewline
                        $used += $piece.Length
                    }
                    Write-Host (' ' * [Math]::Max(0, $width - $used))
                } else {
                    Write-Host $line.Text -ForegroundColor $line.Color
                }
            }
            switch (Invoke-PickerKey -State $state -Key ([Console]::ReadKey($true))) {
                'Cancel'  { return $null }
                'Confirm' { return Get-PickerPlan -State $state }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { }
        Clear-Host
    }
}
