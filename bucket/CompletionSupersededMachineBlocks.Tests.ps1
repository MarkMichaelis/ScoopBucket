#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# Completion blocks superseded by the per-user profile are removed from the
# machine profile (#540).
#
# Before #397, completion blocks were written to $PROFILE.AllUsersAllHosts
# ($PSHOME\profile.ps1). #397 moved them to $PROFILE.CurrentUserAllHosts but
# never cleaned up, so a machine that registered completions earlier carries
# two blocks per CLI, and the stale machine copy loads first. These tests
# drive the cleanup against sandbox profiles only.
# ----------------------------------------------------------------------------

BeforeAll {
    $script:psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket

    function script:Block {
        param([Parameter(Mandatory)][string]$Cli, [string]$Version = 'v1')
        "# ScoopBucket:CliCompletion:${Cli}:BEGIN $Version`r`nif (Get-Command $Cli -ErrorAction SilentlyContinue) { . 'C:\nowhere\$Cli.ps1' }`r`n# ScoopBucket:CliCompletion:${Cli}:END`r`n"
    }

    function script:New-MachineProfile {
        param([Parameter(Mandatory)][string]$Content)
        $path = Join-Path $TestDrive ("machine-" + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
        $path
    }

    function script:Invoke-Removal {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentUserContent,
            [Parameter(Mandatory)][string]$MachinePath,
            [switch]$WhatIf
        )
        & $script:mod {
            param($c, $p, $w)
            Remove-SupersededCompletionBlock -CurrentUserContent $c -LegacyProfilePath $p -WhatIf:$w
        } $CurrentUserContent $MachinePath $WhatIf.IsPresent
    }
}

Describe 'Remove-SupersededCompletionBlock' -Tag 'Light','Completion' {

    It 'removes a machine block the current-user profile also has, and leaves everything else' {
        $machine = script:New-MachineProfile -Content ("Import-Module posh-git`r`n`r`n" + (script:Block alpha) + "`r`n" + (script:Block beta) + "# keep-me`r`n")
        $currentUser = script:Block alpha 'v4'

        $rows = @(script:Invoke-Removal -CurrentUserContent $currentUser -MachinePath $machine)

        $after = Get-Content -Raw $machine
        $after | Should -Not -Match 'CliCompletion:alpha:'
        $after | Should -Match 'CliCompletion:beta:BEGIN' -Because 'a block with no current-user counterpart may be the only registration'
        $after | Should -Match 'Import-Module posh-git'
        $after | Should -Match '# keep-me'
        $rows.Count | Should -Be 1
        $rows[0].Cli | Should -Be 'alpha'
        $rows[0].Action | Should -Be 'Removed'
        $rows[0].Reason | Should -Match ([regex]::Escape($machine))
    }

    It 'removes every copy when the machine profile holds the same block twice' {
        $machine = script:New-MachineProfile -Content ((script:Block alpha) + (script:Block alpha))
        $rows = @(script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $machine)
        Get-Content -Raw $machine | Should -Not -Match 'CliCompletion:alpha:'
        $rows.Count | Should -Be 1
    }

    It 'finds nothing to do on a second run' {
        $machine = script:New-MachineProfile -Content ("# head`r`n" + (script:Block alpha) + (script:Block beta))
        $currentUser = script:Block alpha 'v4'
        script:Invoke-Removal -CurrentUserContent $currentUser -MachinePath $machine | Out-Null
        $hash = (Get-FileHash $machine).Hash

        $rows = @(script:Invoke-Removal -CurrentUserContent $currentUser -MachinePath $machine 3>&1)

        $rows | Should -BeNullOrEmpty -Because 'a second run must neither report nor warn'
        (Get-FileHash $machine).Hash | Should -Be $hash
    }

    It 'reports WhatIf rows and writes nothing under -WhatIf' {
        $machine = script:New-MachineProfile -Content (script:Block alpha)
        $hash = (Get-FileHash $machine).Hash
        $rows = @(script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $machine -WhatIf)
        $rows.Count | Should -Be 1
        $rows[0].Action | Should -Be 'WhatIf'
        (Get-FileHash $machine).Hash | Should -Be $hash
    }

    It 'warns once, naming the file and elevation, and writes nothing when the machine profile is not writable' {
        $machine = script:New-MachineProfile -Content ((script:Block alpha) + (script:Block beta))
        $hash = (Get-FileHash $machine).Hash
        Mock -ModuleName MarkMichaelis.ScoopBucket Move-Item { throw [System.UnauthorizedAccessException]::new('Access to the path is denied.') }

        $out = @(script:Invoke-Removal -CurrentUserContent ((script:Block alpha 'v4') + (script:Block beta 'v4')) -MachinePath $machine 3>&1)

        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $rows = @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Match ([regex]::Escape($machine))
        $warnings[0].Message | Should -Match 'elevated'
        $warnings[0].Message | Should -Match '\b2\b' -Because 'the warning gives the count of blocks left behind'
        @($rows | ForEach-Object Action | Select-Object -Unique) | Should -Be @('Skipped')
        (Get-FileHash $machine).Hash | Should -Be $hash
        @(Get-ChildItem -Path (Split-Path $machine) -Filter "$(Split-Path $machine -Leaf)*.tmp") | Should -BeNullOrEmpty -Because 'the temporary file must not be left behind'
    }

    It 'does nothing when there is no machine profile' {
        $missing = Join-Path $TestDrive 'no-such-machine-profile.ps1'
        @(script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $missing) | Should -BeNullOrEmpty
        Test-Path $missing | Should -BeFalse
    }
}

