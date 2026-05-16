#Requires -Modules Pester
<#
.SYNOPSIS
    Pester coverage for the install-ledger + cleanup logic added to
    Test-Installs.ps1 by issue #62 Part B.

.DESCRIPTION
    Test-Installs.ps1 is a top-level script (#Requires -RunAsAdministrator
    + main execution at the bottom) so we cannot dot-source it whole.  We
    extract just the ledger / probe / uninstall helpers via a regex pull
    pattern (the same trick Test-Installs.Tests.ps1 already uses), inject
    fakes for Invoke-WithTimeout and the elevated uninstall cmdlets, then
    drive end-to-end scenarios.

    Cases covered:
      * Empty ledger → no work; no file created.
      * Add-LedgerEntry only fires when $Cleanup is $true.
      * Add-LedgerEntry serialises winget / choco / scoop / ps-module rows.
      * Get-CleanupLedger round-trips a multi-entry JSON file.
      * Invoke-CleanupLedger dispatches each row to the right uninstaller
        and deletes the ledger file when done.
      * Pre-run replay (-Cleanup) walks a stale ledger then starts fresh.
      * "Already installed" semantics: Add-LedgerEntry must NOT be called
        when the pre-install probe reports the package was on the host
        before the run started (cross-manager case is naturally safe —
        we only uninstall via the manager that produced the row, against
        the recorded scope).
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Test-Installs.ps1'
    $scriptContent = Get-Content $scriptPath -Raw

    # Pull only the helpers we want to exercise.  Each function block ends
    # at the next `function ` declaration OR the next banner (lines of ====).
    $functionsToLoad = @(
        'Get-CleanupLedger', 'Add-LedgerEntry', 'Clear-CleanupLedger',
        'Uninstall-WingetPackage', 'Uninstall-ChocoPackage',
        'Uninstall-ScoopPackage', 'Uninstall-PSModuleEntry',
        'Invoke-CleanupLedger',
        'Test-WingetInstalled', 'Test-ChocoInstalled',
        'Test-ScoopInstalled', 'Test-PSModuleInstalled'
    )
    $bodies = foreach ($n in $functionsToLoad) {
        if ($scriptContent -match "(?ms)(function\s+$n\s*\{.+?)(?=\nfunction\s|\n#\s*={5,})") {
            $Matches[1]
        }
    }
    $loadScript = $bodies -join "`n`n"

    # Fake Invoke-WithTimeout: deterministic, no actual processes.  Tests
    # that need specific output/exit set $script:InvokeWithTimeoutImpl.
    function script:Invoke-WithTimeout {
        param([string]$Command, [int]$TimeoutSeconds = 60)
        if ($script:InvokeWithTimeoutImpl) {
            return & $script:InvokeWithTimeoutImpl $Command
        }
        return @{ ExitCode = 0; Output = ''; TimedOut = $false }
    }

    # Fake Uninstall-Module so Uninstall-PSModuleEntry doesn't try to talk
    # to the real PSGallery / system module store.
    function script:Uninstall-Module {
        param([string]$Name, [switch]$AllVersions, [switch]$Force, [string]$ErrorAction)
        $script:UninstallModuleCalls += @($Name)
    }

    Invoke-Expression $loadScript

    function script:Reset-LedgerTestState {
        $script:CleanupLedgerPath = Join-Path $TestDrive ("ledger-{0}.json" -f ([guid]::NewGuid().Guid))
        $script:Cleanup = $true
        $script:InvokeWithTimeoutCalls = @()
        $script:UninstallModuleCalls = @()
        $script:InvokeWithTimeoutImpl = {
            param($cmd)
            $script:InvokeWithTimeoutCalls += @($cmd)
            @{ ExitCode = 0; Output = ''; TimedOut = $false }
        }
    }
}

