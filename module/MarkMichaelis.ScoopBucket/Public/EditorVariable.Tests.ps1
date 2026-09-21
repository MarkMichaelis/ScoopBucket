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

Describe 'Set-DefaultEditorVariable at Machine scope' -Tag 'Light' {

    # The machine-scope value is read through Get-EditorVariable, so every
    # branch here is driven by a mock rather than by whatever this particular
    # host happens to have set. Nothing in this block can write a machine-scope
    # value: Test-IsElevated is forced false throughout, and each test asserts
    # the mock is live BEFORE anything that could write.

    BeforeAll {
        $script:MachineEditorBefore = [Environment]::GetEnvironmentVariable('EDITOR', 'Machine')
    }

    BeforeEach {
        Mock Test-IsElevated -ModuleName MarkMichaelis.ScoopBucket { $false }
        # Session reads stay real, so the mirror is exercised for real. Each
        # test then adds its own Machine-scope stub, which Pester prefers over
        # these.
        Mock Get-EditorVariable -ModuleName MarkMichaelis.ScoopBucket `
            -ParameterFilter { $Scope -eq 'Process' } {
            [Environment]::GetEnvironmentVariable('EDITOR', 'Process')
        }
        # Anything that matches NEITHER filter throws rather than falling
        # through to a real read. Most of these tests stub the machine value as
        # $null, which is also what a real read returns on nearly every host --
        # so a silently-unmatched filter (a renamed or dropped -Scope parameter
        # would do it) would leave them passing for the wrong reason, quietly
        # back to testing against host state. This is what fails instead.
        Mock Get-EditorVariable -ModuleName MarkMichaelis.ScoopBucket {
            throw "Get-EditorVariable was called in a way no stub matched (Scope='$Scope'). The machine-scope read must never reach the host from these tests."
        }
        $env:EDITOR = $null
    }

    AfterEach {
        $env:EDITOR = $null
        [Environment]::GetEnvironmentVariable('EDITOR', 'Machine') |
            Should -Be $script:MachineEditorBefore -Because 'no test here may touch the host machine value'
    }

    It 'warns instead of throwing, so the package is not marked Failed' {
        (& (Get-Module MarkMichaelis.ScoopBucket) { Test-IsElevated }) |
            Should -BeFalse -Because 'this test must never reach the elevated write path'
        Mock Get-EditorVariable -ModuleName MarkMichaelis.ScoopBucket -ParameterFilter { $Scope -eq 'Machine' } { $null }

        { Set-DefaultEditorVariable 3>$null 6>$null | Out-Null } | Should -Not -Throw

        (Set-DefaultEditorVariable 3>$null 6>$null).Action |
            Should -Be 'Skipped' -Because 'the machine write needs elevation'
    }

    It 'still points the current session at VS Code when the machine value is ours to set' {
        (& (Get-Module MarkMichaelis.ScoopBucket) { Test-IsElevated }) |
            Should -BeFalse -Because 'this test must never reach the elevated write path'
        Mock Get-EditorVariable -ModuleName MarkMichaelis.ScoopBucket -ParameterFilter { $Scope -eq 'Machine' } { $null }

        Set-DefaultEditorVariable 3>$null 6>$null | Out-Null

        $env:EDITOR | Should -Be 'code --wait' `
            -Because 'the first git commit after an install should not need a fresh shell'
    }

    It 'keeps a machine-wide editor that belongs to someone else, even unelevated' {
        (& (Get-Module MarkMichaelis.ScoopBucket) { Test-IsElevated }) |
            Should -BeFalse -Because 'this test must never reach the elevated write path'
        Mock Get-EditorVariable -ModuleName MarkMichaelis.ScoopBucket -ParameterFilter { $Scope -eq 'Machine' } { 'vim' }

        $result = Set-DefaultEditorVariable 3>$null 6>$null

        $result.Action | Should -Be 'Kept'
        $result.Previous | Should -Be 'vim'
        $env:EDITOR | Should -BeNullOrEmpty -Because 'a kept value must not be mirrored into the session either'
    }

    It 'leaves a session-local override alone even when the machine value is free' {
        # Exporting EDITOR in one shell is as deliberate a choice as a
        # machine-wide one, so the mirror applies the same ownership rule.
        (& (Get-Module MarkMichaelis.ScoopBucket) { Test-IsElevated }) |
            Should -BeFalse -Because 'this test must never reach the elevated write path'
        Mock Get-EditorVariable -ModuleName MarkMichaelis.ScoopBucket -ParameterFilter { $Scope -eq 'Machine' } { $null }
        $env:EDITOR = 'vim'

        Set-DefaultEditorVariable 3>$null 6>$null | Out-Null

        $env:EDITOR | Should -Be 'vim'
    }

    It 'writes nothing under -WhatIf' {
        (& (Get-Module MarkMichaelis.ScoopBucket) { Test-IsElevated }) |
            Should -BeFalse -Because 'this test must never reach the elevated write path'
        Mock Get-EditorVariable -ModuleName MarkMichaelis.ScoopBucket -ParameterFilter { $Scope -eq 'Machine' } { $null }

        $result = Set-DefaultEditorVariable -WhatIf 3>$null 6>$null

        $result.Action | Should -Be 'Skipped'
        $env:EDITOR | Should -BeNullOrEmpty
    }
}
