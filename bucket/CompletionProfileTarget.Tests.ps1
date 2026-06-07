#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Regression test for #185: Get-CompletionProfilePath must default to
    $PROFILE.AllUsersAllHosts under elevation, never the CurrentUser*
    variants. The originally-reported symptom was sentinel blocks landing
    in $PROFILE.CurrentUserCurrentHost (Microsoft.PowerShell_profile.ps1)
    despite an elevated session and no -ProfilePath override.

    This test pins the default-target contract so any future regression
    in Get-CompletionProfilePath (or callers that fail to thread the
    override) surfaces in CI.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'Get-CompletionProfilePath default target (#185)' -Tag 'Light','Module' {

    It 'returns $PROFILE.AllUsersAllHosts when no -OverridePath is supplied and the host is elevated' {
        InModuleScope MarkMichaelis.ScoopBucket {
            # Shadow $PROFILE with a sandbox-rooted equivalent so the
            # function's writability probe doesn't require Administrator
            # access to C:\Program Files\PowerShell\7\profile.ps1 in CI.
            # The contract under test is: the function picks the
            # AllUsersAllHosts member of $PROFILE -- not which absolute
            # path that member happens to resolve to on this host.
            $sandboxDir = Join-Path ([System.IO.Path]::GetTempPath()) ("CPT-AUAH-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $sandboxDir -Force | Out-Null
            $sandboxAUAH = Join-Path $sandboxDir 'profile.ps1'
            $sandboxCUCH = Join-Path $sandboxDir 'Microsoft.PowerShell_profile.ps1'
            $sandboxCUAH = Join-Path $sandboxDir 'cuah-profile.ps1'

            try {
                $PROFILE = [pscustomobject]@{
                    AllUsersAllHosts       = $sandboxAUAH
                    AllUsersCurrentHost    = Join-Path $sandboxDir 'auch-profile.ps1'
                    CurrentUserAllHosts    = $sandboxCUAH
                    CurrentUserCurrentHost = $sandboxCUCH
                }
                Mock Test-IsElevated { $true }

                $result = Get-CompletionProfilePath

                $result | Should -Be $sandboxAUAH
                # Defense-in-depth: the value must NOT match any of the
                # CurrentUser* profile variants. This is the exact symptom
                # reported in #185.
                $result | Should -Not -Be $sandboxCUAH
                $result | Should -Not -Be $sandboxCUCH
            } finally {
                Remove-Item -Path $sandboxDir -Recurse -Force -ErrorAction Ignore
            }
        }
    }

    It 'honors -OverridePath verbatim (sandbox usage)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Test-IsElevated { $true }
            $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("CPT-" + [guid]::NewGuid().ToString('N') + '.ps1')
            try {
                $result = Get-CompletionProfilePath -OverridePath $sandbox
                $result | Should -Be $sandbox
            } finally {
                Remove-Item -Path $sandbox -ErrorAction Ignore
            }
        }
    }

    It 'throws (does not silently fall back to CurrentUser) when not elevated' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Test-IsElevated { $false }
            { Get-CompletionProfilePath } | Should -Throw -ExpectedMessage '*elevated*'
        }
    }
}

Describe 'Register-CliCompletion default target (#185)' -Tag 'Light','Module' {

    It 'resolves the profile target via Get-CompletionProfilePath when -ProfilePath is omitted' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("CPT-RCC-" + [guid]::NewGuid().ToString('N') + '.ps1')
            try {
                # Pin the resolver to the sandbox so the test never
                # touches the real machine-wide profile. The point is
                # that Register-CliCompletion delegates target choice
                # to Get-CompletionProfilePath -- not that it invents
                # its own path.
                Mock Get-CompletionProfilePath { param($OverridePath) if ($OverridePath) { $OverridePath } else { $sandbox } }

                $native = [scriptblock]::Create("Write-Output 'Register-ArgumentCompleter -CommandName demo -ScriptBlock { }'")
                $result = Register-CliCompletion -Cli 'demo' -NativeCommand $native -Force -Confirm:$false

                $result.ProfilePath | Should -Be $sandbox
                Test-Path $sandbox | Should -BeTrue
                (Get-Content -Raw -Path $sandbox) | Should -Match '# ScoopBucket:CliCompletion:demo:BEGIN'
            } finally {
                Remove-Item -Path $sandbox -ErrorAction Ignore
            }
        }
    }
}
