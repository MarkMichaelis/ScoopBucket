#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Guards that every *.json directly in bucket/ is a valid Scoop manifest
    with a non-empty top-level `version`.

.DESCRIPTION
    Scoop treats every bucket/*.json as an app manifest and reads its version
    via the non-Try overload `$json.RootElement.GetProperty('version')`
    (scoop-search.ps1). A version-less data/snapshot file checked into
    bucket/ therefore makes `scoop search` (and the module `scoop` wrapper's
    bare-name install resolution) throw:

        Exception calling "GetProperty" with "1" argument(s):
        "The given key was not present in the dictionary."

    See #295. Data/snapshot files must live outside bucket/.
#>

BeforeDiscovery {
    $script:BucketRoot = $PSScriptRoot
    $script:ManifestCases = @(
        Get-ChildItem -Path $script:BucketRoot -Filter '*.json' -File -Recurse | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Path = $_.FullName
            }
        }
    )
}

Describe 'Every bucket/*.json is a version-bearing Scoop manifest' -Tag 'Light' {
    It '<_.Name> declares a non-empty top-level version' -ForEach $script:ManifestCases {
        $json = Get-Content -Raw -LiteralPath $_.Path | ConvertFrom-Json
        $json.PSObject.Properties.Name | Should -Contain 'version' -Because "Scoop reads bucket/*.json as a manifest; data/snapshot files belong outside bucket/ (see #295)"
        [string]$json.version | Should -Not -BeNullOrEmpty -Because "a manifest version must be non-empty"
    }

    It '<_.Name> survives Scoop''s GetProperty(''version'') manifest read' -ForEach $script:ManifestCases {
        # Emulates scoop-search.ps1: $json.RootElement.GetProperty('version').
        # A version-less file throws "The given key was not present in the
        # dictionary." here -- the exact crash that breaks the wrapper search.
        $raw = Get-Content -Raw -LiteralPath $_.Path
        $doc = [System.Text.Json.JsonDocument]::Parse($raw)
        try {
            { $doc.RootElement.GetProperty('version') } | Should -Not -Throw -Because "scoop search enumerates this file and reads version the same way (see #295)"
        }
        finally {
            $doc.Dispose()
        }
    }
}
