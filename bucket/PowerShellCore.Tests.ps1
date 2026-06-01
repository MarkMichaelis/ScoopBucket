#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# PowerShellCore install-source policy (#281).
#
# The Microsoft Store / MSIX build of PowerShell 7 installs into a sealed
# TrustedInstaller-owned WindowsApps directory whose AllUsersAllHosts profile
# can't be written even when elevated, breaking machine-wide completion
# registration. The bucket must therefore install the first-party signed MSI
# via the winget *default* source -- never `choco install powershell-core`
# (which let the Store build shadow it) and never the `msstore` source.
#
# Tagged 'Light' -- parses the manifest JSON only; no install side effects.
# ----------------------------------------------------------------------------

BeforeDiscovery {
    $script:ManifestPath = Join-Path $PSScriptRoot 'PowerShellCore.json'
}

Describe 'PowerShellCore install source policy' -Tag 'Light' {
    BeforeAll {
        $script:ManifestPath = Join-Path $PSScriptRoot 'PowerShellCore.json'
        $script:Manifest = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $script:Script = ($script:Manifest.installer.script -join "`n")
    }

    It 'installs PowerShell from the winget default source' {
        $script:Script | Should -Match '(?i)winget\s+install\b' `
            -Because 'PowerShell must be installed as the first-party signed MSI via winget'
        $script:Script | Should -Match '(?i)--id\s+Microsoft\.PowerShell\b' `
            -Because 'the winget package id pins the official PowerShell package'
        $script:Script | Should -Match '(?i)--source\s+winget\b' `
            -Because 'the winget source serves the MSI; the msstore source serves the sealed MSIX'
    }

    It 'does not install PowerShell via choco (which let the Store build shadow the MSI)' {
        $script:Script | Should -Not -Match '(?i)choco\s+install\s+powershell-core' `
            -Because 'choco install powershell-core regressed to a Store-shadowed pwsh'
    }

    It 'never sources PowerShell from msstore' {
        $script:Script | Should -Not -Match '(?i)--source\s+msstore' `
            -Because 'msstore serves the sealed MSIX build with an unwritable AllUsers profile'
        $script:Script | Should -Not -Match '(?i)\bmsstore\b' `
            -Because 'msstore is the last-resort source and must not be used for PowerShell'
    }
}
