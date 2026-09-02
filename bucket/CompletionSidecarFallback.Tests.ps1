#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# Sidecar write fallback (#402).
#
# #400 added a fallback for when the ProgramData sidecar root cannot be
# CREATED. That guard never fires in the situation that actually happens:
# the directory already exists (created by an earlier elevated run) and the
# individual payload files are owned by Administrators with Users holding
# only ReadAndExecute. An unelevated overwrite then fails on Move-Item.
#
# The distinction matters for how this is tested: a directory-level probe
# cannot detect the problem, because a probe creates and deletes a file it
# owns. The failure is specific to replacing a file the user may not replace,
# so these tests deny the write at the file level.
# ----------------------------------------------------------------------------

BeforeAll {
    $script:psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket

    # Make an existing sidecar impossible to replace.
    #
    # A Deny ACE does NOT work here: the test process owns the file and holds
    # FILE_DELETE_CHILD on the TestDrive parent, which grants delete of the
    # child regardless of the file's own DACL -- so Move-Item -Force succeeds
    # and the test silently passes against a working primary path.
    #
    # An exclusive lock (FileShare.None) blocks the replace deterministically,
    # needs no elevation, and models what the caller actually sees: the target
    # cannot be written, whatever the underlying reason.
    function script:Lock-File {
        param([string]$Path)
        return [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
    }
}

Describe 'Write-PackageCompletionSidecar fallback' -Tag 'Light','Completion' {

    It 'writes to the primary directory when it is writable' {
        $primary = Join-Path $TestDrive 'primary'
        New-Item -ItemType Directory -Path $primary -Force | Out-Null
        $p = & $script:mod { param($d, $f) Write-PackageCompletionSidecar -Cli 'demo' -Payload 'x' -Directory $d -FallbackDirectory $f } $primary (Join-Path $TestDrive 'fb')
        $p | Should -Be (Join-Path $primary 'demo.ps1')
        Get-Content -Raw $p | Should -Be 'x'
    }

    It 'falls back and returns the fallback path when the target cannot be replaced' {
        $primary  = Join-Path $TestDrive 'denied'
        $fallback = Join-Path $TestDrive 'beside-profile'
        New-Item -ItemType Directory -Path $primary -Force | Out-Null

        $victim = Join-Path $primary 'demo.ps1'
        Set-Content -Path $victim -Value 'original' -NoNewline
        $lock = script:Lock-File -Path $victim
        try {
            $p = & $script:mod { param($d, $f) Write-PackageCompletionSidecar -Cli 'demo' -Payload 'updated' -Directory $d -FallbackDirectory $f -WarningAction SilentlyContinue } $primary $fallback
            $p | Should -Be (Join-Path $fallback 'demo.ps1') -Because 'the returned path is what gets embedded in the profile block'
            Get-Content -Raw $p | Should -Be 'updated'
        } finally {
            $lock.Dispose()
        }
        # The unwritable original is left untouched, not corrupted.
        Get-Content -Raw $victim | Should -Be 'original'
    }

    It 'leaves no .tmp behind in the abandoned directory' {
        $primary  = Join-Path $TestDrive 'denied2'
        $fallback = Join-Path $TestDrive 'beside2'
        New-Item -ItemType Directory -Path $primary -Force | Out-Null
        $victim = Join-Path $primary 'demo.ps1'
        Set-Content -Path $victim -Value 'original' -NoNewline
        $lock = script:Lock-File -Path $victim
        try {
            & $script:mod { param($d, $f) Write-PackageCompletionSidecar -Cli 'demo' -Payload 'updated' -Directory $d -FallbackDirectory $f -WarningAction SilentlyContinue } $primary $fallback | Out-Null
            @(Get-ChildItem -Path $primary -Filter '*.tmp' -File).Count | Should -Be 0
        } finally {
            $lock.Dispose()
        }
    }

    It 'propagates the failure when no fallback is available' {
        $primary = Join-Path $TestDrive 'denied3'
        New-Item -ItemType Directory -Path $primary -Force | Out-Null
        $victim = Join-Path $primary 'demo.ps1'
        Set-Content -Path $victim -Value 'original' -NoNewline
        $lock = script:Lock-File -Path $victim
        try {
            # Silently swallowing here would hide a real problem from a caller
            # that has nowhere else to write.
            { & $script:mod { param($d) Write-PackageCompletionSidecar -Cli 'demo' -Payload 'updated' -Directory $d } $primary } |
                Should -Throw
        } finally {
            $lock.Dispose()
        }
    }
}

Describe 'Register-PackageCompletion emits the fallback path' -Tag 'Light','Completion' {

    It 'points the profile block at wherever the payload actually landed' {
        $profileDir = Join-Path $TestDrive 'prof'
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        $profilePath = Join-Path $profileDir 'profile.ps1'
        Set-Content -Path $profilePath -Value '' -NoNewline

        $sidecarDir = Join-Path $TestDrive 'shared'
        New-Item -ItemType Directory -Path $sidecarDir -Force | Out-Null
        $victim = Join-Path $sidecarDir 'demo.ps1'
        Set-Content -Path $victim -Value 'original' -NoNewline
        $lock = script:Lock-File -Path $victim
        try {
            & $script:mod {
                param($p, $s)
                Register-PackageCompletion -Cli 'demo' -Mode native -ProfilePath $p -SidecarDirectory $s `
                    -NativeCommand { 'Register-ArgumentCompleter -Native -CommandName demo -ScriptBlock { }' } `
                    -Confirm:$false -WarningAction SilentlyContinue
            } $profilePath $sidecarDir | Out-Null

            $content = Get-Content -Raw -Path $profilePath
            $expected = Join-Path $profileDir 'completions'
            $content | Should -Match ([regex]::Escape($expected)) -Because 'a block pointing at the unwritten shared path would dot-source stale content'
        } finally {
            $lock.Dispose()
        }
    }
}
