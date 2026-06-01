function Get-BundlePackageObjects {
    <#
    .SYNOPSIS
        Internal: return a bundle's real $Packages collection (with
        scriptblocks intact) WITHOUT running the bundle's imperative body.
    .DESCRIPTION
        Update-Package / Uninstall-Package need the actual [Package] instances
        and their live scriptblocks (CustomInstallScript / CustomUninstallScript
        / VerifyScript), not just the metadata Get-BundlePackages returns.

        A bundle .ps1 is NOT purely declarative: besides the
        `$Packages = [Package[]]@(...)` array it can carry heavy imperative
        configuration (MCP server installs, profile edits, dotnet/npm tool
        installs, etc.) that runs top-to-bottom during a real
        `Invoke-PackageInstall`. Dot-sourcing the whole bundle just to harvest
        $Packages would (re)execute all of that as a side effect of an UPDATE or
        UNINSTALL -- clearly wrong. So instead of running the bundle, we locate
        the `$Packages` assignment via the AST and evaluate ONLY that
        expression. `[Package]` casts resolve against the already-loaded module
        and the per-package scriptblocks stay intact (and unexecuted --
        scriptblock literals are not invoked by the assignment).

        $PSScriptRoot / $PSCommandPath are seeded for the assignment scope so a
        package hashtable that references a $PSScriptRoot-relative path resolves
        the same way it would from disk.

        Bundles that do not assign $Packages (legacy imperative bundles) return
        an empty array, quietly. If the $Packages assignment exists but fails to
        evaluate (e.g. a stale cached [Package] type missing a newer member) a
        warning is emitted so the resulting fall back to metadata-only packages
        -- which strips every scriptblock -- is visible rather than a silent,
        nondeterministic degradation.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BundlePath)

    if (-not (Test-Path $BundlePath)) {
        Write-Verbose "Get-BundlePackageObjects: '$BundlePath' not found."
        return @()
    }

    $fullPath  = (Resolve-Path -LiteralPath $BundlePath).Path
    $bundleDir = Split-Path -Parent $fullPath

    $tokens = $null; $parseErrors = $null
    $bundleAst = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) {
        $bundleName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
        Write-Warning ("Get-BundlePackageObjects: bundle '{0}' has parse errors ({1}); falling back to metadata-only packages." -f $bundleName, ($parseErrors[0].Message))
        return @()
    }

    # Find the top-level `$Packages = ...` assignment. Everything else in the
    # bundle (the imperative install/config body) is deliberately ignored so a
    # harvest never re-runs the bundle's install side effects.
    $assign = $bundleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'Packages'
        }, $true)

    if (-not $assign) {
        # Legacy imperative bundle with no declarative $Packages -- legitimate
        # empty result, not an error.
        return @()
    }

    # Seed $PSScriptRoot/$PSCommandPath for the assignment scope (a scriptblock
    # built with ::Create has no source file, so the automatic versions are
    # empty -- and an empty automatic shadows any caller-set local). These prefix
    # the extracted assignment ONLY; no bundle imperative code is included, so
    # nothing with side effects can run.
    $rootLiteral = $bundleDir -replace "'", "''"
    $pathLiteral = $fullPath  -replace "'", "''"
    $evalText = "`$PSScriptRoot = '$rootLiteral'`n`$PSCommandPath = '$pathLiteral'`n" + $assign.Extent.Text

    $Packages = $null
    try {
        . ([scriptblock]::Create($evalText))
    } catch {
        # The $Packages declaration exists but would not evaluate. Most common
        # cause is a STALE cached [Package] class: PowerShell keys a class by
        # name per session, so when an older module version auto-loaded first and
        # a newer one is Import-Module -Force'd over it, the cached [Package] is
        # NOT redefined and a cast to a newer member throws. Surface it so the
        # fall back to metadata-only packages (which strips every scriptblock and
        # degrades custom/Reinstall packages) is visible and explained.
        $bundleName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
        Write-Warning ("Get-BundlePackageObjects: bundle '{0}' declares `$Packages but it failed to evaluate ({1}). Falling back to metadata-only packages -- custom/Reinstall scriptblocks are unavailable this session. This usually means a stale [Package] type from a prior module load; start a fresh PowerShell session to clear it." -f $bundleName, $_.Exception.Message)
        return @()
    }

    if ($null -eq $Packages) { return @() }
    # Emit each package to the pipeline; caller wraps with @(...) to collect.
    return $Packages
}
