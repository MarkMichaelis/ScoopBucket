<#
.SYNOPSIS
    Phase 1 enabler regression coverage for the grouped bucket layout (#302, #300).

.DESCRIPTION
    The bucket reorg files member manifests/bundles into category subfolders
    (os/ client/ developer/ ai/ + admin/). Two engine behaviors must keep
    working once files are no longer flat in bucket/:

      * Get-BundlePackages must discover a bundle that lives in a SUBFOLDER
        (it globs bucket/*.ps1 -- the glob must be -Recurse).
      * A bundle discovered from a subfolder must still surface its companion
        package + completion metadata, so a member like "Everything" still
        auto-installs its companion CLI and registers completions after it is
        moved into os/.

    The module loader (MarkMichaelis.ScoopBucket.psm1) must also stop
    dot-sourcing *.Tests.ps1 from Public/Private/Classes, so that module tests
    can be co-located beside the code they exercise without being loaded at
    import time.

    Each test fails for a behavioral reason (missing bundle / missing metadata /
    leaked sentinel function) when the corresponding -Recurse / *.Tests.ps1
    skip is reverted.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    function script:Invoke-GetBundlePackages {
        param([string]$BucketPath)
        & (Get-Module MarkMichaelis.ScoopBucket) {
            param($p) Get-BundlePackages -BucketPath $p
        } $BucketPath
    }
}

Describe 'Get-BundlePackages foldered discovery' -Tag 'Light', 'Module' {

    BeforeAll {
        # A migrated declarative bundle nested one level deep inside the bucket.
        $script:groupDir = Join-Path $TestDrive 'os'
        New-Item -ItemType Directory -Path $script:groupDir -Force | Out-Null
        $script:bundlePath = Join-Path $script:groupDir 'Widget.ps1'
        Set-Content -LiteralPath $script:bundlePath -Encoding utf8 -Value @'
$Packages = [Package[]]@(
    [Package]@{
        Name                = 'Widget'
        Installer           = 'winget'
        Id                  = 'Acme.Widget'
        Companions          = @('Acme.Widget.Cli')
        ExpectedCompletions = @{ widget = @('--help', '--version') }
    }
)
Invoke-PackageInstall -Packages $Packages -Bundle 'Widget'
'@
        $script:result = @(script:Invoke-GetBundlePackages -BucketPath $TestDrive)
        $script:widget = $script:result | Where-Object { $_.Bundle -eq 'Widget' }
    }

    It 'discovers a bundle that lives in a bucket subfolder' {
        $script:widget | Should -Not -BeNullOrEmpty
        @($script:widget.Packages).Count | Should -Be 1
        $script:widget.Packages[0].Name | Should -Be 'Widget'
    }

    It 'preserves the companion package + completion metadata of a foldered bundle' {
        $pkg = $script:widget.Packages[0]
        @($pkg.Companions) | Should -Contain 'Acme.Widget.Cli'
        $pkg.ExpectedCompletions.widget | Should -Contain '--help'
    }
}

Describe 'Module loader skips co-located *.Tests.ps1' -Tag 'Light', 'Module' {

    It 'does not dot-source a *.Tests.ps1 dropped into Public/ at import' {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $script:moduleManifest)
        $sourceDir = Join-Path $moduleRoot 'MarkMichaelis.ScoopBucket'
        $copyRoot = Join-Path $TestDrive 'ModuleCopy'
        Copy-Item -Path $sourceDir -Destination $copyRoot -Recurse -Force

        $sentinelName = 'SBLoaderSentinel_' + [guid]::NewGuid().ToString('N')
        $sentinel = Join-Path (Join-Path $copyRoot 'Public') 'ZzzLoader.Tests.ps1'
        Set-Content -LiteralPath $sentinel -Encoding utf8 -Value "function global:$sentinelName { 'loaded' }"

        try {
            Import-Module (Join-Path $copyRoot 'MarkMichaelis.ScoopBucket.psd1') -Force
            Get-Command $sentinelName -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty -Because 'a *.Tests.ps1 file in Public/ must not be dot-sourced at module import'
        }
        finally {
            Remove-Item "Function:\$sentinelName" -ErrorAction SilentlyContinue
            Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction SilentlyContinue
            Import-Module $script:moduleManifest -Force
        }
    }
}
