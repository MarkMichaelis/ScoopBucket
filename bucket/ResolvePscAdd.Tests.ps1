#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Issue #226: Resolve-PackageCompletionSource auto-runs `psc add` when
    the requested CLI is absent from the local PSCompletions catalog.

    Before this fix the resolver checked `psc list` (LOCAL catalog) and
    returned 'Skipped' on a miss -- the downstream `psc add` block was
    therefore unreachable. These tests pin the corrected order:

      list miss -> psc add -> list re-check -> Source decision.
#>

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    Import-Module $script:psd1 -Force
}

Describe 'Resolve-PackageCompletionSource auto psc add (issue #226)' -Tag 'Light' {

    BeforeEach {
        # Fresh fake PSCompletions module per test so the in-process
        # state machine (PscListEntries, PscAddCalls, PscAddSucceeds,
        # PscAddThrows) starts from a known baseline. The production
        # resolver verifies `psc.ModuleName -eq 'PSCompletions'`, so we
        # cannot just inject a script-scoped function -- it must come
        # from a module literally named PSCompletions.
        $script:fakePscModule = New-Module -Name PSCompletions -ScriptBlock {
            $script:PscListEntries  = @()      # CLI names visible to `psc list`
            $script:PscAddCalls     = 0
            $script:PscLastAddArg   = $null
            $script:PscAddSucceeds  = $true    # if true, add appends to PscListEntries
            $script:PscAddThrows    = $false
            $script:PscAddBanner    = $null    # written via Write-Host -- must NOT leak

            function psc {
                param()
                if ($args.Count -ge 1 -and $args[0] -eq 'list') {
                    foreach ($e in $script:PscListEntries) { $e }
                    return
                }
                if ($args.Count -ge 1 -and $args[0] -eq 'add') {
                    $script:PscAddCalls++
                    if ($args.Count -ge 2) { $script:PscLastAddArg = [string]$args[1] }
                    if ($script:PscAddBanner) { Write-Host $script:PscAddBanner }
                    if ($script:PscAddThrows) { throw 'simulated psc add throw' }
                    if ($script:PscAddSucceeds -and $args.Count -ge 2) {
                        $script:PscListEntries = @($script:PscListEntries) + [string]$args[1]
                    }
                    return
                }
            }
            Export-ModuleMember -Function psc -Variable PscListEntries,PscAddCalls,PscLastAddArg,PscAddSucceeds,PscAddThrows,PscAddBanner
        } | Import-Module -PassThru
    }

    AfterEach {
        if ($script:fakePscModule) {
            Remove-Module -ModuleInfo $script:fakePscModule -Force -ErrorAction Ignore
            $script:fakePscModule = $null
        }
    }

    It 'T1: catalog miss + psc add succeeds -> Source=PSCompletions (not Skipped)' {
        # Initial PscListEntries = @() so `psc list` is empty for this CLI.
        $script:fakePscModule.SessionState.PSVariable.Set('PscAddSucceeds', $true)

        $result = InModuleScope MarkMichaelis.ScoopBucket {
            Resolve-PackageCompletionSource -Cli 'dotnet' -PreferPSCompletions
        }

        $result.Source | Should -Be 'PSCompletions'
        $result.PSCompletionsName | Should -Be 'dotnet'
        $script:fakePscModule.SessionState.PSVariable.GetValue('PscAddCalls') | Should -Be 1
        $script:fakePscModule.SessionState.PSVariable.GetValue('PscLastAddArg') | Should -Be 'dotnet'
    }

    It 'T2: catalog already present -> psc add is NOT invoked (no-op fast path)' {
        $script:fakePscModule.SessionState.PSVariable.Set('PscListEntries', @('python'))

        $result = InModuleScope MarkMichaelis.ScoopBucket {
            Resolve-PackageCompletionSource -Cli 'python' -PreferPSCompletions
        }

        $result.Source | Should -Be 'PSCompletions'
        $script:fakePscModule.SessionState.PSVariable.GetValue('PscAddCalls') | Should -Be 0
    }

    It 'T3: catalog miss + psc add fails -> Source=Skipped, Reason mentions `psc add`, Write-Warning emitted' {
        $script:fakePscModule.SessionState.PSVariable.Set('PscAddSucceeds', $false)
        $script:fakePscModule.SessionState.PSVariable.Set('PscAddThrows',   $true)

        $warnings = $null
        $result = InModuleScope MarkMichaelis.ScoopBucket {
            Resolve-PackageCompletionSource -Cli 'unobtainium' -PreferPSCompletions -WarningVariable w -WarningAction SilentlyContinue
            $script:CapturedW = $w
        }
        $warnings = InModuleScope MarkMichaelis.ScoopBucket { $script:CapturedW }
        $result   = InModuleScope MarkMichaelis.ScoopBucket {
            Resolve-PackageCompletionSource -Cli 'unobtainium' -PreferPSCompletions -WarningAction SilentlyContinue
        }

        $result.Source | Should -Be 'Skipped'
        $result.Reason | Should -Match 'psc add'
        $script:fakePscModule.SessionState.PSVariable.GetValue('PscAddCalls') | Should -BeGreaterOrEqual 1
        $warnings = @($warnings)
        $warnings.Count | Should -BeGreaterOrEqual 1
        ($warnings | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'psc add'
    }

    It 'T4: psc add invocation redirects all streams (banner does not leak to host)' {
        # PscAddBanner triggers Write-Host inside the fake `psc add`.
        # Production code must use `*>&1 | Out-Null` (or equivalent) so
        # the banner never reaches the caller's pipeline / host stream.
        $banner = "PSC-ADD-BANNER-$([guid]::NewGuid().ToString('N'))"
        $script:fakePscModule.SessionState.PSVariable.Set('PscAddBanner', $banner)
        $script:fakePscModule.SessionState.PSVariable.Set('PscAddSucceeds', $true)

        # 6>&1 lifts Information/Host stream into success so we can
        # inspect it. If the resolver swallowed it correctly, the
        # banner string will be absent from $captured.
        $captured = InModuleScope MarkMichaelis.ScoopBucket {
            Resolve-PackageCompletionSource -Cli 'leakcheck' -PreferPSCompletions -WarningAction SilentlyContinue
        } 6>&1 | Out-String

        $captured | Should -Not -Match ([regex]::Escape($banner))
    }
}
