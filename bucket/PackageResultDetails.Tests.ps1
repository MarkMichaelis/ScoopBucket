<#
.SYNOPSIS
    Pins the PackageResult.Details() presentation contract (#283) -- the single
    merged column combining the version transition and the reason.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'PackageResult.Details()' -Tag 'Light', 'Module' {
    It 'renders a from -> to transition for a real update' {
        $r = [PackageResult]@{ Status = 'Updated'; VersionFrom = '1.2.0'; VersionTo = '1.3.0' }
        $r.Details() | Should -Be '1.2.0 -> 1.3.0'
    }

    It 'appends (WhatIf) to the transition on a dry run' {
        $r = [PackageResult]@{ Status = 'Updated'; VersionFrom = '1.2.0'; VersionTo = '1.3.0'; Reason = '(WhatIf)' }
        $r.Details() | Should -Be '1.2.0 -> 1.3.0 (WhatIf)'
    }

    It 'shows the reason when a WhatIf update has unknown versions' {
        $r = [PackageResult]@{ Status = 'Updated'; Reason = '(WhatIf, version unknown)' }
        $r.Details() | Should -Be '(WhatIf, version unknown)'
    }

    It 'renders Reinstalled (never a version) for a Reinstall update' {
        $r = [PackageResult]@{ Status = 'Updated'; Reason = '(Reinstall)' }
        $r.Details() | Should -Be 'Reinstalled'
    }

    It 'renders -> to for a fresh install with no prior version' {
        $r = [PackageResult]@{ Status = 'Installed'; VersionTo = '2.0.0' }
        $r.Details() | Should -Be '-> 2.0.0'
    }

    It 'renders "new install" for a fresh install with no version info' {
        $r = [PackageResult]@{ Status = 'Installed' }
        $r.Details() | Should -Be 'new install'
    }

    It 'prefers an explicit reason over the new-install label for an install' {
        $r = [PackageResult]@{ Status = 'Installed'; Reason = '(DryRun)' }
        $r.Details() | Should -Be '(DryRun)'
    }

    It 'leaves Details blank for an Updated result with no version info' {
        $r = [PackageResult]@{ Status = 'Updated' }
        $r.Details() | Should -Be ''
    }

    It 'renders <version> (latest) for AlreadyLatest' {
        $r = [PackageResult]@{ Status = 'AlreadyLatest'; VersionFrom = '1.12.000' }
        $r.Details() | Should -Be '1.12.000 (latest)'
    }

    It 'renders not installed' {
        ([PackageResult]@{ Status = 'NotInstalled' }).Details() | Should -Be 'not installed'
    }

    It 'renders self-managed' {
        ([PackageResult]@{ Status = 'SelfManaged' }).Details() | Should -Be 'self-managed'
    }

    It 'renders no auto-update' {
        ([PackageResult]@{ Status = 'NoAutoUpdateSupport' }).Details() | Should -Be 'no auto-update'
    }

    It 'shows the failure reason verbatim for a Failed result' {
        $r = [PackageResult]@{ Status = 'Failed'; Reason = 'winget upgrade exited with -1.' }
        $r.Details() | Should -Be 'winget upgrade exited with -1.'
    }
}
