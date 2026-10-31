#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Bootstrap elevation-gate tests for install.ps1 (issue #493).

.DESCRIPTION
    install.ps1 needs an elevated shell, so a non-elevated run confirms with
    the user and relaunches through the Windows admin prompt. The helpers are
    extracted from the script's AST and Start-Process is always mocked, so
    nothing here raises a real admin prompt or runs the imperative body.
#>

BeforeAll {
    $script:repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:installPath = Join-Path $script:repoRoot 'install.ps1'

    $tokens = $null
    $errors = $null
    $script:installAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:installPath, [ref]$tokens, [ref]$errors)
    $errors | Should -BeNullOrEmpty -Because 'install.ps1 must parse'

    $wanted = @(
        'Test-IsElevated'
        'Test-EngineInstalled'
        'Get-ElevatedRelaunchHost'
        'Get-ElevatedRelaunchStartInfo'
        'Get-ElevatedRelaunchArgument'
        'Confirm-ElevatedRelaunch'
        'Invoke-ElevationGate'
    )
    $script:installAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false) | Where-Object Name -In $wanted | ForEach-Object {
        . ([scriptblock]::Create($_.Extent.Text))
    }
}

Describe 'install.ps1 -- Get-ElevatedRelaunchHost' -Tag 'Light', 'Meta' {

    It 'relaunches in the PowerShell the user is already running' {
        Get-ElevatedRelaunchHost -HostPath 'C:\Program Files\PowerShell\7\pwsh.exe' -Edition 'Core' |
            Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        Get-ElevatedRelaunchHost -HostPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Edition 'Desktop' |
            Should -Be 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'launches Store pwsh by name, not by its versioned package path' {
        Get-ElevatedRelaunchHost -HostPath 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.9.0_x64__8wekyb3d8bbwe\pwsh.exe' -Edition 'Core' |
            Should -Be 'pwsh.exe'
    }

    It 'never drops PowerShell 7 to Windows PowerShell when the path is unusable' {
        Get-ElevatedRelaunchHost -HostPath $null -Edition 'Core' | Should -Be 'pwsh.exe'
        Get-ElevatedRelaunchHost -HostPath 'C:\Program Files\Editor\editor.exe' -Edition 'Core' | Should -Be 'pwsh.exe'
    }

    It 'falls back to Windows PowerShell for a Windows PowerShell host' {
        Get-ElevatedRelaunchHost -HostPath 'C:\Program Files\Editor\editor.exe' -Edition 'Desktop' |
            Should -Be 'powershell.exe'
        Get-ElevatedRelaunchHost -HostPath $null -Edition 'Desktop' | Should -Be 'powershell.exe'
    }
}

Describe 'install.ps1 -- Get-ElevatedRelaunchStartInfo' -Tag 'Light', 'Meta' {

    It 'starts the shell directly outside Windows Terminal' {
        $start = Get-ElevatedRelaunchStartInfo -ShellPath 'pwsh.exe' -ShellArgument '-NoExit' -InTerminal $false
        $start.FilePath | Should -Be 'pwsh.exe'
        $start.ArgumentList | Should -Be '-NoExit'
    }

    It 'opens the same shell in Windows Terminal, quoting a path with spaces' {
        $start = Get-ElevatedRelaunchStartInfo -ShellPath 'C:\Program Files\PowerShell\7\pwsh.exe' -ShellArgument '-NoExit' -InTerminal $true
        $start.FilePath | Should -Be 'wt.exe'
        $start.ArgumentList | Should -Be 'new-tab -- "C:\Program Files\PowerShell\7\pwsh.exe" -NoExit'
    }

    It 'keeps a semicolon in a path from splitting the Windows Terminal command' {
        # wt reads a bare ';' as a separator between its own subcommands.
        $start = Get-ElevatedRelaunchStartInfo -ShellPath 'pwsh.exe' -ShellArgument '-File "D:\a;b\install.ps1"' -InTerminal $true
        $start.ArgumentList | Should -Be 'new-tab -- "pwsh.exe" -File "D:\a\;b\install.ps1"'
    }
}

Describe 'install.ps1 -- Get-ElevatedRelaunchArgument' -Tag 'Light', 'Meta' {

    It 'relaunches a saved copy by its path, quoted for spaces' {
        Get-ElevatedRelaunchArgument -ScriptPath 'C:\My Files\install.ps1' |
            Should -Match '-File "C:\\My Files\\install\.ps1"$'
    }

    It 'relaunches the published one-liner when there is no file (iex)' {
        # Under `iex (irm ...)` $PSCommandPath is empty.
        $relaunch = Get-ElevatedRelaunchArgument -ScriptPath ''
        $relaunch | Should -Match '-Command "iex \(irm https://raw\.githubusercontent\.com/MarkMichaelis/ScoopBucket/main/install\.ps1\)"$'
        (Get-Content -LiteralPath (Join-Path $script:repoRoot 'README.md') -Raw) |
            Should -Match ([regex]::Escape('iex (irm https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/install.ps1)'))
    }

    It 'keeps the elevated window open so the outcome can be read' {
        Get-ElevatedRelaunchArgument -ScriptPath '' | Should -Match '-NoExit'
        Get-ElevatedRelaunchArgument -ScriptPath 'C:\x\install.ps1' | Should -Match '-NoExit'
    }

    It 'can run a saved copy under a restrictive execution policy' {
        Get-ElevatedRelaunchArgument -ScriptPath 'C:\x\install.ps1' | Should -Match '-ExecutionPolicy Bypass'
    }
}

Describe 'install.ps1 -- Confirm-ElevatedRelaunch' -Tag 'Light', 'Meta' {

    It 'treats a host that cannot prompt as declined' {
        # `pwsh -NonInteractive` throws from PromptForChoice rather than asking.
        $result = pwsh -NoProfile -NonInteractive -Command @"
. ([scriptblock]::Create(@'
$(($script:installAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object Name -EQ 'Confirm-ElevatedRelaunch').Extent.Text)
'@))
Confirm-ElevatedRelaunch
"@
        $result | Should -Be 'False'
    }
}

Describe 'install.ps1 -- Invoke-ElevationGate' -Tag 'Light', 'Meta' {

    BeforeEach {
        Mock Start-Process { }
        Mock Write-Host { }
    }

    It 'proceeds silently when already elevated' {
        Mock Test-IsElevated { $true }
        Mock Confirm-ElevatedRelaunch { throw 'must not prompt' }

        Invoke-ElevationGate -ScriptPath '' | Should -BeTrue
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'relaunches elevated and stops this run once confirmed' {
        Mock Test-IsElevated { $false }
        Mock Confirm-ElevatedRelaunch { $true }

        Invoke-ElevationGate -ScriptPath 'C:\x\install.ps1' | Should -BeFalse
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $Verb -eq 'RunAs' -and $ArgumentList -match 'install\.ps1'
        }
    }

    It 'relaunches through Windows Terminal when the run started in it' {
        Mock Test-IsElevated { $false }
        Mock Confirm-ElevatedRelaunch { $true }
        Mock Test-EngineInstalled { $true } -ParameterFilter { $Name -eq 'wt' }
        $saved = $env:WT_SESSION
        try {
            $env:WT_SESSION = 'session'
            Invoke-ElevationGate -ScriptPath 'C:\x\install.ps1' | Should -BeFalse
        } finally {
            $env:WT_SESSION = $saved
        }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'wt.exe' -and $Verb -eq 'RunAs' -and $ArgumentList -match '^new-tab -- '
        }
    }

    It 'starts the shell directly when Windows Terminal is not available' {
        Mock Test-IsElevated { $false }
        Mock Confirm-ElevatedRelaunch { $true }
        Mock Test-EngineInstalled { $false } -ParameterFilter { $Name -eq 'wt' }
        $saved = $env:WT_SESSION
        try {
            $env:WT_SESSION = 'session'
            Invoke-ElevationGate -ScriptPath '' | Should -BeFalse
        } finally {
            $env:WT_SESSION = $saved
        }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -ne 'wt.exe' }
    }

    It 'starts the shell directly when the run did not start in Windows Terminal' {
        Mock Test-IsElevated { $false }
        Mock Confirm-ElevatedRelaunch { $true }
        Mock Test-EngineInstalled { $true } -ParameterFilter { $Name -eq 'wt' }
        $saved = $env:WT_SESSION
        try {
            $env:WT_SESSION = $null
            Invoke-ElevationGate -ScriptPath '' | Should -BeFalse
        } finally {
            $env:WT_SESSION = $saved
        }
        # This suite runs on PowerShell 7, so the running edition must reach the choice.
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match 'pwsh(\.exe)?$' }
    }

    It 'never relaunches when the user declines, and says what to do' {
        Mock Test-IsElevated { $false }
        Mock Confirm-ElevatedRelaunch { $false }

        { Invoke-ElevationGate -ScriptPath '' } | Should -Throw '*elevated*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'reports a cancelled admin prompt with the same guidance' {
        Mock Test-IsElevated { $false }
        Mock Confirm-ElevatedRelaunch { $true }
        Mock Start-Process { throw 'The operation was canceled by the user.' }

        { Invoke-ElevationGate -ScriptPath '' } | Should -Throw '*elevated*canceled by the user*'
    }
}

