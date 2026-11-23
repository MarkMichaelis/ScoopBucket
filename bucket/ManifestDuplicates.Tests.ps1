#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# A bare manifest that no bundle uses must not winget-install a package a
# bundle already declares (#550). Such a manifest is a second way to install
# the same thing, so the package picker (#543) lists it twice and a machine can
# end up with it installed under two names. Claude.json duplicated AIAgents'
# Claude Desktop (Anthropic.Claude) this way.
#
# A manifest a bundle installs through ('MarkMichaelis/<manifest>') is that
# bundle's package, not a stray copy, so it is out of scope here; two bundles
# carrying the same CLI under different engines is tracked separately.

BeforeAll {
    $script:psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:packages = @(Get-Package -BucketPath $PSScriptRoot)
}

Describe 'Bare manifests do not duplicate bundle packages (#550)' -Tag 'Light' {
    It 'no unused bare manifest winget-installs a package that a bundle declares' {
        $declared = @{}
        foreach ($p in $script:packages | Where-Object { $_.Installer -eq 'winget' -and $_.Id }) {
            $declared[$p.Id] = "$($p.Bundle)/$($p.Name)"
        }
        $bundles = @($script:packages.Bundle | Sort-Object -Unique)
        $usedByBundle = @($script:packages | Where-Object { $_.Installer -eq 'scoop' -and $_.Id -match '^MarkMichaelis/' } |
                ForEach-Object { ($_.Id -split '/')[-1] })

        $duplicates = foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.json' -Recurse -File) {
            if ($file.BaseName -in $bundles -or $file.BaseName -in $usedByBundle) { continue }
            $manifest = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            $script = @($manifest.installer.script) -join "`n"
            foreach ($m in [regex]::Matches($script, '(?i)\bwinget(?:\.exe)?\s+(?:install|upgrade)\b[^;|\r\n]*?--id\s+([^\s;|]+)')) {
                $id = $m.Groups[1].Value.Trim('"', "'")
                if ($declared.ContainsKey($id)) { "$($file.Name) installs $id, which $($declared[$id]) already declares" }
            }
        }
        $duplicates | Should -BeNullOrEmpty
    }
}
