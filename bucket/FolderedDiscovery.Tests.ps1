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

Describe 'Bare manifest resolution across bucket subfolders' -Tag 'Light', 'Module' {

    BeforeAll {
        # A config-only manifest: it lives in a category subfolder, has no
        # sibling .ps1 and therefore no [Package[]] declaration at all. Every
        # real config-only manifest has exactly this shape after the reorg --
        # GitConfigure (developer/), EnableRemoteDesktop (os/),
        # McAfeeUninstall (os/), ... -- and dispatch case (c) in
        # Install-/Uninstall-/Update-Package is the only path that can reach
        # them. That case probed `<bucket>\<name>.json` only, so every one of
        # them became unreachable by name once it moved into a subfolder (#452).
        $script:folderedBucket = Join-Path $TestDrive 'FolderedBucket'
        $script:categoryDir = Join-Path $script:folderedBucket 'developer'
        New-Item -ItemType Directory -Path $script:categoryDir -Force | Out-Null
        $script:manifestName = 'WidgetConfigure'
        $manifestJson = @{
            version   = '1.00.000'
            url       = @('https://example.invalid/widget-configure')
            installer = @{ script = @('Write-Host "configure"') }
        } | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath (Join-Path $script:categoryDir "$($script:manifestName).json") `
            -Value $manifestJson -Encoding utf8
    }

    It 'Install-Package resolves a bare manifest that lives in a subfolder' {
        # -DryRun keeps the ShouldProcess gate closed, so nothing is installed;
        # the behavior under test is purely name -> manifest resolution.
        { Install-Package -Name $script:manifestName -BucketPath $script:folderedBucket `
                -DryRun -SkipCompletion -ErrorAction Stop } |
            Should -Not -Throw
    }

    It 'Uninstall-Package resolves a bare manifest that lives in a subfolder' {
        $result = @(Uninstall-Package -Name $script:manifestName `
                -BucketPath $script:folderedBucket -DryRun -SkipCompletion)

        $result.Count     | Should -Be 1
        $result[0].Name   | Should -Be $script:manifestName
        $result[0].Status | Should -Be 'Skipped'
    }

    It 'Update-Package resolves a bare manifest that lives in a subfolder' {
        { Update-Package -Name $script:manifestName -BucketPath $script:folderedBucket `
                -DryRun -SkipCompletion -SkipBucketRefresh -WarningAction SilentlyContinue `
                -ErrorAction Stop } |
            Should -Not -Throw
    }

    It 'still rejects a name that neither a bundle nor any manifest declares' {
        # Guard against "fixing" resolution by making it match anything.
        { Install-Package -Name 'NoSuchWidgetAnywhere' -BucketPath $script:folderedBucket `
                -DryRun -SkipCompletion -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*no bundle declares a package named*'
    }
}

