#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Tests for bucket/os/UpdateBucketOnWindowsUpdate.ps1 (the installer that
    registers the scheduled task) and Invoke-BucketUpdateAfterWindowsUpdate.ps1
    (the runner the task executes).

.DESCRIPTION
    Light tests never touch Task Scheduler, the event log, or a real update:
    Register-/Unregister-/Get-ScheduledTask, Get-WinEvent and Update-Package
    are mocked, and every path lives under TestDrive.

    Heavy tests register a REAL task, but always under a throwaway task name
    and task path, and remove it again. They never register the production
    task name and never fire the Windows Update trigger. There is deliberately
    no Install-LocalManifest test: the manifest installer registers the
    production task name, which is what the owner runs by hand, not CI.

    Both scripts gate their main orchestration on
    $MyInvocation.InvocationName -ne '.', so dot-sourcing only defines the
    functions.
#>

BeforeAll {
    $script:InstallerPath = Join-Path $PSScriptRoot 'UpdateBucketOnWindowsUpdate.ps1'
    $script:RunnerPath = Join-Path $PSScriptRoot 'Invoke-BucketUpdateAfterWindowsUpdate.ps1'
    . $script:InstallerPath
    . $script:RunnerPath
}

Describe 'Get-WindowsUpdateTaskSubscription' -Tag 'Light' {
    It 'subscribes to Event ID 19 from the WindowsUpdateClient provider in the System log' {
        $xml = [xml](Get-WindowsUpdateTaskSubscription)
        $xml.QueryList.Query.Path | Should -Be 'System'
        $select = $xml.QueryList.Query.Select
        $select.Path | Should -Be 'System'
        $select.'#text' | Should -Match "Provider\[@Name='Microsoft-Windows-WindowsUpdateClient'\]"
        $select.'#text' | Should -Match 'EventID=19\b'
    }
}

Describe 'Resolve-TaskPwshPath' -Tag 'Light' {
    It 'returns the first candidate that exists' {
        $missing = Join-Path $TestDrive 'missing\pwsh.exe'
        $present = Join-Path $TestDrive 'present\pwsh.exe'
        New-Item -ItemType File -Path $present -Force | Out-Null
        Resolve-TaskPwshPath -Candidate @($missing, $present) | Should -Be $present
    }

    It 'falls back to the bare pwsh.exe name (PATH lookup at run time) when no candidate exists' {
        Resolve-TaskPwshPath -Candidate @(Join-Path $TestDrive 'nope\pwsh.exe') | Should -Be 'pwsh.exe'
    }

    It 'never defaults to a version-pinned Store package path' {
        # The Store's versioned WindowsApps\Microsoft.PowerShell_<ver> folder
        # vanishes on the next pwsh update; the defaults must not include it.
        (Get-TaskPwshCandidate) | Where-Object { $_ -match 'Microsoft\.PowerShell_' } | Should -BeNullOrEmpty
    }
}

Describe 'New-WindowsUpdateTaskDefinition' -Tag 'Light' {
    BeforeAll {
        $script:def = New-WindowsUpdateTaskDefinition -RunnerPath 'C:\Runner Dir\runner.ps1' -LogRoot 'C:\Log Dir' -PwshPath 'C:\pwsh\pwsh.exe' -UserId 'DOMAIN\someone'
    }

    It 'runs pwsh non-interactively, without a profile, against the runner, passing the log root' {
        $def.Action.Execute | Should -Be 'C:\pwsh\pwsh.exe'
        $arguments = $def.Action.Arguments
        $arguments | Should -Match '-NoProfile'
        $arguments | Should -Match '-NonInteractive'
        $arguments | Should -Match '-WindowStyle Hidden'
        $arguments | Should -Match '-ExecutionPolicy Bypass'
        $arguments | Should -Match ([regex]::Escape('-File "C:\Runner Dir\runner.ps1"'))
        $arguments | Should -Match ([regex]::Escape('-LogRoot "C:\Log Dir"'))
    }

    It 'triggers on the Windows Update subscription with a debounce delay' {
        $def.Trigger.Subscription | Should -Be (Get-WindowsUpdateTaskSubscription)
        $def.Trigger.Delay | Should -Be 'PT10M'
        $def.Trigger.Enabled | Should -BeTrue
    }

    It 'never starts a second instance while one is running' {
        $def.Settings.MultipleInstances | Should -Be 'IgnoreNew'
    }

    It 'requires the network but not AC power' {
        $def.Settings.RunOnlyIfNetworkAvailable | Should -BeTrue
        $def.Settings.DisallowStartIfOnBatteries | Should -BeFalse
        $def.Settings.StopIfGoingOnBatteries | Should -BeFalse
    }

    It 'caps the run time so a hung update cannot hold the single instance forever' {
        $def.Settings.ExecutionTimeLimit | Should -Be 'PT2H'
    }

    It 'runs as the given user with highest privileges, without a stored password' {
        $def.Principal.UserId | Should -Be 'DOMAIN\someone'
        $def.Principal.RunLevel | Should -Be 'Highest'
        $def.Principal.LogonType | Should -Be 'Interactive'
    }
}

