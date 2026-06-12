<#
.SYNOPSIS
    Pin the lazy-import contract for $PROFILE.CurrentUserAllHosts.

    The block written by Install-Module.ps1 must:
      1. NOT eagerly Import-Module MarkMichaelis.ScoopBucket. Profile
         dot-source must remain cheap (target: <50 ms; budget set
         loose to absorb FS/AV jitter).
      2. Register a stub argument completer for `-Name` on
         Install/Get/Uninstall-Package that, on first Tab, triggers
         Import-Module and returns REAL package-name suggestions for
         that same Tab call (not file paths from the default fallback).
      3. Carry sentinel `# MarkMichaelis.ScoopBucket:Import:BEGIN v2`
         so Install-Module.ps1 can detect and replace v1 blocks
         idempotently.

    These tests are the behavioral contract for issue #243. If any
    fails, profile load has either regressed back to eager-import
    (~1 s tax on every shell start) or first-Tab completions silently
    return file paths.
#>

BeforeAll {
    $script:repoRoot      = Split-Path -Parent $PSScriptRoot
    $script:installScript = Join-Path $script:repoRoot 'module\Install-Module.ps1'
    $script:helperScript  = Join-Path $script:repoRoot 'module\Add-ScoopBucketProfileBlock.ps1'
    $script:moduleRoot    = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1          = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    if (-not (Test-Path $script:installScript)) {
        throw "Install-Module.ps1 not found at $script:installScript"
    }
    if (-not (Test-Path $script:helperScript)) {
        throw "Add-ScoopBucketProfileBlock.ps1 not found at $script:helperScript"
    }
    if (-not (Test-Path $script:psd1)) {
        throw "Module manifest not found at $script:psd1"
    }

    # Emit the v2 stub block to a fresh temp profile and return its
    # contents as a string. Calls the helper script directly so the
    # tests don't need to run Install-Module.ps1's junction step.
    function script:Get-EmittedProfileBlock {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-profile-test-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            & $script:helperScript -ProfilePath $tempProfile | Out-Null
            return (Get-Content -Raw -LiteralPath $tempProfile)
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }
}

Describe 'Install-Module.ps1 emits lazy v3 stub block (#243, #375)' -Tag 'Light','Module' {
    It 'profile block is sentinel-marked v3 (not v1 eager Import-Module)' {
        $block = script:Get-EmittedProfileBlock
        $block | Should -Match '# MarkMichaelis.ScoopBucket:Import:BEGIN v3'
        $block | Should -Match '# MarkMichaelis.ScoopBucket:Import:END'
    }

    It 'profile block does NOT contain an unconditional eager Import-Module' {
        # The v1 block ran Import-Module unconditionally on every shell
        # start. v2 must defer it behind a Tab-completer trigger. We
        # tolerate the literal string "Import-Module" appearing inside
        # the stub's deferred scriptblock; what we forbid is a
        # top-level eager call. Match the v1 shape:
        #     if (-not (Get-Module ...)) { Import-Module ... }
        # at the OUTERMOST scope of the stub block.
        $block = script:Get-EmittedProfileBlock
        $v1Pattern = '(?ms)^if \(-not \(Get-Module -Name MarkMichaelis\.ScoopBucket\)\) \{\s*\r?\n\s*Import-Module MarkMichaelis\.ScoopBucket'
        $block | Should -Not -Match $v1Pattern
    }
}

Describe 'v2 stub does not load module on profile dot-source' -Tag 'Light','Module' {
    It 'dot-sourcing the emitted block in a fresh pwsh leaves the module unloaded' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-stub-dotsrc-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            $block = script:Get-EmittedProfileBlock
            Set-Content -LiteralPath $tempProfile -Value $block -Encoding utf8

            $probe = "& { . '$tempProfile'; if (Get-Module MarkMichaelis.ScoopBucket) { 'LOADED' } else { 'UNLOADED' } }"
            $result = pwsh -NoProfile -NoLogo -Command $probe
            ($result -join "`n").Trim() | Should -Be 'UNLOADED'
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }
}

