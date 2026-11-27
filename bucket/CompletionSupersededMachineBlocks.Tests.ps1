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

    It 'keeps user code that sits between a block that lost its END and a later copy of that block' {
        $truncated = "# ScoopBucket:CliCompletion:alpha:BEGIN v1`r`nif (Get-Command alpha) { . 'x' }`r`n"
        $machine = script:New-MachineProfile -Content ($truncated + "Set-Alias ll Get-ChildItem # user-line-keep`r`n" + (script:Block alpha))
        script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $machine | Out-Null
        Get-Content -Raw $machine | Should -Match 'user-line-keep' -Because 'a removal must never span from one block''s BEGIN to another block''s END'
    }

    It 'keeps the machine copy when the current-user block for that CLI is incomplete' {
        $machine = script:New-MachineProfile -Content (script:Block alpha)
        $hash = (Get-FileHash $machine).Hash
        $incomplete = "# ScoopBucket:CliCompletion:alpha:BEGIN v4`r`n# (END line lost)`r`n"
        @(script:Invoke-Removal -CurrentUserContent $incomplete -MachinePath $machine) | Should -BeNullOrEmpty
        (Get-FileHash $machine).Hash | Should -Be $hash -Because 'the machine copy may be the only working registration'
    }

    It 'leaves a machine profile that is not UTF-8 untouched, and says so' {
        $path = Join-Path $TestDrive 'machine-cp1252.ps1'
        $text = "# caf" + [char]0xE9 + " note`r`n" + (script:Block alpha)
        [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::GetEncoding(1252))
        $hash = (Get-FileHash $path).Hash

        $out = @(script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $path 3>&1)

        (Get-FileHash $path).Hash | Should -Be $hash -Because 'rewriting non-UTF-8 text as UTF-8 would corrupt it'
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Match 'UTF-8'
    }

    It 'keeps a UTF-8 byte order mark' {
        $path = Join-Path $TestDrive 'machine-bom.ps1'
        [System.IO.File]::WriteAllText($path, ("# head`r`n" + (script:Block alpha)), [System.Text.UTF8Encoding]::new($true))
        script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $path | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        Get-Content -Raw $path | Should -Not -Match 'CliCompletion:alpha:'
    }

    It 'rewrites the machine profile in place, so an explicit ACL entry on it survives' {
        # Replacing the file (temp + move) would give it the folder's
        # inherited ACL and a new owner. (Creation time is no witness:
        # NTFS tunneling hands a re-created name its old creation time.)
        $machine = script:New-MachineProfile -Content ("# head`r`n" + (script:Block alpha))
        $everyone = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
        $acl = Get-Acl -LiteralPath $machine
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Read', 'Allow'))
        Set-Acl -LiteralPath $machine -AclObject $acl

        script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $machine | Out-Null

        Get-Content -Raw $machine | Should -Not -Match 'CliCompletion:alpha:'
        $explicit = @((Get-Acl -LiteralPath $machine).GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
            Where-Object { $_.IdentityReference -eq $everyone })
        $explicit.Count | Should -BeGreaterThan 0 -Because 'the file''s own ACL must not be replaced by the folder''s'
    }

    It 'warns once, naming the file and elevation, and writes nothing when the machine profile is not writable' {
        $machine = script:New-MachineProfile -Content ((script:Block alpha) + (script:Block beta))
        $hash = (Get-FileHash $machine).Hash
        Mock -ModuleName MarkMichaelis.ScoopBucket Set-Content { throw [System.UnauthorizedAccessException]::new('Access to the path is denied.') }

        $out = @(script:Invoke-Removal -CurrentUserContent ((script:Block alpha 'v4') + (script:Block beta 'v4')) -MachinePath $machine 3>&1)

        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $rows = @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Match ([regex]::Escape($machine))
        $warnings[0].Message | Should -Match 'elevated'
        $warnings[0].Message | Should -Match '\b2\b' -Because 'the warning gives the count of blocks left behind'
        @($rows | ForEach-Object Action | Select-Object -Unique) | Should -Be @('Skipped')
        (Get-FileHash $machine).Hash | Should -Be $hash
    }

    It 'does nothing when there is no machine profile' {
        $missing = Join-Path $TestDrive 'no-such-machine-profile.ps1'
        @(script:Invoke-Removal -CurrentUserContent (script:Block alpha 'v4') -MachinePath $missing) | Should -BeNullOrEmpty
        Test-Path $missing | Should -BeFalse
    }
}

Describe 'Completion block matching never spans another block' -Tag 'Light','Completion' {
    # The same lazy BEGIN..END pattern also drove the per-user profile
    # rewrites, so a block whose END was lost let a later END for the same
    # CLI pull everything in between into the match (#540 review).

    It 'Set-PackageCompletionProfileBlock replaces only the complete block, keeping code after a truncated one' {
        $content = "# ScoopBucket:CliCompletion:alpha:BEGIN v4`r`nold-partial`r`n" +
            "Set-Alias ll Get-ChildItem # user-line-keep`r`n" + (script:Block alpha 'v4')
        $new = & $script:mod { param($c) Set-PackageCompletionProfileBlock -Content $c -Cli 'alpha' -Block 'new-body' } $content
        $new | Should -Match 'user-line-keep'
        $new | Should -Match 'new-body'
    }

    It 'Set-CompletionProfileBlock (legacy) replaces only the complete block, keeping code after a truncated one' {
        $content = "# ScoopBucket:CliCompletion:alpha:BEGIN v1`r`nold-partial`r`n" +
            "Set-Alias ll Get-ChildItem # user-line-keep`r`n" + (script:Block alpha 'v1')
        $new = & $script:mod { param($c) Set-CompletionProfileBlock -Content $c -Cli 'alpha' -Block 'new-body' -Force } $content
        $new | Should -Match 'user-line-keep'
        $new | Should -Match 'new-body'
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
