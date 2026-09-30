#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Bootstrap engine-probe tests for install.ps1 (issue #432).

.DESCRIPTION
    install.ps1 used to probe for an engine with
    `Get-Command scoop -ErrorAction Ignore`. That guard is satisfied by the
    `scoop` / `choco` wrapper FUNCTIONS this repo's module exports -- and
    Get-Command's module auto-discovery finds them through PSModulePath even
    in a shell that never imported the module. The bootstrap therefore
    reported "scoop is installed" on machines with no scoop at all and
    silently skipped the install, leaving a half-populated scoop root.

    The decision logic lives in pure, parameterized helpers inside
    install.ps1. These tests extract those helpers from the script's AST and
    exercise them directly, so nothing here touches a real install, a real
    PATH registry hive, or C:\ProgramData\scoop.
#>

BeforeAll {
    $script:repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:installPath = Join-Path $script:repoRoot 'install.ps1'
    $script:installPath | Should -Exist

    $tokens = $null
    $errors = $null
    $script:installAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:installPath, [ref]$tokens, [ref]$errors)
    $errors | Should -BeNullOrEmpty -Because 'install.ps1 must parse'

    $script:installFunctions = $script:installAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false)

    # Dot-source only the helper functions -- never the imperative body,
    # which would install Chocolatey and scoop on the test machine.
    $wanted = @(
        'Test-EngineInstalled'
        'Select-EngineCommandPath'
        'Resolve-ScoopRoot'
        'Get-ScoopInstallState'
        'Get-ScoopRootBackupPath'
        'Merge-PathValue'
        'Test-DirectoryEmpty'
        'Update-PathFromRegistry'
        'Move-OrphanedScoopRoot'
        'Install-ScoopEngine'
    )
    foreach ($fn in $script:installFunctions) {
        if ($fn.Name -in $wanted) { . ([scriptblock]::Create($fn.Extent.Text)) }
    }
}