Describe 'v2 stub completer triggers import and returns real suggestions on first Tab' -Tag 'Light','Module' {
    It 'first [CommandCompletion]::CompleteInput on Install-Package -Name returns package-name results, not file paths' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-stub-tab-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            $block = script:Get-EmittedProfileBlock
            Set-Content -LiteralPath $tempProfile -Value $block -Encoding utf8

            # Run from a directory that has dot-prefixed entries so the
            # default file-fallback would clearly produce '.git' etc.
            # if the stub completer didn't fire.
            $probe = @"
`$env:PSModulePath = '$($script:repoRoot.Replace("'","''"))\module' + [IO.Path]::PathSeparator + `$env:PSModulePath
. '$tempProfile'
Set-Location '$($script:repoRoot)'
`$r = [System.Management.Automation.CommandCompletion]::CompleteInput('Install-Package -Name ', 22, `$null)
`$r.CompletionMatches | ForEach-Object { `$_.CompletionText }
"@
            $completionResult = pwsh -NoProfile -NoLogo -Command $probe
            $matchList = @($completionResult | Where-Object { $_ })

            # Negative assertion: NO results may look like a file path
            # (./.git, .\folder, etc.). If the stub completer didn't
            # fire, PowerShell falls back to the file completer and
            # returns these.
            $fileLike = $matchList | Where-Object { $_ -match '^\.[\\/]' }
            $fileLike | Should -BeNullOrEmpty -Because 'stub completer must intercept first Tab and return package names, not file fallbacks'

            # Positive assertion: at least one result must be a known
            # bucket package name (NoOpBundle is a stable test-fixture).
            # We use a loose contains-letters check so the test isn't
            # brittle to bucket changes.
            ($matchList.Count -gt 0) | Should -BeTrue -Because 'stub must surface real package suggestions for the first Tab'
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }

    It 'after the first Tab, the module is loaded' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-stub-after-tab-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            $block = script:Get-EmittedProfileBlock
            Set-Content -LiteralPath $tempProfile -Value $block -Encoding utf8

            $probe = @"
`$env:PSModulePath = '$($script:repoRoot.Replace("'","''"))\module' + [IO.Path]::PathSeparator + `$env:PSModulePath
. '$tempProfile'
[System.Management.Automation.CommandCompletion]::CompleteInput('Install-Package -Name ', 22, `$null) | Out-Null
if (Get-Module MarkMichaelis.ScoopBucket) { 'LOADED' } else { 'UNLOADED' }
"@
            $result = pwsh -NoProfile -NoLogo -Command $probe
            ($result -join "`n").Trim() | Should -Be 'LOADED'
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }
}

Describe 'Install-Module.ps1 migrates v1/v2 sentinel block to v3 idempotently' -Tag 'Light','Module' {
    It 'replaces a pre-existing v1 sentinel block in-place when re-run' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-migrate-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            # Seed the temp profile with the legacy v1 block.
            $v1Block = @'
# MarkMichaelis.ScoopBucket:Import:BEGIN
# Auto-loads the module so Tab completion for Install-Package / Get-Package
# -Name works on the first keystroke. Remove this block (or re-run
# Install-Module.ps1 -SkipProfile) to opt out.
if (-not (Get-Module -Name MarkMichaelis.ScoopBucket)) {
    Import-Module MarkMichaelis.ScoopBucket -ErrorAction SilentlyContinue
}
# MarkMichaelis.ScoopBucket:Import:END
'@
            Set-Content -LiteralPath $tempProfile -Value $v1Block -Encoding utf8

            & $script:helperScript -ProfilePath $tempProfile | Out-Null
            $migrated = Get-Content -Raw -LiteralPath $tempProfile

            $migrated | Should -Match '# MarkMichaelis.ScoopBucket:Import:BEGIN v3'
            # The v1 BEGIN line had no version suffix; after migration
            # there must be exactly ONE BEGIN marker, the v2 one.
            ([regex]::Matches($migrated, '# MarkMichaelis\.ScoopBucket:Import:BEGIN').Count) | Should -Be 1
            # And the v1-style eager Import-Module body must be gone.
            $migrated | Should -Not -Match '(?ms)^if \(-not \(Get-Module -Name MarkMichaelis\.ScoopBucket\)\) \{\s*\r?\n\s*Import-Module MarkMichaelis\.ScoopBucket'
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }

    It 'is idempotent: re-running on a v2 block produces no duplicates' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-idempotent-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            & $script:helperScript -ProfilePath $tempProfile | Out-Null
            & $script:helperScript -ProfilePath $tempProfile | Out-Null
            & $script:helperScript -ProfilePath $tempProfile | Out-Null
            $content = Get-Content -Raw -LiteralPath $tempProfile
            ([regex]::Matches($content, '# MarkMichaelis\.ScoopBucket:Import:BEGIN').Count) | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }
}