Describe 'install.ps1 -- elevation gate placement' -Tag 'Light', 'Meta' {

    BeforeAll {
        $script:bodyStatements = $script:installAst.EndBlock.Statements |
            Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }
    }

    It 'runs before any statement that changes the machine' {
        # Only the process-scoped execution-policy bump may precede it.
        $gate = @($script:bodyStatements | Where-Object { $_.Extent.Text -match 'Invoke-ElevationGate' })
        $gate.Count | Should -Be 1
        $before = @($script:bodyStatements | Where-Object { $_.Extent.StartOffset -lt $gate[0].Extent.StartOffset })
        $before.Count | Should -Be 1
        $before[0].Extent.Text | Should -Match 'Set-ExecutionPolicy Bypass -Scope Process'
    }

    It 'stops with return, because exit would close the shell that ran iex' {
        $gate = $script:bodyStatements | Where-Object { $_.Extent.Text -match 'Invoke-ElevationGate' }
        $gate.Extent.Text | Should -Match '\breturn\b'
        $gate.Extent.Text | Should -Match '-ScriptPath \$PSCommandPath' -Because 'a saved copy must relaunch itself'
        $gate.Extent.Text | Should -Not -Match '\bexit\b'
        $exits = $script:installAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.ExitStatementAst]
            }, $true)
        @($exits).Count | Should -Be 0
    }
}