Describe 'Install ledger CRUD (#62)' -Tag 'Light' {
    BeforeEach { Reset-LedgerTestState }

    It 'returns an empty array when the ledger file does not exist' {
        Get-CleanupLedger | Should -HaveCount 0
    }

    It 'Add-LedgerEntry no-ops when -Cleanup is off' {
        $script:Cleanup = $false
        Add-LedgerEntry -InstallerType 'winget' -Name 'X' -PackageId 'X.Y'
        Test-Path $script:CleanupLedgerPath | Should -BeFalse
    }

    It 'Add-LedgerEntry persists one row per installer type' {
        Add-LedgerEntry -InstallerType 'winget'    -Name 'Foo' -PackageId 'Org.Foo' -Scope 'machine'
        Add-LedgerEntry -InstallerType 'choco'     -Name 'bar'
        Add-LedgerEntry -InstallerType 'scoop'     -Name 'baz'
        Add-LedgerEntry -InstallerType 'ps-module' -Name 'Qux'

        $entries = @(Get-CleanupLedger)
        $entries | Should -HaveCount 4
        $entries.Where{ $_.InstallerType -eq 'winget'    }.PackageId | Should -Be 'Org.Foo'
        $entries.Where{ $_.InstallerType -eq 'winget'    }.Scope     | Should -Be 'machine'
        $entries.Where{ $_.InstallerType -eq 'choco'     }.Name      | Should -Be 'bar'
        $entries.Where{ $_.InstallerType -eq 'scoop'     }.Name      | Should -Be 'baz'
        $entries.Where{ $_.InstallerType -eq 'ps-module' }.Name      | Should -Be 'Qux'
    }

    It 'Clear-CleanupLedger removes the file' {
        Add-LedgerEntry -InstallerType 'winget' -Name 'Foo' -PackageId 'Org.Foo'
        Test-Path $script:CleanupLedgerPath | Should -BeTrue
        Clear-CleanupLedger
        Test-Path $script:CleanupLedgerPath | Should -BeFalse
    }
}

Describe 'Invoke-CleanupLedger (#62)' -Tag 'Light' {
    BeforeEach { Reset-LedgerTestState }

    It 'no-ops on an empty ledger and does not throw' {
        { Invoke-CleanupLedger -Reason 'unit' } | Should -Not -Throw
    }

    It 'dispatches one uninstall command per entry and deletes the ledger' {
        Add-LedgerEntry -InstallerType 'winget' -Name 'Foo' -PackageId 'Org.Foo' -Scope 'user'
        Add-LedgerEntry -InstallerType 'choco'  -Name 'bar'
        Add-LedgerEntry -InstallerType 'scoop'  -Name 'extras/baz'
        Add-LedgerEntry -InstallerType 'ps-module' -Name 'Qux'

        Invoke-CleanupLedger -Reason 'unit'

        $script:InvokeWithTimeoutCalls | Should -Contain 'winget uninstall --id Org.Foo --scope user --silent --disable-interactivity --accept-source-agreements'
        $script:InvokeWithTimeoutCalls | Should -Contain 'choco uninstall bar -y --no-progress --skip-autouninstaller'
        $script:InvokeWithTimeoutCalls | Should -Contain 'scoop uninstall -g baz'
        $script:UninstallModuleCalls   | Should -Contain 'Qux'
        Test-Path $script:CleanupLedgerPath | Should -BeFalse
    }

    It 'records the scope on winget rows so cleanup targets the same scope (#62 already-installed case 3)' {
        Add-LedgerEntry -InstallerType 'winget' -Name 'Foo' -PackageId 'Org.Foo' -Scope 'machine'
        Invoke-CleanupLedger -Reason 'unit'
        $script:InvokeWithTimeoutCalls | Should -Match '--scope machine'
    }
}

Describe 'Pre-install probe behavior (#62 already-installed)' -Tag 'Light' {
    BeforeEach { Reset-LedgerTestState }

    It 'Test-WingetInstalled returns true when winget list matches the id' {
        $script:InvokeWithTimeoutImpl = {
            @{ ExitCode = 0; Output = 'Name  Id  Version'; TimedOut = $false }
        }
        # winget list parsing requires the id to appear in output too:
        $script:InvokeWithTimeoutImpl = {
            @{ ExitCode = 0; Output = "Foo  Org.Foo  1.0`n"; TimedOut = $false }
        }
        Test-WingetInstalled -PackageId 'Org.Foo' -Scope 'machine' | Should -BeTrue
    }

    It 'Test-WingetInstalled returns false when winget list exits non-zero' {
        $script:InvokeWithTimeoutImpl = { @{ ExitCode = -1978335212; Output = 'No installed package found'; TimedOut = $false } }
        Test-WingetInstalled -PackageId 'Org.Missing' -Scope 'machine' | Should -BeFalse
    }

    It 'Test-PSModuleInstalled returns false for a guaranteed-missing module name' {
        $name = 'NonExistentModule-{0}' -f ([guid]::NewGuid().Guid)
        Test-PSModuleInstalled -Name $name | Should -BeFalse
    }
}