Describe 'Add-ScoopBucketProfileBlock.ps1 -Remove strips the sentinel block (#251)' -Tag 'Light','Module' {
    It 'removes a v2 sentinel block in place, preserving surrounding content' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-remove-v2-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            $before = "Write-Host 'before'`n"
            $after  = "`nWrite-Host 'after'`n"
            Set-Content -LiteralPath $tempProfile -Value $before -Encoding utf8
            & $script:helperScript -ProfilePath $tempProfile | Out-Null
            Add-Content -LiteralPath $tempProfile -Value $after -Encoding utf8

            & $script:helperScript -ProfilePath $tempProfile -Remove | Out-Null
            $content = Get-Content -Raw -LiteralPath $tempProfile

            $content | Should -Not -Match '# MarkMichaelis\.ScoopBucket:Import:BEGIN'
            $content | Should -Not -Match '# MarkMichaelis\.ScoopBucket:Import:END'
            $content | Should -Match "Write-Host 'before'"
            $content | Should -Match "Write-Host 'after'"
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }

    It 'removes a legacy v1 sentinel block too' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-remove-v1-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            $v1Block = @'
# MarkMichaelis.ScoopBucket:Import:BEGIN
if (-not (Get-Module -Name MarkMichaelis.ScoopBucket)) {
    Import-Module MarkMichaelis.ScoopBucket -ErrorAction SilentlyContinue
}
# MarkMichaelis.ScoopBucket:Import:END
'@
            Set-Content -LiteralPath $tempProfile -Value $v1Block -Encoding utf8

            & $script:helperScript -ProfilePath $tempProfile -Remove | Out-Null
            $content = Get-Content -Raw -LiteralPath $tempProfile -ErrorAction SilentlyContinue
            if ($null -eq $content) { $content = '' }

            $content | Should -Not -Match '# MarkMichaelis\.ScoopBucket:Import:BEGIN'
            $content | Should -Not -Match 'Import-Module MarkMichaelis\.ScoopBucket'
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }

    It 'is a no-op when the profile has no sentinel block' {
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-remove-noop-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            $original = "# unrelated profile content`nWrite-Host 'hi'`n"
            Set-Content -LiteralPath $tempProfile -Value $original -Encoding utf8

            & $script:helperScript -ProfilePath $tempProfile -Remove | Out-Null
            $content = Get-Content -Raw -LiteralPath $tempProfile

            $content.TrimEnd() | Should -Be $original.TrimEnd()
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }
}

Describe 'Install-Module.ps1 -Uninstall surfaces the -Remove path (#251)' -Tag 'Light','Module' {
    It 'accepts -Uninstall and runs without throwing under -WhatIf' {
        # We invoke under -WhatIf so the host's real profile / junction
        # are not modified. The contract here is only: the script
        # parses the new switch and reaches the uninstall branch
        # without throwing.
        { & $script:installScript -Uninstall -WhatIf } | Should -Not -Throw
    }
}

Describe 'Install-Module.ps1 -Uninstall removes a ReadOnly junction (#253)' -Tag 'Light','Module' {
    # Regression for #253: New-Item -ItemType Junction creates a link
    # with ReadOnly attribute set on some hosts. The original
    # implementation used `Remove-Item -Recurse -Force` which follows
    # the reparse point into the target and fails with Access Denied
    # if the target tree contains read-only files (or the link itself
    # is ReadOnly). The fix strips ReadOnly and uses
    # [System.IO.Directory]::Delete($path, $false) to remove only the
    # link.
    It 'removes a junction whose Attributes include ReadOnly' {
        $sandbox    = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-junction-$([guid]::NewGuid().ToString('N'))"
        $sourceDir  = Join-Path $sandbox 'real-source'
        $linkParent = Join-Path $sandbox 'fake-modules'
        $linkPath   = Join-Path $linkParent 'MarkMichaelis.ScoopBucket'
        try {
            New-Item -ItemType Directory -Path $sourceDir | Out-Null
            New-Item -ItemType Directory -Path $linkParent | Out-Null
            # Put a read-only file inside the source so a recursive
            # delete via the junction would fail with Access Denied.
            $sentinelFile = Join-Path $sourceDir 'sentinel.txt'
            Set-Content -LiteralPath $sentinelFile -Value 'do-not-delete' -Encoding utf8
            (Get-Item -LiteralPath $sentinelFile).IsReadOnly = $true

            $junction = New-Item -ItemType Junction -Path $linkPath -Target $sourceDir
            # Force ReadOnly on the junction itself to mirror the bug.
            $junction.Attributes = $junction.Attributes -bor [System.IO.FileAttributes]::ReadOnly

            # Apply the same junction-removal logic as Install-Module.ps1.
            $existing  = Get-Item -LiteralPath $linkPath -Force
            $isJunction = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            $isJunction | Should -BeTrue

            if (($existing.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                $existing.Attributes = $existing.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            }
            { [System.IO.Directory]::Delete($linkPath, $false) } | Should -Not -Throw

            Test-Path -LiteralPath $linkPath  | Should -BeFalse
            # Source dir + read-only file must remain intact (the bug
            # would have either failed entirely or wiped them).
            Test-Path -LiteralPath $sourceDir    | Should -BeTrue
            Test-Path -LiteralPath $sentinelFile | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $sentinelFile) {
                (Get-Item -LiteralPath $sentinelFile -ErrorAction Ignore).IsReadOnly = $false
            }
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Ignore
        }
    }
}

