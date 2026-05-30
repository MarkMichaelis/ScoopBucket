<#
.SYNOPSIS
    Pin the lazy-init contract for scoop's heavy search library:
      - scoop's lightweight libs (parse_app, Find-BucketDirectory) ARE
        dot-sourced into module scope on Import-Module (cheap; ~320 ms).
      - scoop-search's `search_bucket` is NOT loaded eagerly (it pulls
        in ~1.8s of nested dot-sources via versions.ps1 / download.ps1).
      - Cold `Import-Module MarkMichaelis.ScoopBucket` median stays
        under a loose budget that catches regressions if scoop-search
        ever re-enters the eager path.
#>

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    function script:Test-ModulePrivateCommand {
        param([string]$Name)
        $mod = Get-Module MarkMichaelis.ScoopBucket
        if (-not $mod) { return $false }
        [bool]($mod.Invoke({ param($n) Get-Command $n -ErrorAction Ignore }, $Name))
    }
}

Describe 'MarkMichaelis.ScoopBucket lazy scoop-search contract' -Tag 'Light','Module' {
    BeforeEach {
        Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction Ignore
    }

    It 'eagerly loads lightweight scoop libs (parse_app, Find-BucketDirectory)' {
        Import-Module $script:psd1 -Force
        script:Test-ModulePrivateCommand 'parse_app'           | Should -BeTrue
        script:Test-ModulePrivateCommand 'Find-BucketDirectory' | Should -BeTrue
    }

    It 'does NOT eagerly dot-source scoop-search.ps1' {
        Import-Module $script:psd1 -Force
        # search_bucket lives in libexec\scoop-search.ps1 -- the heavy
        # library we defer. If this assertion fails, scoop-search.ps1
        # has re-entered the eager init path and import will regress
        # by ~1.8s.
        script:Test-ModulePrivateCommand 'search_bucket' | Should -BeFalse
    }
}

Describe 'MarkMichaelis.ScoopBucket cold import budget' -Tag 'Light','Module','Perf' {
    It 'imports in under 1800 ms (median of 5 cold pwsh -NoProfile runs)' -Skip:([bool]$env:CI) {
        $pwsh = (Get-Process -Id $PID).Path
        $samples = 1..5 | ForEach-Object {
            (Measure-Command {
                & $pwsh -NoProfile -Command "Import-Module '$script:psd1'"
            }).TotalMilliseconds
        }
        $median = ($samples | Sort-Object)[2]
        Write-Host "Cold import samples (ms): $($samples -join ', '); median=$median"
        # Baseline before lazy-scoop-search: ~3400 ms. After: ~1500 ms.
        # 1800 ms is loose enough to absorb FS-cache + AV jitter while
        # still failing loudly if scoop-search.ps1 re-enters eager init.
        $median | Should -BeLessThan 1800
    }
}