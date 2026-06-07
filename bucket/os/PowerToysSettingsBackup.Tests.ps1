#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Tests for bucket/os/PowerToysSettingsBackup.ps1.
.DESCRIPTION
    The pure decision helpers (settings/backup path resolution, exclusion
    filtering) are unit-tested directly, and the imperative backup/restore
    copy is exercised against TestDrive folders so the behaviour -- which
    files travel and which volatile files are skipped -- is verified without
    a real PowerToys install. Process control (Stop/Start-PowerToysProcess)
    is mocked.

    The bundle script gates its main orchestration on
    $MyInvocation.InvocationName -ne '.', so dot-sourcing only defines the
    functions without running a backup.
#>

# Discovery-time dot-source so helpers are visible to It blocks.
. "$PSScriptRoot\PowerToysSettingsBackup.ps1"

BeforeAll {
    . "$PSScriptRoot\PowerToysSettingsBackup.ps1"
}

Describe 'Get-PowerToysSettingsRoot' -Tag 'Light' {
    It 'returns the explicit override when supplied' {
        Get-PowerToysSettingsRoot -Override 'X:\custom\PowerToys' -LocalAppData 'C:\Users\me\AppData\Local' |
            Should -Be 'X:\custom\PowerToys'
    }

    It 'defaults to <LocalAppData>\Microsoft\PowerToys' {
        Get-PowerToysSettingsRoot -LocalAppData 'C:\Users\me\AppData\Local' |
            Should -Be 'C:\Users\me\AppData\Local\Microsoft\PowerToys'
    }
}

Describe 'Resolve-PowerToysBackupRoot' -Tag 'Light' {
    It 'returns the explicit override when supplied' {
        Resolve-PowerToysBackupRoot -Override 'D:\backups\pt' -OneDrive 'C:\Users\me\OneDrive' -UserProfile 'C:\Users\me' |
            Should -Be 'D:\backups\pt'
    }

    It 'uses a OneDrive-synced folder when OneDrive is configured' {
        Resolve-PowerToysBackupRoot -OneDrive 'C:\Users\me\OneDrive' -UserProfile 'C:\Users\me' |
            Should -Be 'C:\Users\me\OneDrive\Backups\PowerToys'
    }

    It 'falls back to the user profile when OneDrive is not configured' {
        Resolve-PowerToysBackupRoot -OneDrive '' -UserProfile 'C:\Users\me' |
            Should -Be 'C:\Users\me\PowerToys-SettingsBackup'
    }
}

Describe 'Select-PowerToysBackupRelativePath' -Tag 'Light' {
    It 'keeps general and per-module settings files' {
        $paths = @('settings.json', 'FancyZones\settings.json', 'Keyboard Manager\default.json')
        $kept = Select-PowerToysBackupRelativePath -RelativePath $paths
        $kept | Should -Be $paths
    }

    It 'drops volatile log, etw, and update-state files' {
        $paths = @(
            'settings.json'
            'Logs\backend.log'
            'etw\trace.etl'
            'UpdateState.json'
            'last_version_run.json'
            'FancyZones\settings.json'
        )
        $kept = Select-PowerToysBackupRelativePath -RelativePath $paths
        $kept | Should -Be @('settings.json', 'FancyZones\settings.json')
    }

    It 'matches exclusion patterns case-insensitively' {
        $kept = Select-PowerToysBackupRelativePath -RelativePath @('LOGS\x.txt', 'keep.json')
        $kept | Should -Be @('keep.json')
    }

    It 'matches a forward-slash separated path the same as a backslash one' {
        $kept = Select-PowerToysBackupRelativePath -RelativePath @('Logs/app.log', 'PowerRename/settings.json')
        $kept | Should -Be @('PowerRename/settings.json')
    }
}

