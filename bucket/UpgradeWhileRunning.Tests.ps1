#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Upgrading a program while it runs (#547).

.DESCRIPTION
    Windows refuses to overwrite or delete an executable a running process has
    loaded, so `winget upgrade` of a portable package (claude.exe, copilot.exe)
    failed while any copy ran -- and winget's cleanup of that failed upgrade also
    removed the command alias. Windows does allow the loaded file to be RENAMED,
    so the module renames in-use executables aside before the engine runs.

    The "running program" here is a real one: a copy of ping.exe started from a
    test folder, which Windows locks exactly as it locks claude.exe (rename
    allowed, delete refused until it exits).
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    $script:running = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

    # Copy ping.exe into $Path and run it, so $Path is a loaded executable image.
    function Start-RunningCopy([string]$Path) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\ping.exe') -Destination $Path
        $p = Start-Process -FilePath $Path -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
        $script:running.Add($p)
        Start-Sleep -Milliseconds 300
        $p
    }

    function Stop-RunningCopy([System.Diagnostics.Process]$Process) {
        if ($Process -and -not $Process.HasExited) { $Process.Kill(); $Process.WaitForExit(5000) | Out-Null }
    }

    function Get-SetAside([string]$Directory) {
        @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Where-Object Name -match '\.(superseded|obsolete)-\d+(-\d+)?$')
    }

    function Stop-AllRunningCopies {
        foreach ($p in $script:running) { Stop-RunningCopy $p }
        $script:running.Clear()
    }

    $script:module = Get-Module MarkMichaelis.ScoopBucket
}


