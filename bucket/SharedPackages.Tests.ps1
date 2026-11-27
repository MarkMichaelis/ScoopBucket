#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Each package a bundle installs is declared once (#563).

.DESCRIPTION
    A package that two bundles install (VS Code, Git, GitHub Copilot CLI,
    Node.js, Playwright) is declared in bucket\SharedPackages.ps1 and
    included by each bundle. Two copies drift; Update-Package and
    Uninstall-Package resolve a name to the FIRST bundle declaring it, so a
    drifted copy changes behavior with name order.

    Scope: the bundles Install-Package installs -- every bundle at the bucket
    root and every bundle another bundle links to ('MarkMichaelis/<bundle>').
    A standalone member bundle that no bundle links (ai\ChatGPT.ps1) is its own
    scoop manifest, never installed alongside the bundle that also declares
    its package, so it is not a second copy in any install.
#>

BeforeDiscovery {
    $bucket = $PSScriptRoot
    $scripts = @(Get-ChildItem -LiteralPath $bucket -Filter '*.ps1' -File -Recurse |
            Where-Object { $_.Name -notmatch '\.Tests\.ps1$' })

    function Get-DeclaredPackage([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                $n.Type.TypeName.Name -eq 'Package' -and
                $n.Child -is [System.Management.Automation.Language.HashtableAst]
            }, $true) | ForEach-Object {
            $fields = @{}
            foreach ($pair in $_.Child.KeyValuePairs) {
                $value = $pair.Item2.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
                if ($value) { $fields[$pair.Item1.Extent.Text] = $value.Value }
            }
            if ($fields.Id) { [pscustomobject]@{ Installer = $fields.Installer; Id = $fields.Id } }
        }
    }

    $bundles = @{}
    foreach ($s in $scripts) {
        if ((Get-Content -Raw -LiteralPath $s.FullName) -match '(?m)^\s*Invoke-PackageInstall\b') {
            $bundles[$s.BaseName] = [pscustomobject]@{ File = $s; Packages = @(Get-DeclaredPackage $s.FullName) }
        }
    }
    $linked = @($bundles.Values | ForEach-Object { $_.Packages } |
            Where-Object { $_.Installer -eq 'scoop' -and $_.Id -match '^MarkMichaelis/(?<t>[^/]+)$' } |
            ForEach-Object { $_.Id.Split('/')[1] })
    $installed = @($bundles.GetEnumerator() | Where-Object {
            $_.Value.File.DirectoryName -eq $bucket -or $linked -contains $_.Key
        } | ForEach-Object { $_.Value.File })
    $declaring = @($installed) + @(Get-Item -LiteralPath (Join-Path $bucket 'SharedPackages.ps1'))

    $byKey = @{}
    foreach ($file in $declaring) {
        foreach ($p in @(Get-DeclaredPackage $file.FullName)) {
            $key = "$($p.Installer)|$($p.Id)"
            if (-not $byKey.ContainsKey($key)) { $byKey[$key] = [System.Collections.Generic.List[string]]::new() }
            if (-not $byKey[$key].Contains($file.Name)) { $byKey[$key].Add($file.Name) }
        }
    }
    $script:Keys = @($byKey.GetEnumerator() | Sort-Object Key | ForEach-Object { @{ Key = $_.Key; Files = @($_.Value) } })
}

Describe 'Each installed package is declared in one file (#563)' -Tag 'Light', 'Bundle' {
    It 'finds declarations to check' -ForEach @(@{ Count = $script:Keys.Count }) {
        $Count | Should -BeGreaterThan 50
    }

    It '<Key> is declared once' -ForEach $script:Keys {
        $Files | Should -HaveCount 1 -Because "declare it once in SharedPackages.ps1 and include that group from each bundle (declared in: $($Files -join ', '))"
    }
}

Describe 'SharedPackages.ps1' -Tag 'Light', 'Bundle' {
    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        Import-Module $scoopBucketPsd1 -Force
        $script:Shared = Join-Path $PSScriptRoot 'SharedPackages.ps1'
    }

    It 'returns a group with the companions it names' {
        $git = @(& $script:Shared -Name 'Git')
        $main = $git | Where-Object Name -eq 'Git'
        $main.Required | Should -BeTrue
        foreach ($c in $main.Companions) { $git.Name | Should -Contain $c }
    }

    It 'refuses a group it does not have, naming the ones it does' {
        { & $script:Shared -Name 'Nope' } | Should -Throw '*Known groups:*Git*'
    }

    It 'is shipped by every manifest whose bundle includes it' {
        $bundleFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
            Where-Object { $_.Name -notmatch '\.Tests\.ps1$' -and (Get-Content -Raw -LiteralPath $_.FullName) -match '(?m)^\s*& "\$PSScriptRoot\\SharedPackages\.ps1"' }
        $bundleFiles | Should -Not -BeNullOrEmpty
        foreach ($f in $bundleFiles) {
            $manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "$($f.BaseName).json") | ConvertFrom-Json
            @($manifest.url) -match '/bucket/SharedPackages\.ps1$' | Should -Not -BeNullOrEmpty -Because "$($f.BaseName).json must ship SharedPackages.ps1 for scoop installs"
        }
    }
}
