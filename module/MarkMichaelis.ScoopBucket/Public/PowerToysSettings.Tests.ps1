<#
.SYNOPSIS
    Light-suite Pester coverage for the PowerToys settings snapshot feature
    (Export-PowerToysSettings / Import-PowerToysSettings and their private
    scrub/exclude/write-set/guard helpers).

.DESCRIPTION
    Pins the security-critical behavior:

      * Secret + machine-identity values (MouseWithoutBorders SecurityKey,
        MachineID, etc.) are neutralized, while every shortcut / hotkey and the
        enabled-module list are preserved verbatim.
      * The residual-secret guard fails the export if a secret survives.
      * Volatile files (Logs, telemetry, update-state) are excluded.
      * The write-set projection refuses path-traversal entries.
      * Export captures a real tree and Import re-applies it, stopping PowerToys
        first.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path $PSScriptRoot '..\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
}

Describe 'Get-PowerToysScrubbedObject' -Tag 'Light', 'Module' {
    It 'neutralizes the MouseWithoutBorders SecurityKey but keeps its hotkeys and switches' {
        $obj = '{"properties":{"SecurityKey":{"value":"qF7$gU9"},"HotKeySwitchMachine":{"value":112},"ShareClipboard":{"value":true}}}' | ConvertFrom-Json
        $scrubbed = & $script:mod { param($o) Get-PowerToysScrubbedObject -InputObject $o } $obj

        $scrubbed.properties.SecurityKey.value          | Should -Be ''
        $scrubbed.properties.HotKeySwitchMachine.value  | Should -Be 112
        $scrubbed.properties.ShareClipboard.value       | Should -BeTrue
    }

    It 'does not touch shortcut/hotkey property names that merely contain "key"' {
        $obj = '{"advanced-paste-ui-hotkey":{"win":true,"code":86},"paste-as-plain-hotkey":{"code":86}}' | ConvertFrom-Json
        $scrubbed = & $script:mod { param($o) Get-PowerToysScrubbedObject -InputObject $o } $obj

        $scrubbed.'advanced-paste-ui-hotkey'.code | Should -Be 86
        $scrubbed.'paste-as-plain-hotkey'.code    | Should -Be 86
    }

    It 'neutralizes machine-identity fields inside the value wrapper, keeping the shape' {
        $obj = '{"MachineID":{"value":1097481455},"MachineMatrixString":[],"Name2IP":{"value":"host"}}' | ConvertFrom-Json
        $scrubbed = & $script:mod { param($o) Get-PowerToysScrubbedObject -InputObject $o } $obj

        $scrubbed.MachineID.value     | Should -Be 0
        $scrubbed.Name2IP.value       | Should -Be ''
        @($scrubbed.MachineMatrixString).Count | Should -Be 0
    }
}

Describe 'Get-PowerToysSnapshotViolation' -Tag 'Light', 'Module' {
    It 'reports a residual non-empty secret value (wrapper shape)' {
        $obj = '{"properties":{"SecurityKey":{"value":"leak"},"HotKeySwitchMachine":{"value":112}}}' | ConvertFrom-Json
        $violations = & $script:mod { param($o) Get-PowerToysSnapshotViolation -InputObject $o } $obj
        $violations.Count | Should -BeGreaterThan 0
        $violations -join ' ' | Should -Match 'SecurityKey'
    }

    It 'returns nothing for a scrubbed object' {
        $obj = '{"properties":{"SecurityKey":{"value":""},"HotKeySwitchMachine":{"value":112}}}' | ConvertFrom-Json
        $violations = & $script:mod { param($o) Get-PowerToysSnapshotViolation -InputObject $o } $obj
        @($violations).Count | Should -Be 0
    }
}

Describe 'Test-PowerToysPathExcluded' -Tag 'Light', 'Module' {
    It 'excludes volatile log/telemetry/update-state paths but keeps real settings' {
        $cases = @{
            'Logs\backend.log'              = $true
            'RunnerLogs\x.txt'              = $true
            'etw\trace.etl'                 = $true
            'UpdateState.json'              = $true
            'last_version_run.json'         = $true
            'settings-telemetry.json'       = $true
            'settings.json'                 = $false
            'FancyZones\settings.json'      = $false
            'Keyboard Manager\default.json' = $false
        }
        foreach ($path in $cases.Keys) {
            $actual = & $script:mod { param($p) Test-PowerToysPathExcluded -RelativePath $p } $path
            $actual | Should -Be $cases[$path] -Because "path '$path'"
        }
    }
}

