# Which of the picker's items are installed (#543), answered with one bulk
# query per engine rather than a probe per package: on a fresh machine almost
# every item is absent, and probing ~80 of them one by one would keep the
# owner waiting a minute or more before the picker appears.
#
# Only custom packages fall back to Get-PackagePresence (their VerifyScript or
# CliCommands), since no engine inventory covers them. A wrong "not
# installed" here costs nothing: the install path probes again and upgrades.

function Get-InstalledPackageMap {
    <#
    .SYNOPSIS
        Map each picker item's identity to $true / $false / $null (unknown).
    .PARAMETER Catalog
        Get-PackageCatalog output.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object]$Catalog)

    # One sample node per identity.
    $nodes = @{}
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $walk = {
        param($list)
        foreach ($n in $list) {
            if ($n.Kind -eq 'Group') {
                if ($seen.Add($n.Key)) { & $walk $n.Children }
            } else {
                if (-not $nodes.ContainsKey($n.Identity)) { $nodes[$n.Identity] = $n }
                # A package's sub-items (#559) are items too.
                if ($seen.Add($n.Key)) { & $walk @(Get-PickerSubItems -Node $n) }
            }
        }
    }
    & $walk $Catalog.Roots

    $installerOf = { param($n) if ($n.Kind -eq 'Manifest') { 'scoop' } else { ($n.Identity -split '\|', 2)[0] } }
    $wanted = @($nodes.Values | ForEach-Object { & $installerOf $_ } | Sort-Object -Unique)

    $index = @{}
    $bulk = @($wanted | Where-Object { $_ -in 'winget', 'choco', 'dotnetTool' })
    if ($bulk) { try { $index = Get-PackageUpdateIndex -Installers $bulk } catch { Write-Verbose "Get-InstalledPackageMap: $($_.Exception.Message)" } }
    $scoopList = $null
    if ('scoop' -in $wanted -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
        # 6>$null: scoop prints an "Installed apps:" banner to the host.
        try { $scoopList = & scoop list 2>$null 6>$null | Out-String } catch { $scoopList = $null }
    }
    $npmList = $null
    if ('npmGlobal' -in $wanted -and (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        try { $npmList = & npm.cmd list -g --depth=0 2>$null | Out-String } catch { $npmList = $null }
    }

    $map = @{}
    foreach ($id in $nodes.Keys) {
        $n = $nodes[$id]
        $installer = & $installerOf $n
        $map[$id] = switch ($installer) {
            { $_ -in 'winget', 'choco', 'dotnetTool' } {
                if (-not $index.ContainsKey($installer)) { $false; break }   # engine absent: nothing installed by it
                (Resolve-PackageVersionInfo -Package $n.Package -Index $index).Present
            }
            'scoop' {
                # Chocolatey is usually installed by the bootstrap, not by scoop
                # (#559): choco on PATH is what counts.
                if ($n.Kind -eq 'Manifest' -and $n.Name -eq 'Chocolatey') { [bool](Get-Command choco -ErrorAction SilentlyContinue); break }
                if ($null -eq $scoopList) { $null; break }
                $app = if ($n.Kind -eq 'Manifest') { $n.Name } else { ($n.Package.Id -split '/')[-1] }
                $scoopList -match "(?im)^\s*$([regex]::Escape($app))\s+\S+"
            }
            'npmGlobal' {
                if ($null -eq $npmList) { $false; break }
                $npmList -match "(?im)^\S+\s+$([regex]::Escape($n.Package.Id))@"
            }
            default { (Get-PackagePresence -Package $n.Package).Present }
        }
    }
    $map
}