Describe 'Install-UpdateBucketOnWindowsUpdate' -Tag 'Light' {
    BeforeEach {
        $script:tdInstall = Join-Path $TestDrive ("install-" + [guid]::NewGuid())
        $script:tdLog = Join-Path $TestDrive ("log-" + [guid]::NewGuid())
        Mock Register-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName; TaskPath = $TaskPath; State = 'Ready' } }
        Mock Set-RunnerFolderAcl { }
    }

    It 'refuses to run unelevated, with an actionable message, and registers nothing' {
        Mock Test-IsElevated { $false }
        { Install-UpdateBucketOnWindowsUpdate -InstallRoot $script:tdInstall -LogRoot $script:tdLog } |
            Should -Throw -ExpectedMessage '*elevated*sudo scoop install*'
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Test-Path -LiteralPath $script:tdInstall | Should -BeFalse
    }

    It 'stages the runner in the install root and registers the task in place (-Force)' {
        Mock Test-IsElevated { $true }
        Install-UpdateBucketOnWindowsUpdate -TaskName 'T1' -TaskPath '\P1\' -InstallRoot $script:tdInstall -LogRoot $script:tdLog | Out-Null

        $staged = Join-Path $script:tdInstall 'Invoke-BucketUpdateAfterWindowsUpdate.ps1'
        Test-Path -LiteralPath $staged | Should -BeTrue
        (Get-FileHash $staged).Hash | Should -Be (Get-FileHash $script:RunnerPath).Hash
        Should -Invoke Set-RunnerFolderAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:tdInstall }
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'T1' -and $TaskPath -eq '\P1\' -and $Force -and
            $Action.Arguments -match ([regex]::Escape($staged)) -and
            $Action.Arguments -match ([regex]::Escape($script:tdLog))
        }
    }

    It 'is idempotent: a second run re-stages and re-registers without throwing' {
        Mock Test-IsElevated { $true }
        Install-UpdateBucketOnWindowsUpdate -InstallRoot $script:tdInstall -LogRoot $script:tdLog | Out-Null
        { Install-UpdateBucketOnWindowsUpdate -InstallRoot $script:tdInstall -LogRoot $script:tdLog | Out-Null } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $script:tdInstall -File).Count | Should -Be 1
        Should -Invoke Register-ScheduledTask -Times 2 -Exactly
    }
}

