#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester coverage for Update-PackageConfig -- the on-demand "re-apply package
# configuration" command. It walks declarative bundles, reconstructs the real
# [Package] objects (ConfigScript scriptblocks intact) via the harvest path,
# and re-runs each ConfigScript idempotently. This is the clean entry point for
# the user's original "refresh the MCP servers" request:
#   Update-PackageConfig AIAgents

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psd1     = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force

    function script:New-ConfigBucket {
        # Build a throwaway bucket with two bundles:
        #   Alpha  -- one package with a ConfigScript that appends to a sentinel.
        #   Bravo  -- one package with a ConfigScript that appends to a sentinel,
        #             plus one package with NO ConfigScript.
        $bucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-cfg-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $bucket | Out-Null
        $sentinel = Join-Path $bucket 'config-ran.log'

        $psd1Lit = $script:psd1 -replace "'", "''"
        $senLit  = $sentinel -replace "'", "''"

        $alpha = @"
`$scoopBucketPsd1 = '$psd1Lit'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{
        Name = 'alpha'; Installer = 'winget'; Id = 'Test.Alpha'
        ConfigScript = { Add-Content -LiteralPath '$senLit' -Value "alpha:`$(`$args[0].Name)" }
    }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'Alpha'
"@
        Set-Content -LiteralPath (Join-Path $bucket 'Alpha.ps1') -Value $alpha -Encoding UTF8

        $bravo = @"
`$scoopBucketPsd1 = '$psd1Lit'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{
        Name = 'bravo'; Installer = 'winget'; Id = 'Test.Bravo'
        ConfigScript = { Add-Content -LiteralPath '$senLit' -Value 'bravo' }
    }
    [Package]@{ Name = 'charlie'; Installer = 'winget'; Id = 'Test.Charlie' }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'Bravo'
"@
        Set-Content -LiteralPath (Join-Path $bucket 'Bravo.ps1') -Value $bravo -Encoding UTF8

        foreach ($name in 'Alpha', 'Bravo') {
            $manifest = @{
                '$schema' = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
                version   = '1.00.000'
                url       = @('https://example.invalid/test')
                installer = @{ script = @("& `"`$dir\$name.ps1`"") }
            }
            Set-Content -LiteralPath (Join-Path $bucket "$name.json") `
                -Value ($manifest | ConvertTo-Json -Depth 4) -Encoding UTF8
        }

        [pscustomobject]@{ Bucket = $bucket; Sentinel = $sentinel }
    }
}

Describe 'Update-PackageConfig' -Tag 'Light', 'Module' {

    It 'is exported by the module' {
        Get-Command Update-PackageConfig -Module MarkMichaelis.ScoopBucket | Should -Not -BeNullOrEmpty
    }

    It 'runs the ConfigScript for a named bundle and passes the [Package]' {
        $env = script:New-ConfigBucket
        try {
            $null = Update-PackageConfig -Name 'Alpha' -BucketPath $env.Bucket
            Test-Path -LiteralPath $env.Sentinel | Should -BeTrue
            (Get-Content -LiteralPath $env.Sentinel -Raw) | Should -Match 'alpha:alpha'
        } finally {
            Remove-Item -LiteralPath $env.Bucket -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'runs every ConfigScript across all bundles when no name is given' {
        $env = script:New-ConfigBucket
        try {
            $null = Update-PackageConfig -BucketPath $env.Bucket
            $content = Get-Content -LiteralPath $env.Sentinel -Raw
            $content | Should -Match 'alpha:alpha'
            $content | Should -Match 'bravo'
        } finally {
            Remove-Item -LiteralPath $env.Bucket -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'does not run other bundles ConfigScripts when a single bundle is named' {
        $env = script:New-ConfigBucket
        try {
            $null = Update-PackageConfig -Name 'Bravo' -BucketPath $env.Bucket
            $content = Get-Content -LiteralPath $env.Sentinel -Raw
            $content | Should -Match 'bravo'
            $content | Should -Not -Match 'alpha'
        } finally {
            Remove-Item -LiteralPath $env.Bucket -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'under -WhatIf does not invoke any ConfigScript' {
        $env = script:New-ConfigBucket
        try {
            $null = Update-PackageConfig -BucketPath $env.Bucket -WhatIf
            Test-Path -LiteralPath $env.Sentinel | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $env.Bucket -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'emits a result row only for packages that declare a ConfigScript' {
        $env = script:New-ConfigBucket
        try {
            $rows = @(Update-PackageConfig -BucketPath $env.Bucket)
            $rows.Package | Should -Contain 'alpha'
            $rows.Package | Should -Contain 'bravo'
            $rows.Package | Should -Not -Contain 'charlie'
        } finally {
            Remove-Item -LiteralPath $env.Bucket -Recurse -Force -ErrorAction Ignore
        }
    }
}