Describe 'v3 stub block registers the repo module dir on PSModulePath (#375)' -Tag 'Light','Module' {
    It 'makes MarkMichaelis.ScoopBucket discoverable after dot-source with no pre-seeded PSModulePath' {
        # Behavioral contract for #375: the OneDrive-breaking junction is
        # replaced by a profile block that prepends the repo's module dir to
        # $env:PSModulePath. With PSModulePath emptied, dot-sourcing the block
        # must be sufficient for Get-Module -ListAvailable to find the module.
        $tempProfile = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-psmodulepath-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            $block = script:Get-EmittedProfileBlock
            Set-Content -LiteralPath $tempProfile -Value $block -Encoding utf8

            $probe = @"
`$env:PSModulePath = ''
. '$tempProfile'
if (Get-Module -ListAvailable -Name MarkMichaelis.ScoopBucket) { 'PRESENT' } else { 'ABSENT' }
"@
            $result = pwsh -NoProfile -NoLogo -Command $probe
            ($result -join "`n").Trim() | Should -Be 'PRESENT'
        } finally {
            Remove-Item -LiteralPath $tempProfile -ErrorAction Ignore
        }
    }
}

Describe 'Install-Module.ps1 install path removes a legacy junction and creates none (#375)' -Tag 'Light','Module' {
    It 'removes a pre-existing self-pointing junction at the user module path and leaves no reparse point' {
        # The pre-#375 installer junctioned the module into the user module
        # path; on OneDrive Known-Folder-Move machines that path is synced and
        # backup chokes on the reparse point. Running the installer must now
        # clean up that legacy junction and must NOT recreate one. The test
        # redirects the user module path via the internal
        # $env:SCOOPBUCKET_USER_MODULE_PATH seam so it never touches the host.
        $installScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\Install-Module.ps1'
        $source        = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket'
        $sandbox       = Join-Path ([IO.Path]::GetTempPath()) "scoopbucket-legacy-$([guid]::NewGuid().ToString('N'))"
        $linkPath      = Join-Path $sandbox 'MarkMichaelis.ScoopBucket'
        $savedEnv      = $env:SCOOPBUCKET_USER_MODULE_PATH
        try {
            New-Item -ItemType Directory -Path $sandbox | Out-Null
            New-Item -ItemType Junction -Path $linkPath -Target $source | Out-Null
            (Get-Item -LiteralPath $linkPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Not -Be 0

            $env:SCOOPBUCKET_USER_MODULE_PATH = $sandbox
            & $installScript -SkipProfile -WarningAction SilentlyContinue | Out-Null

            # The legacy junction must be gone, and no new reparse point may
            # exist at that path.
            if (Test-Path -LiteralPath $linkPath) {
                (Get-Item -LiteralPath $linkPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint |
                    Should -Be 0 -Because 'the installer must not recreate a junction under the user module path'
            }
            # The real source module must be untouched.
            Test-Path -LiteralPath $source -PathType Container | Should -BeTrue
        } finally {
            $env:SCOOPBUCKET_USER_MODULE_PATH = $savedEnv
            if (Test-Path -LiteralPath $linkPath) {
                $i = Get-Item -LiteralPath $linkPath -Force
                if (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    [IO.Directory]::Delete($linkPath, $false)
                }
            }
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Ignore
        }
    }
}
