function Get-BundlePackageObjects {
    <#
    .SYNOPSIS
        Internal: dot-source a bundle .ps1 in-process and return the
        real $Packages collection (with scriptblocks intact).
    .DESCRIPTION
        Used by Uninstall-Package when it needs the actual [Package]
        instances (and their CustomUninstallScript scriptblocks), not
        just the metadata Get-BundlePackages returns.

        Strips the bundle's terminal `Invoke-PackageInstall -Packages …`
        line so the act of loading the bundle doesn't trigger a real
        install, then evaluates the remainder via [scriptblock]::Create
        in the current scope so `$Packages` is assigned and `[Package]`
        casts resolve against the already-loaded module.

        Bundle scripts that do not assign $Packages (legacy imperative
        bundles) return an empty array.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BundlePath)

    if (-not (Test-Path $BundlePath)) {
        Write-Verbose "Get-BundlePackageObjects: '$BundlePath' not found."
        return @()
    }

    $bundleText = Get-Content -Raw -LiteralPath $BundlePath -ErrorAction SilentlyContinue
    if (-not $bundleText) { return @() }
    if ($bundleText -notmatch '(?m)^\s*Invoke-PackageInstall\b') { return @() }

    $stripped = $bundleText -replace "(?ms)^\s*\`$scoopBucketPsd1\s*=.*?Import-Module\s+MarkMichaelis\.ScoopBucket\s+-Force\s*\}\s*", ''
    $stripped = $stripped -replace "(?m)^\s*Invoke-PackageInstall\s+-Packages\s+\`$Packages\s+-Bundle\s+'[^']+'\s*`$", ''

    $Packages = $null
    try {
        . ([scriptblock]::Create($stripped))
    } catch {
        # A throw here (as opposed to a bundle that simply never assigns
        # $Packages) means the bundle body referenced something that failed to
        # evaluate -- most commonly a STALE cached [Package] class. PowerShell
        # caches a class by name per session, so when an older module version is
        # already loaded and a newer one is Import-Module -Force'd over it, the
        # cached [Package] is NOT redefined; bundle casts to a newer property
        # then throw. The caller falls back to metadata-only packages, which
        # strips every scriptblock (CustomInstallScript / VerifyScript / etc.),
        # silently degrading custom + Reinstall packages. Surface it as a warning
        # so that degradation is visible and explained instead of nondeterministic.
        $bundleName = [System.IO.Path]::GetFileNameWithoutExtension($BundlePath)
        Write-Warning ("Get-BundlePackageObjects: bundle '{0}' failed to reconstruct its [Package] objects ({1}). Falling back to metadata-only packages -- custom/Reinstall scriptblocks are unavailable this session. This usually means a stale [Package] type from a prior module load; start a fresh PowerShell session to clear it." -f $bundleName, $_.Exception.Message)
        return @()
    }

    if ($null -eq $Packages) { return @() }
    # Emit each package to the pipeline; caller wraps with @(...) to
    # collect. Returning `,$Packages` would create an extra wrapping
    # level the caller can't easily strip.
    return $Packages
}
