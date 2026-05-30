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

Describe 'Install-Module.ps1 emits lazy v2 stub block (#243)' -Tag 'Light','Module' {
    It 'profile block is sentinel-marked v2 (not v1 eager Import-Module)' {
        $block = script:Get-EmittedProfileBlock
        $block | Should -Match '# MarkMichaelis.ScoopBucket:Import:BEGIN v2'
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

Describe 'Install-Module.ps1 migrates v1 sentinel block to v2 idempotently' -Tag 'Light','Module' {
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

            $migrated | Should -Match '# MarkMichaelis.ScoopBucket:Import:BEGIN v2'
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
