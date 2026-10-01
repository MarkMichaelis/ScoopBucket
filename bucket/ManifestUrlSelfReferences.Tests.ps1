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

    Also verifies the inverse: every sibling .ps1 an installer script
    dot-sources via $PSScriptRoot must be listed in its manifest's `url`
    array, or it is simply absent from the scoop app dir at install time.
    See #265, #431.
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

    # The inverse check (#431): an installer script that dot-sources a sibling
    # .ps1 via $PSScriptRoot only works if scoop actually downloaded that
    # sibling, i.e. the manifest lists it in `url` too. Unlike a committed
    # .jsonc snapshot -- which the module's import cmdlets can fall back to
    # resolving from the bucket checkout -- a dot-sourced helper script has no
    # fallback: the dot-source throws and the install dies. scoop lands `url`
    # entries FLAT in $dir, which is exactly where a $PSScriptRoot-relative
    # sibling path looks, so listing it is the whole fix.
    $script:SiblingCases = @()
    Get-ChildItem -Path $script:BucketRoot -Filter '*.ps1' -File -Recurse |
        Where-Object { $_.Name -notlike '*.Tests.ps1' } | ForEach-Object {
            $scriptPath = $_.FullName
            $manifestPath = [System.IO.Path]::ChangeExtension($scriptPath, '.json')
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
            try { $json = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json } catch { return }
            $urls = @(@($json.url) | Where-Object { $_ -is [string] })

            $text = Get-Content -Raw -LiteralPath $scriptPath
            foreach ($match in [regex]::Matches($text, "PSScriptRoot\s+'(?<sib>[^']+\.ps1)'")) {
                $sibling = $match.Groups['sib'].Value
                if ($sibling -eq $_.Name) { continue }
                $script:SiblingCases += [pscustomobject]@{
                    Script   = $_.Name
                    Manifest = [System.IO.Path]::GetFileName($manifestPath)
                    Sibling  = $sibling
                    Urls     = $urls
                }
            }
        }
    $script:SiblingCases = @($script:SiblingCases | Sort-Object Script, Sibling -Unique)
}

Describe 'Manifest self-referencing URLs resolve to files in the repo' -Tag 'Light' {
    It 'manifest <_.Manifest> references existing local path <_.LocalPath>' -ForEach $script:UrlCases {
        Test-Path -LiteralPath $_.LocalPath -PathType Leaf | Should -BeTrue -Because "URL $($_.Url) would 404 at scoop install/update time"
    }
}

Describe 'Dot-sourced sibling scripts are shipped by their manifest' -Tag 'Light' {
    It '<_.Manifest> ships <_.Sibling>, dot-sourced by <_.Script>' -ForEach $script:SiblingCases {
        $sibling = $_.Sibling
        ($_.Urls | Where-Object { $_.EndsWith("/$sibling", [System.StringComparison]::OrdinalIgnoreCase) }) |
            Should -Not -BeNullOrEmpty -Because "$($_.Script) dot-sources $sibling from `$PSScriptRoot, but $($_.Manifest) does not list it in url[] -- so scoop never downloads it into the app dir and the install dies there (#431)"
    }
}
