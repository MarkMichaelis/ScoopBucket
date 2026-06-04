#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Verifies that every bucket/*.json `url` referring to a file in *this*
    repository points at a path that actually exists on disk.

.DESCRIPTION
    Some no-op manifests (e.g. wrappers around installs handled by Windows
    itself or by winget) still need a `url` field because Scoop requires
    one. Those URLs typically point at a tiny placeholder file checked into
    this bucket via raw.githubusercontent.com. If the placeholder is later
    deleted as "unreferenced" (filename greps miss URL strings), the
    manifests silently break with a 404 at `scoop update` time.

    See #265.
#>

BeforeDiscovery {
    $script:BucketRoot = $PSScriptRoot
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    $script:SelfRefPrefix = 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/'

    $script:UrlCases = @()
    Get-ChildItem -Path $script:BucketRoot -Filter '*.json' -File -Recurse | ForEach-Object {
        $manifestPath = $_.FullName
        $manifestName = $_.BaseName
        try {
            $json = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        }
        catch {
            return
        }
        $urls = @($json.url) | Where-Object { $_ -is [string] }
        foreach ($u in $urls) {
            if ($u.StartsWith($script:SelfRefPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $u.Substring($script:SelfRefPrefix.Length)
                $script:UrlCases += [pscustomobject]@{
                    Manifest = $manifestName
                    Url      = $u
                    LocalPath = (Join-Path $script:RepoRoot $relative)
                }
            }
        }
    }
}

Describe 'Manifest self-referencing URLs resolve to files in the repo' -Tag 'Light' {
    It 'manifest <_.Manifest> references existing local path <_.LocalPath>' -ForEach $script:UrlCases {
        Test-Path -LiteralPath $_.LocalPath -PathType Leaf | Should -BeTrue -Because "URL $($_.Url) would 404 at scoop install/update time"
    }
}