Describe 'Backup-PowerToysSettings' -Tag 'Light' {
    BeforeEach {
        $script:src = Join-Path $TestDrive 'src'
        $script:dst = Join-Path $TestDrive ('dst-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:src 'FancyZones') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:src 'Logs') -Force | Out-Null
        Set-Content -Path (Join-Path $script:src 'settings.json') -Value '{"enabled":{"FancyZones":true}}'
        Set-Content -Path (Join-Path $script:src 'FancyZones\settings.json') -Value '{"zones":1}'
        Set-Content -Path (Join-Path $script:src 'Logs\backend.log') -Value 'noise'
        Set-Content -Path (Join-Path $script:src 'UpdateState.json') -Value '{}'
    }

    It 'mirrors the kept setting files to the backup root' {
        $result = Backup-PowerToysSettings -SettingsRoot $script:src -BackupRoot $script:dst
        Test-Path (Join-Path $script:dst 'settings.json')             | Should -BeTrue
        Test-Path (Join-Path $script:dst 'FancyZones\settings.json')  | Should -BeTrue
        (Get-Content (Join-Path $script:dst 'FancyZones\settings.json') -Raw).Trim() | Should -Be '{"zones":1}'
        $result.FileCount | Should -Be 2
    }

    It 'does not copy volatile log or update-state files' {
        Backup-PowerToysSettings -SettingsRoot $script:src -BackupRoot $script:dst | Out-Null
        Test-Path (Join-Path $script:dst 'Logs\backend.log') | Should -BeFalse
        Test-Path (Join-Path $script:dst 'UpdateState.json') | Should -BeFalse
    }

    It 'throws when the settings folder does not exist' {
        { Backup-PowerToysSettings -SettingsRoot (Join-Path $TestDrive 'missing') -BackupRoot $script:dst } |
            Should -Throw '*not found*'
    }

    It 'copies nothing under -WhatIf' {
        Backup-PowerToysSettings -SettingsRoot $script:src -BackupRoot $script:dst -WhatIf | Out-Null
        Test-Path (Join-Path $script:dst 'settings.json') | Should -BeFalse
    }
}

Describe 'Restore-PowerToysSettings' -Tag 'Light' {
    BeforeEach {
        $script:backup = Join-Path $TestDrive 'backup'
        $script:live = Join-Path $TestDrive 'live'
        New-Item -ItemType Directory -Path (Join-Path $script:backup 'FancyZones') -Force | Out-Null
        New-Item -ItemType Directory -Path $script:live -Force | Out-Null
        Set-Content -Path (Join-Path $script:backup 'settings.json') -Value '{"restored":true}'
        Set-Content -Path (Join-Path $script:backup 'FancyZones\settings.json') -Value '{"zones":2}'
        Mock Stop-PowerToysProcess { }
        Mock Start-PowerToysProcess { }
    }

    It 'restores backup files into the live settings folder and stops PowerToys first' {
        $result = Restore-PowerToysSettings -BackupRoot $script:backup -SettingsRoot $script:live
        Test-Path (Join-Path $script:live 'settings.json')            | Should -BeTrue
        Test-Path (Join-Path $script:live 'FancyZones\settings.json') | Should -BeTrue
        $result.FileCount | Should -Be 2
        Should -Invoke Stop-PowerToysProcess -Times 1 -Exactly
    }

    It 'restarts PowerToys by default but not with -NoRestart' {
        Restore-PowerToysSettings -BackupRoot $script:backup -SettingsRoot $script:live | Out-Null
        Should -Invoke Start-PowerToysProcess -Times 1 -Exactly

        Restore-PowerToysSettings -BackupRoot $script:backup -SettingsRoot $script:live -NoRestart | Out-Null
        Should -Invoke Start-PowerToysProcess -Times 1 -Exactly
    }

    It 'throws when the backup folder does not exist' {
        { Restore-PowerToysSettings -BackupRoot (Join-Path $TestDrive 'nope') -SettingsRoot $script:live } |
            Should -Throw '*No PowerToys backup*'
    }
}
