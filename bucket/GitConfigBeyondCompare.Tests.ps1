$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install' {
    BeforeAll {
        if (Test-ScoopPackageInstalled $name) {
            scoop uninstall $name
        }
    }

    It 'installs from the local manifest' {
        Install-LocalManifest "$PSScriptRoot\$name.json"
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'registers the bc difftool when Beyond Compare is installed' {
        . "$PSScriptRoot\GitConfigBeyondCompare.ps1" *>$null
        $bcDir = Resolve-BeyondCompareDir
        if (-not $bcDir) {
            Set-ItResult -Skipped -Because 'Beyond Compare not installed'
            return
        }
        # The bc tool config is always registered so `git difftool --tool=bc`
        # works regardless of which tool is the global default (first-writer-
        # wins for diff.tool/merge.tool, so install order is allowed to vary).
        $bcPath = git config --global difftool.bc.path
        $bcPath | Should -Not -BeNullOrEmpty
    }

    It 'targets BComp.com (console-waiting variant) for difftool/mergetool' {
        . "$PSScriptRoot\GitConfigBeyondCompare.ps1" *>$null
        $bcDir = Resolve-BeyondCompareDir
        if (-not $bcDir) {
            Set-ItResult -Skipped -Because 'Beyond Compare not installed'
            return
        }
        if (-not (Test-Path (Join-Path $bcDir 'BComp.com'))) {
            Set-ItResult -Skipped -Because 'BComp.com missing on this BC build; falling back to BComp.exe is expected'
            return
        }
        # git difftool/mergetool need the wait-for-close wrapper; the GUI
        # launcher BComp.exe returns immediately and breaks the workflow.
        $diff  = git config --global difftool.bc.path
        $merge = git config --global mergetool.bc.path
        $diff  | Should -Match 'BComp\.com$'
        $merge | Should -Match 'BComp\.com$'
    }

    It 'discovers a registry-recorded Beyond Compare install when present' {
        . "$PSScriptRoot\GitConfigBeyondCompare.ps1" *>$null
        $regDir = Get-BeyondCompareDirFromRegistry
        $anyKey = (Test-Path 'HKCU:\SOFTWARE\Scooter Software') -or
                  (Test-Path 'HKLM:\SOFTWARE\Scooter Software') -or
                  (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Scooter Software')
        if (-not $anyKey) {
            Set-ItResult -Skipped -Because 'No Scooter Software registry keys on this machine'
            return
        }
        if (-not $regDir) {
            Set-ItResult -Skipped -Because 'Scooter Software key exists but no usable BComp.exe was found via registry probe'
            return
        }
        Test-Path (Join-Path $regDir 'BComp.exe') | Should -Be $true
    }
}
