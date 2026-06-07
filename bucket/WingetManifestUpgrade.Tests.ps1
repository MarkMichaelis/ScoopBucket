#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# #339: scoop manifests that wrap winget must invoke `winget upgrade`, not
# just `winget install`. `winget install` on an already-installed package is
# idempotent (returns "Package already installed") and never moves the
# package to a newer version. Combined with scoop only re-running the
# installer when the manifest version bumps, install-only manifests leave
# users stuck on whatever winget version was current when the manifest last
# bumped -- exactly the bug reported on PowerShellCore (pwsh 7.4 not
# advancing to 7.6 despite `scoop update powershellcore`).
#
# This guard scans every JSON manifest in bucket/** and asserts: if the
# installer script invokes `winget install --id <ID>`, it must also invoke
# `winget upgrade --id <ID>` for the same id (typically via an if/else that
# upgrades when present, installs when missing). Tagged 'Light' -- parses
# manifest JSON only; no install side effects.
# ----------------------------------------------------------------------------

BeforeDiscovery {
    $bucketRoot = Join-Path $PSScriptRoot ''
    $script:WingetManifestCases = @(
        Get-ChildItem -Path $bucketRoot -Filter '*.json' -Recurse -File |
            ForEach-Object {
                try {
                    $manifest = Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
                } catch { return }
                $scriptText = @($manifest.installer.script) -join "`n"
                $installMatches = [regex]::Matches($scriptText, '(?i)winget\s+install\b[^\r\n]*?--id\s+([A-Za-z0-9._-]+)')
                foreach ($m in $installMatches) {
                    @{
                        Manifest = $_.FullName.Substring($bucketRoot.Length).TrimStart('\','/')
                        Id       = $m.Groups[1].Value
                        Script   = $scriptText
                    }
                }
            }
    )
}

Describe 'winget-based manifests must invoke winget upgrade (#339)' -Tag 'Light' {
    It "<Manifest> invokes 'winget upgrade --id <Id>' so re-runs actually upgrade" -ForEach $script:WingetManifestCases {
        $pattern = '(?i)winget\s+upgrade\b[^\r\n]*--id\s+' + [regex]::Escape($Id) + '\b'
        $Script | Should -Match $pattern `
            -Because "winget install --id $Id is idempotent when the package is present; only winget upgrade moves it to a newer version"
    }
}