Describe 'ConvertTo-PowerToysWriteSet' -Tag 'Light', 'Module' {
    It 'projects each snapshot file to a target path and JSON' {
        $snap = '{"files":{"settings.json":{"enabled":{"FancyZones":true}},"FancyZones/settings.json":{"zones":1}}}' | ConvertFrom-Json
        $set = & $script:mod { param($s) ConvertTo-PowerToysWriteSet -Snapshot $s -SettingsRoot 'C:\pt' } $snap

        @($set).Count | Should -Be 2
        ($set | Where-Object RelativePath -eq 'settings.json').FullPath | Should -Be 'C:\pt\settings.json'
        ($set | Where-Object RelativePath -eq 'settings.json').Json     | Should -Match 'FancyZones'
    }

    It 'refuses a path-traversal entry' {
        $snap = '{"files":{"../evil.json":{"x":1}}}' | ConvertFrom-Json
        { & $script:mod { param($s) ConvertTo-PowerToysWriteSet -Snapshot $s -SettingsRoot 'C:\pt' } $snap } |
            Should -Throw '*unsafe path*'
    }
}

Describe 'Export-PowerToysSettings' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:src = Join-Path $TestDrive ('pt-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:src 'MouseWithoutBorders') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:src 'FancyZones') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:src 'Logs') -Force | Out-Null
        Set-Content -Path (Join-Path $script:src 'settings.json') -Value '{"enabled":{"FancyZones":true,"MouseWithoutBorders":true}}'
        Set-Content -Path (Join-Path $script:src 'MouseWithoutBorders\settings.json') -Value '{"properties":{"SecurityKey":{"value":"qF7$gU9"},"HotKeySwitchMachine":{"value":112}}}'
        Set-Content -Path (Join-Path $script:src 'FancyZones\settings.json') -Value '{"zones":3}'
        Set-Content -Path (Join-Path $script:src 'Logs\backend.log') -Value 'noise'
    }

    It 'captures enabled modules and shortcuts but scrubs the SecurityKey' {
        $snap = Export-PowerToysSettings -SettingsRoot $script:src
        $snap.files.'settings.json'.enabled.MouseWithoutBorders               | Should -BeTrue
        $snap.files.'MouseWithoutBorders/settings.json'.properties.HotKeySwitchMachine.value | Should -Be 112
        $snap.files.'MouseWithoutBorders/settings.json'.properties.SecurityKey.value         | Should -Be ''
        $snap.files.'FancyZones/settings.json'.zones                          | Should -Be 3
    }

    It 'excludes volatile log files from the snapshot' {
        $snap = Export-PowerToysSettings -SettingsRoot $script:src
        $names = $snap.files.PSObject.Properties.Name
        $names | Should -Not -Contain 'Logs/backend.log'
    }

    It 'writes indented JSON when -Path is given and the written file carries no SecurityKey value' {
        $out = Join-Path $TestDrive 'snapshot.json'
        Export-PowerToysSettings -SettingsRoot $script:src -Path $out | Out-Null
        Test-Path $out | Should -BeTrue
        $raw = Get-Content $out -Raw
        $raw | Should -Not -Match 'qF7'
    }
}

Describe 'Import-PowerToysSettings' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:snapshotPath = Join-Path $TestDrive 'snap.json'
        $script:live = Join-Path $TestDrive ('live-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:live -Force | Out-Null
        @'
{
  "schema": 1,
  "files": {
    "settings.json": { "enabled": { "FancyZones": true } },
    "FancyZones/settings.json": { "zones": 5 }
  }
}
'@ | Set-Content -Path $script:snapshotPath
        Mock -ModuleName MarkMichaelis.ScoopBucket Stop-PowerToysProcess { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Start-PowerToysProcess { }
    }

    It 'writes each snapshot file into the live settings folder and stops PowerToys first' {
        $result = Import-PowerToysSettings -SnapshotPath $script:snapshotPath -SettingsRoot $script:live
        Test-Path (Join-Path $script:live 'settings.json')            | Should -BeTrue
        Test-Path (Join-Path $script:live 'FancyZones\settings.json') | Should -BeTrue
        (Get-Content (Join-Path $script:live 'FancyZones\settings.json') -Raw) | Should -Match '"zones": 5'
        $result.FileCount | Should -Be 2
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Stop-PowerToysProcess -Times 1 -Exactly
    }

    It 'restarts PowerToys by default but not with -NoRestart' {
        Import-PowerToysSettings -SnapshotPath $script:snapshotPath -SettingsRoot $script:live | Out-Null
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Start-PowerToysProcess -Times 1 -Exactly

        Import-PowerToysSettings -SnapshotPath $script:snapshotPath -SettingsRoot $script:live -NoRestart | Out-Null
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Start-PowerToysProcess -Times 1 -Exactly
    }

    It 'writes nothing under -WhatIf' {
        Import-PowerToysSettings -SnapshotPath $script:snapshotPath -SettingsRoot $script:live -WhatIf | Out-Null
        Test-Path (Join-Path $script:live 'settings.json') | Should -BeFalse
    }

    It 'throws when the snapshot file is missing' {
        { Import-PowerToysSettings -SnapshotPath (Join-Path $TestDrive 'nope.json') -SettingsRoot $script:live } |
            Should -Throw '*snapshot not found*'
    }
}