Describe 'Setting in-use files aside (#547)' -Tag 'Light', 'Module' {

    AfterEach { Stop-AllRunningCopies }

    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:exe = Join-Path $script:dir 'tool.exe'
    }

    It 'renames an executable a running process holds, and the process keeps running' {
        $p = Start-RunningCopy $script:exe

        $moved = @(& $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir)

        $moved.Count | Should -Be 1
        $moved[0].Original | Should -Be $script:exe
        $script:exe | Should -Not -Exist
        $moved[0].Renamed | Should -Exist
        $p.HasExited | Should -BeFalse
    }

    It 'leaves files that nothing holds exactly where they are' {
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        Set-Content -LiteralPath $script:exe -Value 'not running'

        $moved = @(& $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir)

        $moved.Count | Should -Be 0
        Get-Content -LiteralPath $script:exe | Should -Be 'not running'
    }

    It 'deletes the set-aside copy once a replacement exists and nothing runs it' {
        $p = Start-RunningCopy $script:exe
        $moved = @(& $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir)
        Set-Content -LiteralPath $script:exe -Value 'new version'
        Stop-RunningCopy $p

        $settled = & $script:module { param($m) Complete-InUseFileAside -Moved $m } $moved

        $settled.Kept | Should -Be 0
        Get-SetAside $script:dir | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:exe | Should -Be 'new version'
    }

    It 'keeps the set-aside copy while it still runs, and the next run deletes it after it exits' {
        $p = Start-RunningCopy $script:exe
        $moved = @(& $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir)
        Set-Content -LiteralPath $script:exe -Value 'new version'

        $settled = & $script:module { param($m) Complete-InUseFileAside -Moved $m } $moved
        $settled.Kept | Should -Be 1
        (Get-SetAside $script:dir).Count | Should -Be 1

        Stop-RunningCopy $p
        $null = & $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir

        Get-SetAside $script:dir | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:exe | Should -Be 'new version'
    }

    It 'puts the original back when no replacement was written' {
        $p = Start-RunningCopy $script:exe
        $hash = (Get-FileHash -LiteralPath $script:exe).Hash
        $moved = @(& $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir)

        $settled = & $script:module { param($m) Complete-InUseFileAside -Moved $m } $moved

        $settled.Restored | Should -Be 1
        (Get-FileHash -LiteralPath $script:exe).Hash | Should -Be $hash
        Get-SetAside $script:dir | Should -BeNullOrEmpty
        $p.HasExited | Should -BeFalse
    }

    It 'restores a set-aside file left behind with no replacement (an interrupted run)' {
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        Set-Content -LiteralPath "$($script:exe).superseded-20260101000000000" -Value 'original'

        $null = & $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir

        Get-Content -LiteralPath $script:exe | Should -Be 'original'
        Get-SetAside $script:dir | Should -BeNullOrEmpty
    }

    It 'leaves a set-aside file alone while the run that set it aside is still in progress' {
        # Another Update-Package run (e.g. a scheduled one) is mid-upgrade: its
        # original is missing on purpose. Restoring it would undo that run's work.
        $owner = Start-RunningCopy (Join-Path $TestDrive "owner-$([guid]::NewGuid().ToString('N')).exe")
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        $stamp = (Get-Date).AddSeconds(1).ToString('yyyyMMddHHmmssfff')
        $left = "$($script:exe).superseded-$stamp-$($owner.Id)"
        Set-Content -LiteralPath $left -Value 'original'

        $null = & $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir

        $script:exe | Should -Not -Exist
        $left | Should -Exist
    }

    It 'restores a set-aside file whose recorded owner id now belongs to a newer, unrelated process' {
        # The owning run crashed and Windows reused its process id.
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        $reused = Start-RunningCopy (Join-Path $TestDrive "reused-$([guid]::NewGuid().ToString('N')).exe")
        Set-Content -LiteralPath "$($script:exe).superseded-20260101000000000-$($reused.Id)" -Value 'original'

        $null = & $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir

        Get-Content -LiteralPath $script:exe | Should -Be 'original'
    }

    It 'treats an owner whose start time it may not read (an elevated run) as still in progress' {
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        $left = "$($script:exe).superseded-20260101000000000-4242"
        Set-Content -LiteralPath $left -Value 'original'
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Process {
            $p = [pscustomobject]@{ Id = 4242 }
            $p | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw [System.UnauthorizedAccessException]::new('Access is denied.') }
            $p
        } -ParameterFilter { $Id -eq 4242 }

        $null = & $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir

        $script:exe | Should -Not -Exist
        $left | Should -Exist
    }

    It 'never puts back a file that an upgrade no longer ships, and deletes it once nothing runs it' {
        # e.g. Grok Build names its exe after its version: a successful upgrade
        # writes grok-<new>.exe and no longer has grok-<old>.exe.
        $p = Start-RunningCopy $script:exe
        $moved = @(& $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir)
        Set-Content -LiteralPath (Join-Path $script:dir 'tool-2.0.exe') -Value 'new version'

        $null = & $script:module { param($m) Complete-InUseFileAside -Moved $m -Upgraded } $moved
        $script:exe | Should -Not -Exist
        $p.HasExited | Should -BeFalse

        Stop-RunningCopy $p
        $null = & $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir

        $script:exe | Should -Not -Exist
        Get-SetAside $script:dir | Should -BeNullOrEmpty
    }

    It 'ignores files that only look like set-aside copies' {
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        $lookalike = Join-Path $script:dir 'notes.txt.superseded-20260101000000000'
        Set-Content -LiteralPath $lookalike -Value 'vendor file'

        $null = & $script:module { param($d) Move-InUseFileAside -Directory $d } $script:dir

        $lookalike | Should -Exist
        Join-Path $script:dir 'notes.txt' | Should -Not -Exist
    }

    It 'handles folders whose names contain wildcard characters' {
        $dir = Join-Path $TestDrive "pkg[1]-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $exe = Join-Path $dir 'tool.exe'
        Set-Content -LiteralPath $exe -Value 'v1'
        # A handle that allows rename but not write stands in for a loaded image.
        $hold = [System.IO.File]::Open($exe, 'Open', 'Read', [System.IO.FileShare]'Read, Delete')
        try {
            $moved = @(& $script:module { param($d) Move-InUseFileAside -Directory $d } $dir)
            $moved.Count | Should -Be 1
            [System.IO.File]::Exists($exe) | Should -BeFalse
            [System.IO.File]::Exists($moved[0].Renamed) | Should -BeTrue
        } finally { $hold.Dispose() }
    }

    It 'says which file it could not check when it is not allowed to open it' {
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        Set-Content -LiteralPath $script:exe -Value 'v1'
        (Get-Item -LiteralPath $script:exe).Attributes = 'ReadOnly'
        try {
            $verbose = & $script:module { param($p) Test-FileInUse -Path $p -Verbose 4>&1 } $script:exe |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
            ($verbose | ForEach-Object Message) -join "`n" | Should -Match ([regex]::Escape($script:exe))
        } finally { (Get-Item -LiteralPath $script:exe).Attributes = 'Normal' }
    }
}

