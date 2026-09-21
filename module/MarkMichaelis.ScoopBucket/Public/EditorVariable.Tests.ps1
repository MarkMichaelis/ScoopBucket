#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior tests for Set-DefaultEditorVariable (issue #419).

.DESCRIPTION
    Installing VS Code points EDITOR at `code --wait` so every CLI tool that
    shells out to an editor (git without core.editor, npm, gh, ...) opens
    VS Code and waits for the file to be saved and closed.

    The consequential behavior is WHEN it declines to write:

      * unset         -> set it.
      * `code`        -> ours, and broken without --wait; normalize it.
      * `vim`, `code-insiders --wait`, ... -> a deliberate choice; keep it.

    Every test here drives -Scope Process, so the decision is exercised end to
    end against a real environment variable that dies with the test process.
    Nothing in this file can write a machine-scope value: the Machine branch is
    covered separately, with elevation forced false.
#>

BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $moduleManifest -Force

    $script:OriginalEditor = $env:EDITOR
}

AfterAll {
    $env:EDITOR = $script:OriginalEditor
}

Describe 'Set-DefaultEditorVariable claims EDITOR only when it is free' -Tag 'Light' {

    BeforeEach { $env:EDITOR = $null }
    AfterEach  { $env:EDITOR = $null }

    It 'sets it when nothing has claimed it' {
        $result = Set-DefaultEditorVariable -Scope Process 6>$null

        $env:EDITOR | Should -Be 'code --wait'
        $result.Action | Should -Be 'Set'
        $result.Previous | Should -BeNullOrEmpty
    }

    It 'changes nothing when it is already exactly right' {
        $env:EDITOR = 'code --wait'

        $result = Set-DefaultEditorVariable -Scope Process 6>$null

        $env:EDITOR | Should -Be 'code --wait'
        $result.Action | Should -Be 'Unchanged'
    }

    It 'repairs a bare `code`, which forks and loses the edit' {
        # The classic broken setting: without --wait the caller reads back an
        # unedited file. It is our own value, so fixing it is not a clobber.
        $env:EDITOR = 'code'

        $result = Set-DefaultEditorVariable -Scope Process 6>$null

        $env:EDITOR | Should -Be 'code --wait'
        $result.Action | Should -Be 'Set'
        $result.Previous | Should -Be 'code'
    }

    It 'repairs a full-path VS Code value, quoted or not' -ForEach @(
        @{ Value = 'C:\Program Files\Microsoft VS Code\bin\code.cmd --wait' }
        @{ Value = '"C:\Program Files\Microsoft VS Code\bin\code.cmd"' }
    ) {
        $env:EDITOR = $Value

        $result = Set-DefaultEditorVariable -Scope Process 6>$null

        $env:EDITOR | Should -Be 'code --wait'
        $result.Action | Should -Be 'Set'
    }

    It 'leaves <_> alone -- a deliberate choice is not ours to revert' -ForEach @(
        'vim', 'nano', 'notepad', 'code-insiders --wait', 'C:\tools\vim\vim.exe'
    ) {
        $env:EDITOR = $_

        $result = Set-DefaultEditorVariable -Scope Process 6>$null

        $env:EDITOR | Should -Be $_ -Because 'the user picked this editor on purpose'
        $result.Action | Should -Be 'Kept'
        $result.Previous | Should -Be $_
    }

    It 'writes nothing under -WhatIf' {
        Set-DefaultEditorVariable -Scope Process -WhatIf 6>$null

        $env:EDITOR | Should -BeNullOrEmpty
    }

    It 'is idempotent -- a second run changes nothing' {
        $first  = Set-DefaultEditorVariable -Scope Process 6>$null
        $second = Set-DefaultEditorVariable -Scope Process 6>$null

        $first.Action  | Should -Be 'Set'
        $second.Action | Should -Be 'Unchanged'
        $env:EDITOR    | Should -Be 'code --wait'
    }
}

Describe 'Set-DefaultEditorVariable at Machine scope without elevation' -Tag 'Light' {

    BeforeAll {
        $script:MachineEditorBefore = [Environment]::GetEnvironmentVariable('EDITOR', 'Machine')
    }

    BeforeEach {
        # Machine scope needs admin. Force the unelevated path so this test can
        # never write a machine-scope value, on a developer box or an elevated
        # CI runner alike.
        Mock Test-IsElevated -ModuleName MarkMichaelis.ScoopBucket { $false }
        $env:EDITOR = $null
    }

    AfterEach { $env:EDITOR = $null }

    It 'warns instead of throwing, so the package is not marked Failed' {
        # Prove the mock is in effect BEFORE anything that could write, so a
        # mocking regression fails the test instead of mutating the host.
        (& (Get-Module MarkMichaelis.ScoopBucket) { Test-IsElevated }) |
            Should -BeFalse -Because 'this test must never reach the elevated write path'

        { Set-DefaultEditorVariable 3>$null 6>$null | Out-Null } | Should -Not -Throw

        [Environment]::GetEnvironmentVariable('EDITOR', 'Machine') |
            Should -Be $script:MachineEditorBefore -Because 'an unelevated run must not attempt the write'
    }

    It 'still points the current session at VS Code' -Skip:(
        [bool][Environment]::GetEnvironmentVariable('EDITOR', 'Machine')
    ) {
        # Skipped on a host that already has a machine-scope EDITOR: the
        # session mirror is decided by the MACHINE value, so only a host
        # without one exercises the "ours to set" path deterministically.
        (& (Get-Module MarkMichaelis.ScoopBucket) { Test-IsElevated }) |
            Should -BeFalse -Because 'this test must never reach the elevated write path'

        $env:EDITOR = 'notepad'
        $result = Set-DefaultEditorVariable 3>$null 6>$null

        $result.Action | Should -Be 'Skipped' -Because 'the machine write needs elevation'
        $env:EDITOR | Should -Be 'code --wait' `
            -Because 'the first git commit after an install should not need a fresh shell'
    }
}
