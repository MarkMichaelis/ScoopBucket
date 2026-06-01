#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# De-Store helpers (#281).
#
# Remove-StorePwsh removes the sealed Microsoft Store / MSIX build of
# PowerShell 7 so the first-party MSI build wins and its AllUsersAllHosts
# profile is admin-writable. The removal *policy* (Resolve-StorePwshRemoval)
# and the PATH scrub (Remove-StorePwshFromPathString) are pure functions so
# they are unit-testable without the Appx cmdlets (which exist only on
# Windows) and without mutating the real environment.
#
# Tagged 'Light' -- pure functions, no processes, no environment writes.
# ----------------------------------------------------------------------------

Describe 'De-Store PowerShell helpers' -Tag 'Light' {
    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    }

    Context 'Remove-StorePwshFromPathString' {
        It 'drops the sealed WindowsApps PowerShell directory and preserves order' {
            InModuleScope MarkMichaelis.ScoopBucket {
                $sealed = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.2.0_x64__8wekyb3d8bbwe'
                $path = "C:\Windows;$sealed;C:\Program Files\PowerShell\7;C:\Tools"

                $result = Remove-StorePwshFromPathString -PathValue $path

                $result | Should -Not -Match '(?i)WindowsApps\\Microsoft\.PowerShell_' `
                    -Because 'the sealed Store package directory must be removed from PATH'
                $result | Should -Be 'C:\Windows;C:\Program Files\PowerShell\7;C:\Tools' `
                    -Because 'every other entry must be preserved in original order'
            }
        }

        It 'is a no-op when no sealed PowerShell directory is present' {
            InModuleScope MarkMichaelis.ScoopBucket {
                $path = 'C:\Windows;C:\Program Files\PowerShell\7;C:\Tools'
                Remove-StorePwshFromPathString -PathValue $path | Should -Be $path
            }
        }
    }

    Context 'Resolve-StorePwshRemoval' {
        It 'requests removal when the Store build is present and the MSI build exists' {
            InModuleScope MarkMichaelis.ScoopBucket {
                $decision = Resolve-StorePwshRemoval -StorePackage ([pscustomobject]@{ Name = 'Microsoft.PowerShell' }) -MsiPresent $true
                $decision.ShouldRemove | Should -BeTrue
                $decision.StoreBuildFound | Should -BeTrue
            }
        }

        It 'refuses removal when the MSI build is missing (would leave no pwsh)' {
            InModuleScope MarkMichaelis.ScoopBucket {
                $decision = Resolve-StorePwshRemoval -StorePackage ([pscustomobject]@{ Name = 'Microsoft.PowerShell' }) -MsiPresent $false
                $decision.ShouldRemove | Should -BeFalse `
                    -Because 'removing the only pwsh on the machine would be destructive'
                $decision.StoreBuildFound | Should -BeTrue
            }
        }

        It 'is a no-op when no Store build is present' {
            InModuleScope MarkMichaelis.ScoopBucket {
                $decision = Resolve-StorePwshRemoval -StorePackage $null -MsiPresent $true
                $decision.ShouldRemove | Should -BeFalse
                $decision.StoreBuildFound | Should -BeFalse
            }
        }
    }

    Context 'Remove-StorePwsh orchestration' -Skip:(-not $IsWindows) {
        It 'removes the Appx package when the Store build is present and MSI exists' {
            InModuleScope MarkMichaelis.ScoopBucket {
                Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.PowerShell' } }
                Mock Remove-AppxPackage { }
                Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
                Mock Add-MachinePath { }
                Mock Remove-StorePwshPathEntry { }
                Mock Get-Command { $true } -ParameterFilter { $Name -eq 'Get-AppxPackage' }

                $result = Remove-StorePwsh -Confirm:$false

                Should -Invoke Remove-AppxPackage -Times 1 -Exactly `
                    -Because 'the sealed Store build must be removed'
                Should -Invoke Remove-StorePwshPathEntry -Times 2 -Exactly `
                    -Because 'both Machine and User PATH scopes are scrubbed (via the mockable helper, never the real env)'
                $result.Removed | Should -BeTrue
            }
        }

        It 'does not remove anything when the Store build is absent' {
            InModuleScope MarkMichaelis.ScoopBucket {
                Mock Get-AppxPackage { $null }
                Mock Remove-AppxPackage { }
                Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
                Mock Remove-StorePwshPathEntry { }
                Mock Get-Command { $true } -ParameterFilter { $Name -eq 'Get-AppxPackage' }

                $result = Remove-StorePwsh -Confirm:$false

                Should -Invoke Remove-AppxPackage -Times 0 -Exactly
                Should -Invoke Remove-StorePwshPathEntry -Times 0 -Exactly
                $result.StoreBuildFound | Should -BeFalse
                $result.Removed | Should -BeFalse
            }
        }
    }
}
