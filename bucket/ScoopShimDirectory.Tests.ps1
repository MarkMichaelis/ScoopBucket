<#
.SYNOPSIS
    Guard the scoop shim-directory resolution used by every package that
    writes .cmd shims (the Office CLI shims and OneDrive entries in
    MicrosoftOffice365.ps1).

.DESCRIPTION
    Scoop installs either per-user (~\scoop) or globally
    (C:\ProgramData\scoop). This bucket's own install.ps1 sets SCOOP to the
    ProgramData root at Machine scope, so the global layout is the one the
    repo itself creates -- yet the shim-writing packages used to hardcode
    `Join-Path $env:USERPROFILE 'scoop\shims'` and threw

        Scoop shim directory 'C:\Users\<user>\scoop\shims' not found.

    on exactly that machine. Worse, VerifyScript probed the same hardcoded
    path, so the package never verified and re-downloaded OneDriveSetup.exe
    on every run.

    Get-ScoopShimDirectory probes the candidate roots in precedence order
    and returns the first `shims` folder that exists, mirroring the order
    already used by bucket/developer/GitConfigBeyondCompare.ps1.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psd1     = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force

    $script:office365 = Join-Path $script:repoRoot 'bucket\client\MicrosoftOffice365.ps1'

    # Saved once and restored in AfterAll: the resolution reads these at
    # call time, so each test repoints them at a throwaway sandbox.
    $script:savedScoop       = $env:SCOOP
    $script:savedScoopGlobal = $env:SCOOP_GLOBAL
    $script:savedUserProfile = $env:USERPROFILE
    $script:savedProgramData = $env:ProgramData

    function script:New-ShimRoot {
        <# Create <Parent>\<Name>\shims and return the root (not the shims dir). #>
        param([string]$Parent, [string]$Name)
        $root = Join-Path $Parent $Name
        New-Item -ItemType Directory -Path (Join-Path $root 'shims') -Force | Out-Null
        return $root
    }
}

AfterAll {
    $env:SCOOP        = $script:savedScoop
    $env:SCOOP_GLOBAL = $script:savedScoopGlobal
    $env:USERPROFILE  = $script:savedUserProfile
    $env:ProgramData  = $script:savedProgramData
}