Describe 'Resolve-BucketManifestPath' -Tag 'Light', 'Module' {

    BeforeAll {
        function script:Invoke-ResolveBucketManifestPath {
            param([string]$Name, [string]$BucketPath)
            & (Get-Module MarkMichaelis.ScoopBucket) {
                param($n, $p) Resolve-BucketManifestPath -Name $n -BucketPath $p
            } $Name $BucketPath
        }

        function script:New-Manifest {
            param([Parameter(Mandatory)][string]$Path)
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            Set-Content -LiteralPath $Path -Encoding utf8 -Value '{ "version": "1.00.000" }'
        }

        $script:bucket = Join-Path $TestDrive 'ResolveBucket'
        New-Item -ItemType Directory -Path $script:bucket -Force | Out-Null

        # Same base name at the root and in a subfolder.
        script:New-Manifest (Join-Path $script:bucket 'Both.json')
        script:New-Manifest (Join-Path $script:bucket 'os\Both.json')
        # Same base name in two different subfolders.
        script:New-Manifest (Join-Path $script:bucket 'ai\Twice.json')
        script:New-Manifest (Join-Path $script:bucket 'os\Twice.json')
        # Nested two levels deep.
        script:New-Manifest (Join-Path $script:bucket 'os\extras\Deep.json')
        # Neighbours that a wildcard name would sweep up.
        script:New-Manifest (Join-Path $script:bucket 'client\WildA.json')
        script:New-Manifest (Join-Path $script:bucket 'client\WildB.json')
        # A manifest OUTSIDE the bucket, one level up.
        script:New-Manifest (Join-Path $TestDrive 'Outside.json')
        # A plain file plus a real NTFS alternate data stream named
        # 'stream.json' on it, so 'StreamHost:stream' is a genuine probe,
        # not a no-op: without the ':' guard this is exactly the path
        # Resolve-BucketManifestPath would Test-Path and find.
        $script:streamHost = Join-Path $script:bucket 'StreamHost'
        Set-Content -LiteralPath $script:streamHost -Value 'dummy' -Encoding utf8
        Set-Content -LiteralPath "$($script:streamHost):stream.json" -Value '{}' -Encoding utf8
    }

    It 'prefers the bucket root over a same-named manifest in a subfolder' {
        # Keeps a root-level manifest's resolution byte-identical to the
        # pre-#452 behavior, which only ever looked at the root.
        script:Invoke-ResolveBucketManifestPath -Name 'Both' -BucketPath $script:bucket |
            Should -Be (Join-Path $script:bucket 'Both.json')
    }

    It 'resolves the same base name in two subfolders deterministically' {
        $first = script:Invoke-ResolveBucketManifestPath -Name 'Twice' -BucketPath $script:bucket
        $first | Should -Be (Join-Path $script:bucket 'ai\Twice.json')
        # Same answer every call -- enumeration order must not leak through.
        1..3 | ForEach-Object {
            script:Invoke-ResolveBucketManifestPath -Name 'Twice' -BucketPath $script:bucket |
                Should -Be $first
        }
    }

    It 'finds a manifest nested more than one level deep' {
        script:Invoke-ResolveBucketManifestPath -Name 'Deep' -BucketPath $script:bucket |
            Should -Be (Join-Path $script:bucket 'os\extras\Deep.json')
    }

    It 'does not let a wildcard in the name widen the search' -ForEach @(
        @{ Pattern = 'Wild*' }
        @{ Pattern = 'Wild?' }
        @{ Pattern = 'Wild[AB]' }
    ) {
        script:Invoke-ResolveBucketManifestPath -Name $Pattern -BucketPath $script:bucket |
            Should -BeNullOrEmpty
    }

    It 'refuses a name with a directory component so the search cannot escape the bucket' -ForEach @(
        @{ Escape = '..\Outside' }
        @{ Escape = '../Outside' }
        @{ Escape = 'os\..\..\Outside' }
    ) {
        # `-LiteralPath` stops wildcard expansion but not `..`; without the
        # leaf-name guard this returned a manifest outside the bucket, which
        # the caller then reported as "found in the bucket".
        script:Invoke-ResolveBucketManifestPath -Name $Escape -BucketPath $script:bucket |
            Should -BeNullOrEmpty
    }

    It 'refuses a name containing a colon so it cannot probe an NTFS alternate data stream' {
        # [IO.Path]::GetFileName alone does not treat ':' as a separator.
        # 'StreamHost:stream' resolves to 'StreamHost:stream.json' once the
        # mandatory suffix is appended -- a REAL, populated ADS (BeforeAll),
        # so Test-Path would genuinely succeed without the ':' guard. This is
        # not a vacuous assertion: removing the guard flips it to the ADS path.
        script:Invoke-ResolveBucketManifestPath -Name 'StreamHost:stream' -BucketPath $script:bucket |
            Should -BeNullOrEmpty
    }

    It 'returns nothing for a missing bucket, or one that is a file rather than a directory' {
        script:Invoke-ResolveBucketManifestPath -Name 'Both' -BucketPath (Join-Path $TestDrive 'NoSuchBucket') |
            Should -BeNullOrEmpty
        script:Invoke-ResolveBucketManifestPath -Name 'Both' -BucketPath (Join-Path $TestDrive 'Outside.json') |
            Should -BeNullOrEmpty
    }
}
