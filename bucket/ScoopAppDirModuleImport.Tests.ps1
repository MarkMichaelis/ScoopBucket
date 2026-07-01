#requires -Version 7.0
# ----------------------------------------------------------------------------
# Part B behavior test (Pester v5, Light): a bundle .ps1 that scoop dropped
# into ~\scoop\apps\<bundle>\<ver>\ (with NO sibling module\) must still load
# MarkMichaelis.ScoopBucket -- by finding it in the bucket CLONE at
# <scoopRoot>\buckets\*\module\... -- when run under -NoProfile.
#
# The header text is extracted from a REAL production bundle via its region
# markers, so reverting the bucket-clone branch (branch 2) there makes the
# positive cases below fail (behavioral fail-on-revert). See #390.
# ----------------------------------------------------------------------------

Set-StrictMode -Version Latest

Describe 'Bundle loads MarkMichaelis.ScoopBucket from the scoop bucket clone under -NoProfile' -Tag 'Light', 'Bundle' {

    BeforeAll {
        $script:repoRoot  = Split-Path -Parent $PSScriptRoot
        $script:moduleSrc = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
        $script:pwshPath  = (Get-Process -Id $PID).Path

        # Pull the region-delimited "#region MarkMichaelis.ScoopBucket bundle
        # module import ... #endregion" block out of a shipped bundle. Returns
        # '' if absent (which makes the composed probe bundle fail to resolve
        # [Package] -> the positive It below fails, exactly as it should before
        # the fix lands).
        function Get-BundleImportHeader {
            param([Parameter(Mandatory)][string]$BundlePath)
            $text = Get-Content -Raw -LiteralPath $BundlePath
            $m = [regex]::Match($text, '(?ms)^#region MarkMichaelis\.ScoopBucket bundle module import.*?^#endregion[^\r\n]*')
            if ($m.Success) { return $m.Value }
            return ''
        }

        # Stage a fake scoop root: apps\BootstrapProbe\1.0.0\BootstrapProbe.ps1
        # holding ONLY the header + a trivial declarative install, and
        # (optionally) a sibling bucket clone that actually contains the module.
        # NO module\ sibling is created in the app dir, so branch 1 (repo
        # checkout) cannot resolve.
        function New-FakeScoopBundle {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][AllowEmptyString()][string]$Header,
                [switch]$WithBucketClone
            )
            $appDir = Join-Path $Root 'apps\BootstrapProbe\1.0.0'
            New-Item -ItemType Directory -Force -Path $appDir | Out-Null
            if ($WithBucketClone) {
                $cloneModule = Join-Path $Root 'buckets\TestBucket\module\MarkMichaelis.ScoopBucket'
                New-Item -ItemType Directory -Force -Path $cloneModule | Out-Null
                Copy-Item -Path (Join-Path $script:moduleSrc '*') -Destination $cloneModule -Recurse -Force
            }
            $body = @"
$Header

`$Packages = [Package[]]@(
    [Package]@{ Name = 'BootstrapProbe'; CustomInstallScript = { } }
)
Invoke-PackageInstall -Packages `$Packages -Bundle 'BootstrapProbe' -DryRun |
    ForEach-Object { "RESULT:`$(`$_.Name)=`$(`$_.Status)" }
"@
            $bundlePath = Join-Path $appDir 'BootstrapProbe.ps1'
            Set-Content -LiteralPath $bundlePath -Value $body -Encoding utf8
            return $bundlePath
        }

        # Run the probe bundle in a fresh -NoProfile child (mirrors scoop) so
        # the imported module + [Package] type never leak into the test runner.
        #
        # The child's PSModulePath is pinned to just the built-in pwsh module
        # dir. That is faithful to scoop's real launch -- under -NoProfile the
        # module is NOT on PSModulePath (that is the bug; Part C is what puts it
        # there deliberately) -- and it makes the negative control hermetic: a
        # suite peer that prepends the repo module dir to the parent's
        # PSModulePath cannot leak in and let branch 3 (by-name Import-Module)
        # mask the branch-2 bucket-clone load path. See #390.
        function Invoke-ProbeBundle {
            param([Parameter(Mandatory)][string]$BundlePath, [string]$ScoopEnv = '')
            $prevScoop = $env:SCOOP
            $prevPsmp = $env:PSModulePath
            try {
                $env:SCOOP = $ScoopEnv
                $env:PSModulePath = Join-Path $PSHOME 'Modules'
                return (& $script:pwshPath -NoProfile -ExecutionPolicy Bypass -File $BundlePath 2>&1 | Out-String)
            } finally {
                $env:SCOOP = $prevScoop
                $env:PSModulePath = $prevPsmp
            }
        }
    }

    Context 'top-level bundle header (OSBasePackages, branch-1 depth ..\module)' {
        BeforeAll {
            $script:header = Get-BundleImportHeader -BundlePath (Join-Path $script:repoRoot 'bucket\OSBasePackages.ps1')
        }

        It 'loads via the ..\..\..\ scoop-root derivation when $env:SCOOP is unset' {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $bundle = New-FakeScoopBundle -Root $root -Header $script:header -WithBucketClone
            (Invoke-ProbeBundle -BundlePath $bundle) | Should -Match 'RESULT:BootstrapProbe=Installed'
        }

        It 'loads via $env:SCOOP when it points at the scoop root' {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $bundle = New-FakeScoopBundle -Root $root -Header $script:header -WithBucketClone
            (Invoke-ProbeBundle -BundlePath $bundle -ScoopEnv $root) | Should -Match 'RESULT:BootstrapProbe=Installed'
        }

        It 'does NOT load when the bucket clone is absent (negative control: branch 2 is the load path)' {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $bundle = New-FakeScoopBundle -Root $root -Header $script:header
            (Invoke-ProbeBundle -BundlePath $bundle) | Should -Not -Match 'RESULT:BootstrapProbe=Installed'
        }
    }

    Context 'subdir bundle header (developer/PowerShell, branch-1 depth ..\..\module)' {
        BeforeAll {
            $script:header = Get-BundleImportHeader -BundlePath (Join-Path $script:repoRoot 'bucket\developer\PowerShell.ps1')
        }

        It 'loads from the bucket clone (identical branch 2 despite deeper branch 1)' {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $bundle = New-FakeScoopBundle -Root $root -Header $script:header -WithBucketClone
            (Invoke-ProbeBundle -BundlePath $bundle) | Should -Match 'RESULT:BootstrapProbe=Installed'
        }
    }
}