Describe 'Update-WingetPackage upgrades a portable package while it runs (#547)' -Tag 'Light', 'Module' {

    AfterEach { Stop-AllRunningCopies }

    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:exe = Join-Path $script:dir 'tool.exe'
        $script:originalPresentAtUpgrade = $null
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-WingetPortableDirectory { $script:dir }
        $script:engine = & $script:module { Get-Command Update-WingetPackage }
        $script:pkg = [Package]@{ Name = 'Tool'; Installer = 'winget'; Id = 'Vendor.Tool' }
    }

    It 'frees the locked executable before winget runs, and reports that running copies keep the old version' {
        $p = Start-RunningCopy $script:exe
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
            $script:originalPresentAtUpgrade = Test-Path -LiteralPath $script:exe
            Set-Content -LiteralPath $script:exe -Value 'new version'
            $global:LASTEXITCODE = 0
        }

        $r = & $script:engine -Package $script:pkg -TimeoutMinutes 0

        $script:originalPresentAtUpgrade | Should -BeFalse -Because 'winget can only write the new claude.exe once the running one is out of the way'
        $r.State | Should -Be 'Updated'
        $r.Reason | Should -Match 'running'
        $p.HasExited | Should -BeFalse
        Get-Content -LiteralPath $script:exe | Should -Be 'new version'
    }

    It 'puts the running executable back when winget reports no applicable upgrade' {
        $null = Start-RunningCopy $script:exe
        $hash = (Get-FileHash -LiteralPath $script:exe).Hash
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
            $global:LASTEXITCODE = -1978335212
        }

        $r = & $script:engine -Package $script:pkg -TimeoutMinutes 0

        $r.State | Should -Be 'AlreadyLatest'
        (Get-FileHash -LiteralPath $script:exe).Hash | Should -Be $hash
        Get-SetAside $script:dir | Should -BeNullOrEmpty
    }

    It 'puts the running executable back when the upgrade fails' {
        $null = Start-RunningCopy $script:exe
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
            $global:LASTEXITCODE = 1
        }

        $r = & $script:engine -Package $script:pkg -TimeoutMinutes 0

        $r.State | Should -Be 'Failed'
        $script:exe | Should -Exist
        Get-SetAside $script:dir | Should -BeNullOrEmpty
    }

    It 'does not put back a file the upgraded version no longer ships' {
        $null = Start-RunningCopy $script:exe
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
            Set-Content -LiteralPath (Join-Path $script:dir 'tool-2.0.exe') -Value 'new version'
            $global:LASTEXITCODE = 0
        }

        $r = & $script:engine -Package $script:pkg -TimeoutMinutes 0

        $r.State | Should -Be 'Updated'
        $script:exe | Should -Not -Exist -Because 'the new version replaced tool.exe with tool-2.0.exe'
    }

    It 'puts the running executable back when winget reports success but installed nothing' {
        $null = Start-RunningCopy $script:exe
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            if ($args[0] -eq 'list') { $global:LASTEXITCODE = 0; return 'row' }
            $global:LASTEXITCODE = 0
        }

        $null = & $script:engine -Package $script:pkg -TimeoutMinutes 0

        $script:exe | Should -Exist
        Get-SetAside $script:dir | Should -BeNullOrEmpty
    }
}