Describe 'Resolve-SupersededCompletionProfilePath' -Tag 'Light','Completion' {

    It 'never targets the real machine profile when -ProfilePath is overridden' {
        & $script:mod { Resolve-SupersededCompletionProfilePath -OverridePath 'C:\sandbox\profile.ps1' } | Should -BeNullOrEmpty
    }

    It 'targets AllUsersAllHosts otherwise' {
        & $script:mod { Resolve-SupersededCompletionProfilePath } | Should -Be $PROFILE.AllUsersAllHosts
    }
}

Describe 'Update-PackageCompletion removes superseded machine blocks' -Tag 'Light','Completion' {

    It 'removes the machine copy of a CLI it preserves, and shows the removal in the default view' {
        $cli = 'pwsh'
        $fakeBundle = [pscustomobject]@{
            Bundle   = 'Test'
            Packages = @(
                [pscustomobject]@{
                    Name = 'TestPkg'; CliCommands = @($cli); Completion = 'native'
                    HasNativeCommandScript = $true
                    NativeCommandOutputs = @{ $cli = "Register-ArgumentCompleter -Native -CommandName $cli -ScriptBlock { } # superseded" }
                    NativeCommandScript = $null
                }
            )
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { @($fakeBundle) }
        $machine = script:New-MachineProfile -Content ("Import-Module posh-git`r`n`r`n" + (script:Block $cli))
        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-SupersededCompletionProfilePath { $machine }

        $emptyBucket = Join-Path $TestDrive 'empty-bucket'
        New-Item -ItemType Directory -Path $emptyBucket -Force | Out-Null
        $dir = Join-Path $TestDrive 'user'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $profilePath = Join-Path $dir 'profile.ps1'
        Set-Content -Path $profilePath -Value '' -NoNewline
        # First run registers the current-user block (and so already
        # supersedes the machine copy).
        Update-PackageCompletion -BucketPath $emptyBucket -ProfilePath $profilePath -Confirm:$false 6>$null | Out-Null
        Get-Content -Raw $machine | Should -Not -Match "CliCompletion:${cli}:"
        Get-Content -Raw $machine | Should -Match 'Import-Module posh-git'

        # A preserving run (no -Force) also cleans up, and the default
        # changed-only view shows it.
        [System.IO.File]::AppendAllText($machine, (script:Block $cli))
        $rows = @(Update-PackageCompletion -BucketPath $emptyBucket -ProfilePath $profilePath -Confirm:$false 6>$null)
        $removed = @($rows | Where-Object { $_.Cli -eq $cli -and $_.Action -eq 'Removed' })
        $removed.Count | Should -Be 1
        Get-Content -Raw $machine | Should -Not -Match "CliCompletion:${cli}:"
    }
}
