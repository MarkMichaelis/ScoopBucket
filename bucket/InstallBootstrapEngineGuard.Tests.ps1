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

    It 'refreshes PATH after installing an engine' {
        ($script:installFunctions | Where-Object Name -EQ 'Update-PathFromRegistry') |
            Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $script:installPath -Raw) |
            Should -Match 'Update-PathFromRegistry'
    }
}
