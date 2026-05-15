function Get-PackageNameSuggestion {
    <#
    .SYNOPSIS
        Internal: fast, cached lookup of every declared package name across
        the bucket — designed for argument-completer hot path.

    .DESCRIPTION
        Tab completion has to run in the user's interactive session and
        return suggestions in well under a second. Get-BundlePackages
        spawns one child pwsh per bundle (~22 right now) and takes tens
        of seconds end-to-end — far too slow for a Tab keypress. This
        helper instead does a regex scan over `bucket/*.ps1` source text
        looking for `Name = '...'` (or `Name = "..."`) assignments inside
        `[Package]@{ ... }` literals. Results are cached at module scope,
        keyed by the latest mtime across bundle scripts so edits during
        a session invalidate the cache automatically.

    .PARAMETER WordToComplete
        Prefix the user has typed; matching is case-insensitive on either
        a prefix OR a substring (so "compare" finds "Beyond Compare").

    .PARAMETER BucketPath
        Override the auto-detected bucket directory.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [string]$WordToComplete = '',
        [string]$BucketPath
    )

    if (-not $BucketPath) {
        $BucketPath = Resolve-BucketPath -BucketPath $BucketPath -CallerScriptRoot $PSScriptRoot
    }

    if (-not $BucketPath -or -not (Test-Path $BucketPath)) {
        return @()
    }

    $bundleFiles = Get-ChildItem -Path $BucketPath -Filter '*.ps1' -File |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
        Where-Object { $_.Name -ne 'Utils.ps1' -and $_.Name -ne 'Invoke-Tests.ps1' }

    if (-not $bundleFiles) { return @() }

    $latestMtimeTicks = ($bundleFiles | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum.Ticks
    $cacheKey = "$BucketPath|$latestMtimeTicks"

    if ($script:PackageNameCacheKey -ne $cacheKey) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # Match `Name = 'value'` or `Name = "value"`. We intentionally
        # don't try to scope to the inside of a [Package]@{...} literal —
        # the only place `Name = '...'` appears in bundles in practice
        # is inside Package literals; any false positives would just be
        # ignored by Install-Package's strict name match at run time.
        $rx = [regex]'(?m)^\s*Name\s*=\s*[''"]([^''"]+)[''"]'
        foreach ($f in $bundleFiles) {
            $text = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            foreach ($m in $rx.Matches($text)) {
                $null = $names.Add($m.Groups[1].Value)
            }
        }
        $script:PackageNameCache = @($names) | Sort-Object
        $script:PackageNameCacheKey = $cacheKey
    }

    $all = $script:PackageNameCache
    if (-not $WordToComplete) { return $all }

    $w = $WordToComplete.Trim("'", '"')
    $prefix = $all | Where-Object { $_ -like "$w*" }
    $substring = $all | Where-Object { $_ -like "*$w*" -and $_ -notin $prefix }
    return @($prefix) + @($substring)
}