Describe 'install.ps1 -- Test-EngineInstalled' -Tag 'Light', 'Meta' {

    It 'is not satisfied by a PowerShell function named scoop' {
        # THE regression this issue is about: module/.../Private/Legacy.ps1
        # defines and exports `function scoop`, and Get-Command finds it via
        # module auto-discovery even in a shell that never imported the
        # module. A wrapper must never count as an installed engine.
        #
        # PATH is emptied for the duration so the assertion holds on a
        # machine that also has a real scoop on PATH (like CI).
        function scoop { 'wrapper' }

        $savedPath = $env:Path
        try {
            $env:Path = ''
            (Get-Command scoop -ErrorAction Ignore) |
                Should -Not -BeNullOrEmpty -Because 'the wrapper function is in scope'
            Test-EngineInstalled -Name 'scoop' |
                Should -BeFalse -Because 'a Function is not an installed engine'
        } finally {
            $env:Path = $savedPath
        }
    }

    It 'is not satisfied by an alias named after the engine' {
        $name = 'choco_alias_probe_432'
        Set-Alias -Name $name -Value Get-Date -Scope Local
        (Get-Command $name -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
        Test-EngineInstalled -Name $name | Should -BeFalse
    }

    It 'is satisfied by a real executable on PATH' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("engine432_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $savedPath = $env:Path
        try {
            Set-Content -LiteralPath (Join-Path $dir 'fakeengine432.cmd') -Value '@echo off' -Encoding ascii
            $env:Path = "$dir;$env:Path"
            Test-EngineInstalled -Name 'fakeengine432' | Should -BeTrue
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is satisfied by an external script on PATH (scoop.ps1 shim)' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("engine432_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $savedPath = $env:Path
        try {
            Set-Content -LiteralPath (Join-Path $dir 'scriptengine432.ps1') -Value '"hi"' -Encoding ascii
            $env:Path = "$dir;$env:Path"
            Test-EngineInstalled -Name 'scriptengine432' | Should -BeTrue
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'install.ps1 -- Select-EngineCommandPath' -Tag 'Light', 'Meta' {

    It 'prefers the ExternalScript shim so the engine keeps emitting objects' {
        $candidates = @(
            [pscustomobject]@{ CommandType = 'Application';    Source = 'C:\scoop\shims\scoop.cmd' }
            [pscustomobject]@{ CommandType = 'ExternalScript'; Source = 'C:\scoop\shims\scoop.ps1' }
        )
        Select-EngineCommandPath -Candidate $candidates | Should -Be 'C:\scoop\shims\scoop.ps1'
    }

    It 'falls back to an Application when no script shim resolved' {
        $candidates = @([pscustomobject]@{ CommandType = 'Application'; Source = 'C:\ProgramData\chocolatey\bin\choco.exe' })
        Select-EngineCommandPath -Candidate $candidates | Should -Be 'C:\ProgramData\chocolatey\bin\choco.exe'
    }

    It 'returns nothing when the engine did not resolve' {
        Select-EngineCommandPath -Candidate @() | Should -BeNullOrEmpty
        Select-EngineCommandPath -Candidate $null | Should -BeNullOrEmpty
    }
}

Describe 'install.ps1 -- Resolve-ScoopRoot' -Tag 'Light', 'Meta' {

    It 'honors an existing SCOOP value' {
        Resolve-ScoopRoot -ScoopEnvValue 'D:\myscoop' -ProgramDataPath 'C:\ProgramData' |
            Should -Be 'D:\myscoop'
    }

    It 'falls back to the ProgramData scoop root when SCOOP is unset' {
        Resolve-ScoopRoot -ScoopEnvValue '' -ProgramDataPath 'C:\ProgramData' |
            Should -Be 'C:\ProgramData\scoop'
        Resolve-ScoopRoot -ScoopEnvValue $null -ProgramDataPath 'C:\ProgramData' |
            Should -Be 'C:\ProgramData\scoop'
    }
}

Describe 'install.ps1 -- Get-ScoopInstallState' -Tag 'Light', 'Meta' {

    It 'reports Installed only when the engine resolves AND apps\scoop exists' {
        Get-ScoopInstallState -CommandFound $true -AppDirExists $true -RootExists $true -RootIsEmpty $false |
            Should -Be 'Installed'
    }

    It 'reports Orphaned when the root is populated but apps\scoop is missing' {
        # The state seen in the wild: leftover apps\ + shims\, no apps\scoop.
        # The upstream installer hard-fails here with Deny-Install
        # "exists and is not empty", so the bootstrap must move it aside.
        Get-ScoopInstallState -CommandFound $false -AppDirExists $false -RootExists $true -RootIsEmpty $false |
            Should -Be 'Orphaned'
    }

    It 'reports Orphaned when a stale shim resolves but the app dir is gone' {
        Get-ScoopInstallState -CommandFound $true -AppDirExists $false -RootExists $true -RootIsEmpty $false |
            Should -Be 'Orphaned'
    }

    It 'reports Unlinked -- never Orphaned -- when apps\scoop exists but PATH does not resolve scoop' {
        # A shell opened before scoop landed on Machine PATH has a stale
        # $env:Path, so the command probe says "missing" for a perfectly good
        # install. Classifying that as Orphaned would move a working scoop
        # root -- global apps, persist\, buckets and all -- aside and
        # reinstall from scratch. Never do that.
        Get-ScoopInstallState -CommandFound $false -AppDirExists $true -RootExists $true -RootIsEmpty $false |
            Should -Be 'Unlinked'
    }

    It 'reports Missing when the root is absent or empty' {
        Get-ScoopInstallState -CommandFound $false -AppDirExists $false -RootExists $false -RootIsEmpty $true |
            Should -Be 'Missing'
        Get-ScoopInstallState -CommandFound $false -AppDirExists $false -RootExists $true -RootIsEmpty $true |
            Should -Be 'Missing'
    }
}

Describe 'install.ps1 -- Get-ScoopRootBackupPath' -Tag 'Light', 'Meta' {

    It 'derives a sibling backup path stamped with the supplied timestamp' {
        Get-ScoopRootBackupPath -Root 'C:\ProgramData\scoop' -Timestamp '20260101-120000' |
            Should -Be 'C:\ProgramData\scoop.orphaned-20260101-120000'
    }

    It 'ignores a trailing separator on the root' {
        Get-ScoopRootBackupPath -Root 'C:\ProgramData\scoop\' -Timestamp '20260101-120000' |
            Should -Be 'C:\ProgramData\scoop.orphaned-20260101-120000'
    }
}

Describe 'install.ps1 -- Merge-PathValue' -Tag 'Light', 'Meta' {

    It 'concatenates Machine then User PATH' {
        Merge-PathValue -MachinePath 'C:\a;C:\b' -UserPath 'C:\c' | Should -Be 'C:\a;C:\b;C:\c'
    }

    It 'de-dupes case-insensitively while preserving order' {
        Merge-PathValue -MachinePath 'C:\a;C:\b' -UserPath 'c:\A;C:\d' | Should -Be 'C:\a;C:\b;C:\d'
    }

    It 'tolerates empty hives and empty segments' {
        Merge-PathValue -MachinePath $null -UserPath 'C:\c' | Should -Be 'C:\c'
        Merge-PathValue -MachinePath 'C:\a;;C:\b' -UserPath '' | Should -Be 'C:\a;C:\b'
    }
}

Describe 'install.ps1 -- Test-DirectoryEmpty' -Tag 'Light', 'Meta' {

    BeforeEach {
        $script:probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("empty432_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:probeDir -Force | Out-Null
    }

    AfterEach {
        icacls $script:probeDir /reset /t /q 2>&1 | Out-Null
        Remove-Item -LiteralPath $script:probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports a missing path as empty' {
        Test-DirectoryEmpty -Path (Join-Path $script:probeDir 'nope') | Should -BeTrue
    }

    It 'reports an empty directory as empty' {
        Test-DirectoryEmpty -Path $script:probeDir | Should -BeTrue
    }

    It 'reports a populated directory as not empty, hidden entries included' {
        $file = Join-Path $script:probeDir '.hidden'
        Set-Content -LiteralPath $file -Value 'x' -Encoding ascii
        (Get-Item -LiteralPath $file -Force).Attributes = 'Hidden'
        Test-DirectoryEmpty -Path $script:probeDir | Should -BeFalse
    }

    It 'fails closed: an unreadable directory is not reported as empty' {
        # Swallowing the access-denied error and reading the resulting empty
        # collection as "empty" would route a populated-but-locked-down scoop
        # root straight past the orphan handling.
        Set-Content -LiteralPath (Join-Path $script:probeDir 'payload.txt') -Value 'x' -Encoding ascii
        icacls $script:probeDir /deny "$([Environment]::UserName):(OI)(CI)(RX)" 2>&1 | Out-Null
        $probe = @(Get-ChildItem -LiteralPath $script:probeDir -Force -ErrorAction SilentlyContinue)
        if ($probe.Count -gt 0) {
            Set-ItResult -Skipped -Because 'this process can still enumerate the directory despite the deny ACE'
            return
        }
        Test-DirectoryEmpty -Path $script:probeDir -WarningAction SilentlyContinue | Should -BeFalse
    }
}

Describe 'install.ps1 -- Install-ScoopEngine' -Tag 'Light', 'Meta' {

    BeforeEach {
        $script:fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("scooproot432_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:fakeRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:fakeRoot 'keepme.txt') -Value 'x' -Encoding ascii
        $script:savedPath = $env:Path
        $script:savedScoop = $env:SCOOP
    }

    AfterEach {
        $env:Path = $script:savedPath
        $env:SCOOP = $script:savedScoop
        Remove-Item -LiteralPath $script:fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'scooproot432_*' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'leaves an Installed root completely alone' {
        Install-ScoopEngine -Root $script:fakeRoot -State 'Installed'
        Test-Path -LiteralPath (Join-Path $script:fakeRoot 'keepme.txt') | Should -BeTrue
        $env:SCOOP | Should -Be $script:savedScoop
    }

    It 'never moves or reinstalls an Unlinked root' {
        # No -WhatIf here on purpose: the real code path must be
        # non-destructive, not merely previewable.
        Install-ScoopEngine -Root $script:fakeRoot -State 'Unlinked' -WarningAction SilentlyContinue
        Test-Path -LiteralPath (Join-Path $script:fakeRoot 'keepme.txt') | Should -BeTrue
        @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter "$(Split-Path $script:fakeRoot -Leaf).orphaned-*" -ErrorAction SilentlyContinue).Count |
            Should -Be 0
    }

    It 'moves nothing for an Orphaned root under -WhatIf' {
        Install-ScoopEngine -Root $script:fakeRoot -State 'Orphaned' -WhatIf -WarningAction SilentlyContinue
        Test-Path -LiteralPath (Join-Path $script:fakeRoot 'keepme.txt') | Should -BeTrue
    }

    It 'skips the install when the orphaned root was not moved aside' {
        # Declining (or -WhatIf-ing) the move must not fall through into the
        # installer, which would hit Deny-Install on the populated root.
        Move-OrphanedScoopRoot -Root $script:fakeRoot -WhatIf | Should -BeFalse
        Test-Path -LiteralPath $script:fakeRoot | Should -BeTrue
    }

    It 'moves an orphaned root to the timestamped sibling path' {
        Move-OrphanedScoopRoot -Root $script:fakeRoot -WarningAction SilentlyContinue | Should -BeTrue
        Test-Path -LiteralPath $script:fakeRoot | Should -BeFalse
        @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter "$(Split-Path $script:fakeRoot -Leaf).orphaned-*" -ErrorAction SilentlyContinue).Count |
            Should -Be 1
    }
}

Describe 'install.ps1 -- engine guards' -Tag 'Light', 'Meta' {

    It 'never calls Get-Command without restricting -CommandType' {
        $bare = $script:installAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Get-Command'
            }, $true) | Where-Object {
            $_.Extent.Text -notmatch '-CommandType'
        }
        ($bare | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty `
            -Because 'an unrestricted Get-Command matches the module''s scoop/choco wrapper functions'
    }

    It 'probes choco, scoop and git through Test-EngineInstalled' {
        $probed = $script:installAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Test-EngineInstalled'
            }, $true) | ForEach-Object { $_.Extent.Text }

        foreach ($engine in 'choco', 'scoop', 'git') {
            ($probed -join "`n") | Should -Match "'$engine'"
        }
    }

    It 'invokes the resolved scoop executable rather than the bare wrapper name' {
        $addBucket = $script:installFunctions | Where-Object Name -EQ 'Add-ScoopBucket'
        $addBucket | Should -Not -BeNullOrEmpty

        $bareEngineCalls = $addBucket.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -in @('scoop', 'choco')
            }, $true) | ForEach-Object { $_.Extent.Text }

        $bareEngineCalls | Should -BeNullOrEmpty -Because 'Add-ScoopBucket must not depend on the module wrapper'
    }

    It 'refreshes PATH before probing whether scoop is installed' {
        # A stale $env:Path makes the command probe say "missing" for a good
        # install, which used to classify the root as orphaned.
        function Get-ScriptBodyCalls {
            param([string]$Name, [type[]]$Forbidden)
            $script:installAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq $Name
                }, $true) | Where-Object {
                $nested = $false
                $p = $_.Parent
                while ($p) {
                    if ($Forbidden | Where-Object { $p -is $_ }) { $nested = $true; break }
                    $p = $p.Parent
                }
                -not $nested
            }
        }

        $inFunction = [System.Management.Automation.Language.FunctionDefinitionAst]
        $conditional = [System.Management.Automation.Language.IfStatementAst]

        # The refresh must be unconditional: the one inside the choco `if`
        # only runs when choco was missing.
        $refresh = @(Get-ScriptBodyCalls -Name 'Update-PathFromRegistry' -Forbidden $inFunction, $conditional)
        $probe = @(Get-ScriptBodyCalls -Name 'Test-EngineInstalled' -Forbidden @($inFunction) |
                Where-Object { $_.Extent.Text -match "'scoop'" })
        $probe.Count | Should -Be 1
        $refresh.Count | Should -BeGreaterThan 0
        ($refresh | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Minimum).Minimum |
            Should -BeLessThan $probe[0].Extent.StartOffset
    }

    It 'refreshes PATH after installing an engine' {
        ($script:installFunctions | Where-Object Name -EQ 'Update-PathFromRegistry') |
            Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $script:installPath -Raw) |
            Should -Match 'Update-PathFromRegistry'
    }
}