Describe 'Uninstall-UpdateBucketOnWindowsUpdate' -Tag 'Light' {
    BeforeEach {
        $script:tdInstall = Join-Path $TestDrive ("install-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tdInstall -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tdInstall 'Invoke-BucketUpdateAfterWindowsUpdate.ps1') -Value '# staged'
        Mock Unregister-ScheduledTask { }
        Mock Test-IsElevated { $true }
    }

    It 'unregisters an existing task and removes the staged runner' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'T1'; TaskPath = '\P1\' } }
        Uninstall-UpdateBucketOnWindowsUpdate -TaskName 'T1' -TaskPath '\P1\' -InstallRoot $script:tdInstall
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'T1' -and $TaskPath -eq '\P1\' -and $Confirm -eq $false
        }
        Test-Path -LiteralPath $script:tdInstall | Should -BeFalse
    }

    It 'is a no-op when the task and runner are already gone (twice-runnable)' {
        Mock Get-ScheduledTask { }
        Remove-Item -LiteralPath $script:tdInstall -Recurse -Force
        { Uninstall-UpdateBucketOnWindowsUpdate -TaskName 'T1' -TaskPath '\P1\' -InstallRoot $script:tdInstall } | Should -Not -Throw
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'refuses to remove an existing task unelevated, with an actionable message' {
        Mock Test-IsElevated { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'T1'; TaskPath = '\P1\' } }
        { Uninstall-UpdateBucketOnWindowsUpdate -TaskName 'T1' -TaskPath '\P1\' -InstallRoot $script:tdInstall } |
            Should -Throw -ExpectedMessage '*elevated*'
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Select-QualifyingWindowsUpdateEvent' -Tag 'Light' {
    BeforeAll {
        $script:since = [datetime]'2026-09-30T12:00:00'
        function New-Evt([string]$Title, [datetime]$At) { [pscustomobject]@{ TimeCreated = $At; Title = $Title } }
    }

    It 'keeps a real Windows update installed after the last run' {
        $evt = New-Evt '2026-09 Security Update (KB5129195) (26200.9457)' $since.AddMinutes(5)
        @(Select-QualifyingWindowsUpdateEvent -UpdateEvent $evt -Since $since).Count | Should -Be 1
    }

    It 'drops Defender definition updates and Store app updates by default' {
        $events = @(
            New-Evt 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.437.1.0)' $since.AddMinutes(1)
            New-Evt '9WZDNCRFJBH4-Microsoft.Windows.Photos' $since.AddMinutes(2)
        )
        @(Select-QualifyingWindowsUpdateEvent -UpdateEvent $events -Since $since).Count | Should -Be 0
    }

    It 'drops events at or before the last run (debounce across a burst)' {
        $events = @(
            New-Evt 'Intel Firmware Driver Update (18.1.21.2911)' $since
            New-Evt 'Intel Firmware Driver Update (18.1.21.2911)' $since.AddMinutes(-3)
        )
        @(Select-QualifyingWindowsUpdateEvent -UpdateEvent $events -Since $since).Count | Should -Be 0
    }

    It 'honours a caller-supplied exclusion list' {
        $evt = New-Evt 'Lenovo System Driver Update (26.7.0.7)' $since.AddMinutes(1)
        @(Select-QualifyingWindowsUpdateEvent -UpdateEvent $evt -Since $since -ExcludeTitlePattern @('Lenovo')).Count | Should -Be 0
        @(Select-QualifyingWindowsUpdateEvent -UpdateEvent $evt -Since $since -ExcludeTitlePattern @()).Count | Should -Be 1
    }
}

Describe 'Last-run marker' -Tag 'Light' {
    It 'round-trips the timestamp' {
        $path = Join-Path $TestDrive 'marker-roundtrip.txt'
        $at = [datetime]'2026-10-01T08:15:30.1234567'
        Set-BucketUpdateLastRun -Path $path -At $at
        Get-BucketUpdateLastRun -Path $path | Should -Be $at
    }

    It 'defaults to the given lookback when there is no marker yet' {
        $now = [datetime]'2026-10-01T08:00:00'
        Get-BucketUpdateLastRun -Path (Join-Path $TestDrive 'absent.txt') -Now $now -DefaultLookback ([timespan]::FromDays(1)) |
            Should -Be $now.AddDays(-1)
    }

    It 'treats an unreadable marker like a missing one' {
        $path = Join-Path $TestDrive 'marker-garbage.txt'
        Set-Content -LiteralPath $path -Value 'not a date'
        $now = [datetime]'2026-10-01T08:00:00'
        Get-BucketUpdateLastRun -Path $path -Now $now -DefaultLookback ([timespan]::FromDays(1)) |
            Should -Be $now.AddDays(-1)
    }
}

Describe 'Limit-BucketUpdateLog' -Tag 'Light' {
    It 'rotates the log to .1 once it exceeds the cap, replacing an older .1' {
        $log = Join-Path $TestDrive 'rotate.log'
        Set-Content -LiteralPath $log -Value ('x' * 200)
        Set-Content -LiteralPath "$log.1" -Value 'old'
        Limit-BucketUpdateLog -Path $log -MaxBytes 100
        Test-Path -LiteralPath $log | Should -BeFalse
        (Get-Content -LiteralPath "$log.1" -Raw) | Should -Match '^x{200}'
    }

    It 'leaves a log under the cap alone' {
        $log = Join-Path $TestDrive 'small.log'
        Set-Content -LiteralPath $log -Value 'small'
        Limit-BucketUpdateLog -Path $log -MaxBytes 1000
        Test-Path -LiteralPath $log | Should -BeTrue
        Test-Path -LiteralPath "$log.1" | Should -BeFalse
    }

    It 'tolerates a missing log' {
        { Limit-BucketUpdateLog -Path (Join-Path $TestDrive 'none.log') -MaxBytes 10 } | Should -Not -Throw
    }
}

Describe 'Invoke-BucketUpdateAfterWindowsUpdate' -Tag 'Light' {
    BeforeEach {
        $script:tdLog = Join-Path $TestDrive ("run-" + [guid]::NewGuid())
        $script:tdLogFile = Join-Path $script:tdLog 'UpdateBucketOnWindowsUpdate.log'
        Mock Update-Package { }
    }

    It 'skips the update (exit 0) when only excluded updates were installed, and records the check' {
        Mock Get-WindowsUpdateInstalledEvent { [pscustomobject]@{ TimeCreated = (Get-Date); Title = '9NBLGGH5R558-Microsoft.Todos' } }
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog | Should -Be 0
        Should -Invoke Update-Package -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:tdLog 'last-run.txt') | Should -BeTrue
        (Get-Content -LiteralPath $script:tdLogFile -Raw) | Should -Match 'skipp'
    }

    It 'runs the bucket-scoped update (not -MachineWide) when a real update was installed' {
        Mock Get-WindowsUpdateInstalledEvent { [pscustomobject]@{ TimeCreated = (Get-Date); Title = '2026-09 Security Update (KB5129195)' } }
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog | Should -Be 0
        Should -Invoke Update-Package -Times 1 -Exactly -ParameterFilter {
            ($Name -join ',') -eq '*' -and -not $MachineWide
        }
        (Get-Content -LiteralPath $script:tdLogFile -Raw) | Should -Match 'KB5129195'
    }

    It 'runs regardless of events under -Force' {
        Mock Get-WindowsUpdateInstalledEvent { }
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog -Force | Should -Be 0
        Should -Invoke Update-Package -Times 1 -Exactly
    }

    It 'logs every output stream of the update, so the owner can see what ran' {
        Mock Get-WindowsUpdateInstalledEvent { [pscustomobject]@{ TimeCreated = (Get-Date); Title = 'Some Driver Update' } }
        Mock Update-Package {
            Write-Host 'host line from update'
            Write-Warning 'warning line from update'
            'native-ish output line'
        }
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog | Should -Be 0
        $text = Get-Content -LiteralPath $script:tdLogFile -Raw
        $text | Should -Match 'host line from update'
        $text | Should -Match 'WARNING: warning line from update'
        $text | Should -Match 'native-ish output line'
    }

    It 'exits 1 when any package update failed' {
        Mock Get-WindowsUpdateInstalledEvent { [pscustomobject]@{ TimeCreated = (Get-Date); Title = 'Some Driver Update' } }
        Mock Update-Package {
            $r = [pscustomobject]@{ Operation = 'Update'; Status = 'Failed'; Name = 'ripgrep'; Reason = 'boom' }
            $r.PSObject.TypeNames.Insert(0, 'PackageResult')
            $r
        }
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog | Should -Be 1
        (Get-Content -LiteralPath $script:tdLogFile -Raw) | Should -Match 'ripgrep'
    }

    It 'exits 1 and logs the error when the update throws' {
        Mock Get-WindowsUpdateInstalledEvent { [pscustomobject]@{ TimeCreated = (Get-Date); Title = 'Some Driver Update' } }
        Mock Update-Package { throw 'bucket exploded' }
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog | Should -Be 1
        (Get-Content -LiteralPath $script:tdLogFile -Raw) | Should -Match 'bucket exploded'
    }

    It 'is twice-runnable: the second check sees no new events since the first' {
        $script:at = (Get-Date).AddMinutes(-1)
        Mock Get-WindowsUpdateInstalledEvent { [pscustomobject]@{ TimeCreated = $script:at; Title = 'Some Driver Update' } }
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog | Should -Be 0
        Invoke-BucketUpdateAfterWindowsUpdate -LogRoot $script:tdLog | Should -Be 0
        Should -Invoke Update-Package -Times 1 -Exactly
    }
}

Describe 'UpdateBucketOnWindowsUpdate manifest' -Tag 'Light' {
    BeforeAll {
        $script:Manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'UpdateBucketOnWindowsUpdate.json') | ConvertFrom-Json
    }

    It 'ships both the installer and the runner (scoop downloads only listed files)' {
        $script:Manifest.url | Should -Contain 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/bucket/os/UpdateBucketOnWindowsUpdate.ps1'
        $script:Manifest.url | Should -Contain 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/bucket/os/Invoke-BucketUpdateAfterWindowsUpdate.ps1'
    }

    It 'installer runs the installer script' {
        ($script:Manifest.installer.script -join "`n") | Should -Match 'UpdateBucketOnWindowsUpdate\.ps1'
    }

    It 'uninstaller removes the task with -Uninstall, but not during a scoop update (#401)' {
        $uninstall = $script:Manifest.uninstaller.script -join "`n"
        $uninstall | Should -Match 'UpdateBucketOnWindowsUpdate\.ps1.*-Uninstall'
        $uninstall | Should -Match ([regex]::Escape("if (((Get-PSCallStack).Command -contains 'update_app') -or (Get-Variable -Name old_version -ErrorAction SilentlyContinue)) { Write-Host 'scoop update in progress: skipping uninstaller (#401).'; return }"))
    }
}

Describe 'UpdateBucketOnWindowsUpdate registers a real task (throwaway name)' -Tag 'Heavy' {
    BeforeAll {
        $script:elevated = Test-IsElevated
        $script:tdTaskName = 'UpdateBucketOnWindowsUpdate-Test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:tdTaskPath = '\MarkMichaelis.ScoopBucket.Tests\'
        $script:tdInstall = Join-Path $TestDrive 'heavy-install'
        $script:tdLog = Join-Path $TestDrive 'heavy-log'
    }

    AfterAll {
        if ($script:elevated) {
            Get-ScheduledTask -TaskName $script:tdTaskName -TaskPath $script:tdTaskPath -ErrorAction SilentlyContinue |
                Unregister-ScheduledTask -Confirm:$false
        }
    }

    It 'registers the task, twice, and it carries the trigger, principal and action' {
        if (-not $script:elevated) { Set-ItResult -Skipped -Because 'registering a highest-privilege task requires an elevated session'; return }
        & $script:InstallerPath -TaskName $script:tdTaskName -TaskPath $script:tdTaskPath -InstallRoot $script:tdInstall -LogRoot $script:tdLog | Out-Null
        { & $script:InstallerPath -TaskName $script:tdTaskName -TaskPath $script:tdTaskPath -InstallRoot $script:tdInstall -LogRoot $script:tdLog | Out-Null } |
            Should -Not -Throw

        $task = Get-ScheduledTask -TaskName $script:tdTaskName -TaskPath $script:tdTaskPath
        @($task).Count | Should -Be 1
        $task.Triggers[0].Subscription | Should -Match 'EventID=19'
        $task.Triggers[0].Delay | Should -Be 'PT10M'
        $task.Principal.RunLevel | Should -Be 'Highest'
        $task.Settings.MultipleInstances | Should -Be 'IgnoreNew'
        $task.Actions[0].Arguments | Should -Match ([regex]::Escape($script:tdInstall))
    }

    It 'locks the staged runner so standard users cannot modify what runs elevated' {
        if (-not $script:elevated) { Set-ItResult -Skipped -Because 'requires the elevated install above'; return }
        $runner = Join-Path $script:tdInstall 'Invoke-BucketUpdateAfterWindowsUpdate.ps1'
        $acl = Get-Acl -LiteralPath $runner
        $acl.Owner | Should -Not -Match ([regex]::Escape($env:USERNAME))
        $writable = $acl.Access | Where-Object {
            $_.AccessControlType -eq 'Allow' -and
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') -and
            ($_.FileSystemRights -band ([Security.AccessControl.FileSystemRights]'Write, Delete, ChangePermissions, TakeOwnership'))
        }
        $writable | Should -BeNullOrEmpty
    }

    It 'uninstalls the task, twice' {
        if (-not $script:elevated) { Set-ItResult -Skipped -Because 'removing a highest-privilege task requires an elevated session'; return }
        & $script:InstallerPath -Uninstall -TaskName $script:tdTaskName -TaskPath $script:tdTaskPath -InstallRoot $script:tdInstall
        { & $script:InstallerPath -Uninstall -TaskName $script:tdTaskName -TaskPath $script:tdTaskPath -InstallRoot $script:tdInstall } | Should -Not -Throw
        Get-ScheduledTask -TaskName $script:tdTaskName -TaskPath $script:tdTaskPath -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:tdInstall | Should -BeFalse
    }
}

Describe 'Invoke-BucketUpdateAfterWindowsUpdate.ps1 as the task runs it' -Tag 'Heavy' {
    It 'reads the real event log and skips when nothing was installed since the last run' {
        # A marker in the future guarantees "no events since", so the real
        # pwsh -File invocation exercises module import, the real Get-WinEvent
        # query, logging and the exit code -- without running an update.
        $script:tdLog = Join-Path $TestDrive 'heavy-runner'
        New-Item -ItemType Directory -Path $script:tdLog -Force | Out-Null
        Set-BucketUpdateLastRun -Path (Join-Path $script:tdLog 'last-run.txt') -At (Get-Date).AddDays(1)
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoProfile -NonInteractive -File $script:RunnerPath -LogRoot $script:tdLog *> $null
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:tdLog 'UpdateBucketOnWindowsUpdate.log') -Raw) | Should -Match 'skipp'
    }
}