Describe 'Update-Package -MachineWide upgrades running portables too (#547)' -Tag 'Light', 'Module' {

    AfterEach { Stop-AllRunningCopies }

    It 'frees the locked executables of packages with an upgrade, and leaves the rest running untouched' {
        $script:upDir   = Join-Path $TestDrive "up-$([guid]::NewGuid().ToString('N'))"
        $script:keepDir = Join-Path $TestDrive "keep-$([guid]::NewGuid().ToString('N'))"
        $script:upExe   = Join-Path $script:upDir 'tool.exe'
        $script:keepExe = Join-Path $script:keepDir 'other.exe'
        $script:seen = $null
        $null = Start-RunningCopy $script:upExe
        $null = Start-RunningCopy $script:keepExe
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex {
            @{ winget = @{
                'vendor.tool' = @{ Installed = '1.0'; Available = '2.0' }
                'other.app'   = @{ Installed = '3.0'; Available = '' }
            } }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-WingetPortableDirectory {
            switch ($Id) { 'vendor.tool' { $script:upDir } 'other.app' { $script:keepDir } }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            $script:seen = @{ Up = (Test-Path -LiteralPath $script:upExe); Keep = (Test-Path -LiteralPath $script:keepExe) }
            Set-Content -LiteralPath $script:upExe -Value 'new version'
            $global:LASTEXITCODE = 0
        }

        $r = & $script:module { Update-AllWingetPackages }

        $script:seen.Up | Should -BeFalse -Because 'the upgradable package''s running exe must be out of winget''s way'
        $script:seen.Keep | Should -BeTrue -Because 'a package with nothing to upgrade is not disturbed'
        $r.State | Should -Be 'Updated'
        Get-Content -LiteralPath $script:upExe | Should -Be 'new version'
        Get-SetAside $script:keepDir | Should -BeNullOrEmpty
    }

    It 'puts back a running executable whose package the sweep did not upgrade (e.g. a pinned package)' {
        # winget list still shows an Available version for a pinned package, but
        # winget upgrade --all skips it and exits 0.
        $script:pinDir = Join-Path $TestDrive "pin-$([guid]::NewGuid().ToString('N'))"
        $script:pinExe = Join-Path $script:pinDir 'pinned.exe'
        $null = Start-RunningCopy $script:pinExe
        $hash = (Get-FileHash -LiteralPath $script:pinExe).Hash
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex {
            @{ winget = @{ 'vendor.pinned' = @{ Installed = '1.0'; Available = '2.0' } } }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-WingetPortableDirectory { $script:pinDir }
        # The skipped program keeps running and writes its own log meanwhile.
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            Set-Content -LiteralPath (Join-Path $script:pinDir 'pinned.log') -Value 'still running'
            $global:LASTEXITCODE = 0
        }

        $null = & $script:module { Update-AllWingetPackages }

        (Get-FileHash -LiteralPath $script:pinExe).Hash | Should -Be $hash
        Get-SetAside $script:pinDir | Should -BeNullOrEmpty
    }
}
Describe 'Update-Package -WhatIf previews an upgrade of a running portable (#547)' -Tag 'Light', 'Module' {

    AfterEach { Stop-AllRunningCopies }

    It 'says the in-use program will be upgraded alongside the running copy' {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Start-RunningCopy (Join-Path $script:dir 'tool.exe')
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-WingetPortableDirectory { $script:dir }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex {
            @{ winget = @{ 'vendor.tool' = @{ Installed = '1.0'; Available = '2.0' } } }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-EngineRootMap { $null }
        $pkg = [Package]@{ Name = 'Tool'; Installer = 'winget'; Id = 'Vendor.Tool' }

        $r = Invoke-PackageUpdate -Packages @($pkg) -Bundle 'Test' -WhatIf

        $r.Status | Should -Be 'Updated'
        $r.Reason | Should -Match 'running'
        Get-SetAside $script:dir | Should -BeNullOrEmpty -Because '-WhatIf must not rename anything'
    }
}

Describe 'AIAgents declares each agent CLI under the engine that installs it (#547, #553)' -Tag 'Light', 'Bundle' -ForEach @(
    @{ Name = 'Claude Code CLI';    Cli = 'claude';  Id = 'Anthropic.ClaudeCode'; Wrapper = 'MarkMichaelis/ClaudeCode' }
    @{ Name = 'GitHub Copilot CLI'; Cli = 'copilot'; Id = 'GitHub.Copilot';       Wrapper = 'MarkMichaelis/GitHubCopilotCli' }
    @{ Name = 'Codex CLI';          Cli = 'codex';   Id = 'OpenAI.Codex';         Wrapper = 'MarkMichaelis/Codex' }
) {

    BeforeAll {
        $script:agent = & $script:module {
            param($bundle, $name) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq $name
        } (Join-Path $PSScriptRoot 'AIAgents.ps1') $Name
        $script:roots = @{
            scoop  = @('C:\ProgramData\scoop', 'C:\Users\u\scoop')
            winget = @('C:\Program Files\WinGet', 'C:\Users\u\AppData\Local\Microsoft\WinGet')
        }
    }

    It '<Name>: Update-Package reaches the winget-installed <Cli> instead of refusing it as a foreign copy' {
        $conflict = & $script:module {
            param($pkg, $roots, $cli)
            Get-PackageEngineConflict -Package $pkg -EngineRoot $roots `
                -CommandResolver { param($c) "C:\Users\u\AppData\Local\Microsoft\WinGet\Links\$c.exe" }
        } $script:agent $script:roots $Cli

        $conflict | Should -BeNullOrEmpty
        $script:agent.Id | Should -Be $Id
    }

    It '<Name>: names the retired scoop wrapper as its predecessor so Uninstall-Package also clears its record' {
        $script:agent.PreviousInstaller | Should -Be 'scoop'
        $script:agent.PreviousId | Should -Be $Wrapper
    }
}
Describe 'AIAgents declares ChatGPT under the Store engine that installs it (#553)' -Tag 'Light', 'Bundle' {
    # The MarkMichaelis/ChatGPT scoop manifest only runs ai/ChatGPT.ps1, which
    # installs the Store app through winget's msstore source. Declared as that
    # wrapper, Update-Package asked scoop, which re-runs it only when this
    # bucket bumps its version, never when OpenAI ships one.

    BeforeAll {
        $harvest = { param($bundle, $name) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq $name }
        $script:agent = & $script:module $harvest (Join-Path $PSScriptRoot 'AIAgents.ps1') 'ChatGPT'
        $script:canonical = & $script:module $harvest (Join-Path $PSScriptRoot 'ai\ChatGPT.ps1') 'ChatGPT'
    }

    It 'asks winget''s msstore source for the same Store product as ai/ChatGPT.ps1' {
        $script:agent.Installer | Should -Be 'winget'
        $script:agent.Source    | Should -Be 'msstore'
        $script:agent.Id        | Should -Be $script:canonical.Id
    }

    It 'declares no predecessor, because ai/ChatGPT.json stays a manifest Install-Package installs' {
        # A PreviousId of MarkMichaelis/ChatGPT would make Install-Package refuse
        # that manifest as the superseded install (#464), unlike Codex.json,
        # which this change retires.
        $script:agent.PreviousInstaller | Should -BeNullOrEmpty
        $script:agent.PreviousId        | Should -BeNullOrEmpty
    }

    It 'counts the current app (Appx OpenAI.Codex) as installed, and ChatGPT Classic alone as not' {
        foreach ($scope in @{}, @{ ModuleName = 'MarkMichaelis.ScoopBucket' }) {
            Mock Get-AppxPackage @scope -ParameterFilter { $Name -eq 'OpenAI.Codex' } { $null }
            Mock Get-AppxPackage @scope -ParameterFilter { $Name -eq 'OpenAI.ChatGPT-Desktop' } {
                [pscustomobject]@{ Name = 'OpenAI.ChatGPT-Desktop' }
            }
        }
        & $script:agent.VerifyScript | Should -BeFalse -Because 'a machine with only ChatGPT Classic has not moved to the current app (#511)'

        foreach ($scope in @{}, @{ ModuleName = 'MarkMichaelis.ScoopBucket' }) {
            Mock Get-AppxPackage @scope -ParameterFilter { $Name -eq 'OpenAI.Codex' } { [pscustomobject]@{ Name = 'OpenAI.Codex' } }
        }
        & $script:agent.VerifyScript | Should -BeTrue
    }
}
