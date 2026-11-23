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
        @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Where-Object Name -match '\.superseded-\d+$')
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
}

Describe 'Update-Package -MachineWide upgrades running portables too (#547)' -Tag 'Light', 'Module' {

    AfterEach { Stop-AllRunningCopies }

    It 'frees locked portable executables around winget upgrade --all' {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:exe = Join-Path $script:dir 'tool.exe'
        $script:originalPresentAtUpgrade = $null
        $null = Start-RunningCopy $script:exe
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-WingetPortableDirectory { $script:dir }
        Mock -ModuleName MarkMichaelis.ScoopBucket winget {
            $script:originalPresentAtUpgrade = Test-Path -LiteralPath $script:exe
            Set-Content -LiteralPath $script:exe -Value 'new version'
            $global:LASTEXITCODE = 0
        }

        $r = & $script:module { Update-AllWingetPackages }

        $script:originalPresentAtUpgrade | Should -BeFalse
        $r.State | Should -Be 'Updated'
        Get-Content -LiteralPath $script:exe | Should -Be 'new version'
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

Describe 'AIAgents declares Claude Code CLI under the engine that installs it (#547)' -Tag 'Light', 'Bundle' {

    BeforeAll {
        $script:claude = & $script:module {
            param($bundle) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq 'Claude Code CLI'
        } (Join-Path $PSScriptRoot 'AIAgents.ps1')
        $script:roots = @{
            scoop  = @('C:\ProgramData\scoop', 'C:\Users\u\scoop')
            winget = @('C:\Program Files\WinGet', 'C:\Users\u\AppData\Local\Microsoft\WinGet')
        }
    }

    It 'lets Update-Package reach the winget-installed claude instead of refusing it as a foreign copy' {
        $conflict = & $script:module {
            param($pkg, $roots)
            Get-PackageEngineConflict -Package $pkg -EngineRoot $roots `
                -CommandResolver { param($cli) 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links\claude.exe' }
        } $script:claude $script:roots

        $conflict | Should -BeNullOrEmpty
        $script:claude.Id | Should -Be 'Anthropic.ClaudeCode'
    }

    It 'names the old scoop wrapper as its predecessor so Install-Package retires it' {
        $script:claude.PreviousInstaller | Should -Be 'scoop'
        $script:claude.PreviousId | Should -Be 'MarkMichaelis/ClaudeCode'
    }
}