Describe 'Get-ScoopShimDirectory' -Tag 'Light', 'Module' {

    BeforeEach {
        # Point every candidate at a non-existent path inside a fresh
        # sandbox so each test opts in to exactly the roots it wants.
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('shimdir-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:SCOOP        = Join-Path $script:sandbox 'absent-scoop'
        $env:SCOOP_GLOBAL = Join-Path $script:sandbox 'absent-global'
        $env:USERPROFILE  = Join-Path $script:sandbox 'absent-user'
        $env:ProgramData  = Join-Path $script:sandbox 'absent-programdata'
    }

    AfterEach {
        # Restore per-test, not just in AfterAll: these are process-wide, and
        # leaving $env:USERPROFILE / $env:ProgramData pointed at a sandbox we
        # are about to delete would poison any later test in this session.
        # Matches the per-test save/restore in LazyScoopInit.Tests.ps1.
        $env:SCOOP        = $script:savedScoop
        $env:SCOOP_GLOBAL = $script:savedScoopGlobal
        $env:USERPROFILE  = $script:savedUserProfile
        $env:ProgramData  = $script:savedProgramData
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'is exported from the module' {
        (Get-Command Get-ScoopShimDirectory -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'prefers $env:SCOOP\shims when it exists' {
        $env:SCOOP        = script:New-ShimRoot $script:sandbox 'scoop-root'
        $env:SCOOP_GLOBAL = script:New-ShimRoot $script:sandbox 'global-root'

        Get-ScoopShimDirectory | Should -Be (Join-Path $env:SCOOP 'shims')
    }

    It 'falls back to $env:SCOOP_GLOBAL\shims when $env:SCOOP has no shims folder' {
        $env:SCOOP        = Join-Path $script:sandbox 'absent-scoop'
        $env:SCOOP_GLOBAL = script:New-ShimRoot $script:sandbox 'global-root'

        Get-ScoopShimDirectory | Should -Be (Join-Path $env:SCOOP_GLOBAL 'shims')
    }

    It 'falls back to the per-user ~\scoop\shims default' {
        $env:USERPROFILE = Join-Path $script:sandbox 'home'
        New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE 'scoop\shims') -Force | Out-Null

        Get-ScoopShimDirectory | Should -Be (Join-Path $env:USERPROFILE 'scoop\shims')
    }

    It 'falls back to the global ProgramData\scoop\shims default' {
        $env:ProgramData = Join-Path $script:sandbox 'pd'
        New-Item -ItemType Directory -Path (Join-Path $env:ProgramData 'scoop\shims') -Force | Out-Null

        Get-ScoopShimDirectory | Should -Be (Join-Path $env:ProgramData 'scoop\shims')
    }

    It 'returns $null when no candidate root has a shims folder' {
        Get-ScoopShimDirectory | Should -BeNullOrEmpty
    }

    It 'resolves the global root when $env:SCOOP is set and ~\scoop is absent (the reported regression)' {
        # The failing machine: SCOOP=C:\ProgramData\scoop at Machine scope
        # (set by this repo's install.ps1) and no ~\scoop directory at all.
        $env:SCOOP       = script:New-ShimRoot $script:sandbox 'ProgramData-scoop'
        $env:USERPROFILE = Join-Path $script:sandbox 'home-without-scoop'
        New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null

        $resolved = Get-ScoopShimDirectory
        $resolved | Should -Be (Join-Path $env:SCOOP 'shims')
        $resolved | Should -Not -Match 'home-without-scoop'
    }

    It 'skips an unset $env:SCOOP without throwing' {
        $env:SCOOP        = ''
        $env:SCOOP_GLOBAL = script:New-ShimRoot $script:sandbox 'global-root'

        { Get-ScoopShimDirectory } | Should -Not -Throw
        Get-ScoopShimDirectory | Should -Be (Join-Path $env:SCOOP_GLOBAL 'shims')
    }

    It 'ignores a candidate root whose shims entry is a file, not a directory' {
        $env:SCOOP = Join-Path $script:sandbox 'file-shims'
        New-Item -ItemType Directory -Path $env:SCOOP -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $env:SCOOP 'shims') -Value 'not a directory'
        $env:SCOOP_GLOBAL = script:New-ShimRoot $script:sandbox 'global-root'

        Get-ScoopShimDirectory | Should -Be (Join-Path $env:SCOOP_GLOBAL 'shims')
    }
}

Describe 'Shim-writing bundle scripts use the resolver' -Tag 'Light', 'Bundle' {

    It 'no bucket script hardcodes the per-user scoop shims path' {
        $offenders = Get-ChildItem -Path (Join-Path $script:repoRoot 'bucket') -Filter '*.ps1' -Recurse -File |
            Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
            Where-Object {
                $raw = Get-Content -LiteralPath $_.FullName -Raw
                $raw -match [regex]::Escape("Join-Path `$env:USERPROFILE 'scoop\shims")
            } |
            ForEach-Object { $_.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/') }

        $offenders | Should -BeNullOrEmpty -Because 'shim paths must come from Get-ScoopShimDirectory so global scoop installs work'
    }

    It 'the OneDrive install short-circuits on VerifyScript before downloading the installer' {
        # Invoke-PackageInstall has no pre-install gate for Installer=custom:
        # CustomInstallScript runs on every sweep and VerifyScript is only a
        # post-install warning. Without an early-out the package re-downloads
        # OneDriveSetup.exe every run -- and the fwlink serves an older build
        # than the self-updating client already on disk, silently downgrading
        # it. The guard must come BEFORE the download, so assert the order.
        # Get-BundlePackages round-trips through a child runspace as JSON, so
        # scriptblock bodies do not survive it -- read the declaration source.
        $raw   = Get-Content -LiteralPath $script:office365 -Raw
        $start = $raw.IndexOf("Name        = 'Microsoft OneDrive (machine-wide)'")
        $start | Should -BeGreaterThan -1 -Because 'the OneDrive package must still be declared'

        $region = $raw.Substring($start)
        $end    = $region.IndexOf('CustomUninstallScript')
        $end | Should -BeGreaterThan -1
        $region = $region.Substring(0, $end)

        $guardAt    = $region.IndexOf('$pkg.VerifyScript')
        $downloadAt = $region.IndexOf('Invoke-WebRequest')

        $guardAt    | Should -BeGreaterThan -1 -Because 'the install must consult VerifyScript before doing any work'
        $downloadAt | Should -BeGreaterThan -1
        $guardAt    | Should -BeLessThan $downloadAt -Because 'an already-installed OneDrive must not be re-downloaded'
    }

    It 'install, uninstall, and verify in MicrosoftOffice365.ps1 all call Get-ScoopShimDirectory' {
        $raw = Get-Content -LiteralPath $script:office365 -Raw

        # Two packages (Office CLI shims + OneDrive), each with an install,
        # an uninstall, and a verify script that must agree on one path.
        ([regex]::Matches($raw, 'Get-ScoopShimDirectory')).Count |
            Should -BeGreaterOrEqual 6 -Because 'each of the six shim script sites resolves the directory'
    }
}
