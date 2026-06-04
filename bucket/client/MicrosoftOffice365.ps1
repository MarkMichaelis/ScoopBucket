$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Microsoft 365 baseline: Office ProPlus + Teams + any Office Web Add-ins.
# Claude for Excel lives here (not AIAgents) because it is delivered through
# Microsoft AppSource as an Excel-only Office Web Add-in: removing Office
# from the box also removes the add-in, so its lifecycle is tied to Office
# rather than to the agent surface.

$Packages = [Package[]]@(
    [Package]@{
        Name      = 'Microsoft 365 Apps for Enterprise'
        Installer = 'choco'
        Id        = 'Office365ProPlus'
        CISkip    = 'Requires GUI session and license activation (choco exit 17004); skipped in CI.'
        Notes     = 'Choco package is the only unattended path; winget Office IDs require an interactive sign-in.'
    }
    [Package]@{
        Name      = 'Microsoft Teams'
        Installer = 'choco'
        Id        = 'Microsoft-Teams'
        DependsOn = @('Microsoft 365 Apps for Enterprise')
    }
    [Package]@{
        # Issue #173. Office16 ships seven user-facing GUI apps under
        # C:\Program Files\Microsoft Office\root\Office16\ but that dir is
        # not on PATH, so `winword`/`excel`/`outlook` are unreachable from
        # a terminal. We create thin .cmd shims in ~\scoop\shims (already
        # on PATH via scoop) for the seven user-facing apps only --
        # the other 39 EXEs under Office16 are internal helpers
        # (excelcnv, lync99, OcPubMgr, SDXHelperBgt, ...) that would just
        # pollute tab completion.
        Name        = 'Microsoft Office CLI shims'
        Installer   = 'custom'
        DependsOn   = @('Microsoft 365 Apps for Enterprise')
        CliCommands = @('winword','excel','outlook','powerpnt','onenote','msaccess','mspub')
        Completion  = 'native'
        UpdateMode  = 'Reinstall'  # Idempotently regenerates the .cmd shims against the current Office16 binaries; VerifyScript gates it.
        Notes       = 'Office GUI apps have no PowerShell completer and no PSCompletions catalog entry. Switches are documented in the Microsoft Office command-line switches reference (support.microsoft.com/en-us/office/command-line-switches-for-microsoft-office-products-079164cd-4ef5-4178-b235-441737deb3a6) and stable across Office versions. Each shim runs the underlying Office16 binary detached so the terminal returns immediately.'
        ExpectedCompletions = @{
            winword  = @('/safe','/q','/n','/x')
            excel    = @('/safe','/automation','/embedded','/x')
            outlook  = @('/safe','/resetnavpane','/cleanreminders','/profiles')
            powerpnt = @('/safe','/q','/n','/x')
            onenote  = @('/safe')
            msaccess = @('/safe','/excl','/ro','/runtime')
            mspub    = @('/safe')
        }
        CustomInstallScript = {
            param($pkg)

            $candidates = @(
                'C:\Program Files\Microsoft Office\root\Office16',
                'C:\Program Files (x86)\Microsoft Office\root\Office16'
            )
            $office16 = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if (-not $office16) {
                throw "Office16 install directory not found. Tried: $($candidates -join ', '). Ensure 'Microsoft 365 Apps for Enterprise' installed first."
            }

            $shimDir = Join-Path $env:USERPROFILE 'scoop\shims'
            if (-not (Test-Path -LiteralPath $shimDir)) {
                throw "Scoop shim directory '$shimDir' not found. Install scoop first (this bucket depends on it)."
            }

            $map = @{
                winword  = 'WINWORD.EXE'
                excel    = 'EXCEL.EXE'
                outlook  = 'OUTLOOK.EXE'
                powerpnt = 'POWERPNT.EXE'
                onenote  = 'ONENOTE.EXE'
                msaccess = 'MSACCESS.EXE'
                mspub    = 'MSPUB.EXE'
            }

            foreach ($entry in $map.GetEnumerator()) {
                $shimName = $entry.Key
                $binary   = Join-Path $office16 $entry.Value
                if (-not (Test-Path -LiteralPath $binary)) {
                    Write-Warning "  Skipping shim '$shimName': underlying binary '$binary' not found (app not installed by this Office edition)."
                    continue
                }
                $shimPath = Join-Path $shimDir "$shimName.cmd"
                # @start "" "<binary>" %* detaches the GUI from the terminal
                # so the shell prompt returns immediately. The empty "" is
                # the window title arg required by cmd's start command when
                # the path itself is quoted.
                $content = "@echo off`r`n" +
                           "@rem ScoopBucket:OfficeShim:$shimName -- managed by MicrosoftOffice365.ps1 (issue #173)`r`n" +
                           "@start `"`" `"$binary`" %*`r`n"
                Set-Content -LiteralPath $shimPath -Value $content -Encoding ASCII -NoNewline
                Write-Host "  Created Office shim: $shimPath -> $binary"
            }
        }
        CustomUninstallScript = {
            param($pkg)
            $shimDir = Join-Path $env:USERPROFILE 'scoop\shims'
            if (-not (Test-Path -LiteralPath $shimDir)) { return }
            foreach ($shimName in @('winword','excel','outlook','powerpnt','onenote','msaccess','mspub')) {
                $shimPath = Join-Path $shimDir "$shimName.cmd"
                if (-not (Test-Path -LiteralPath $shimPath)) { continue }
                # Only remove shims we wrote (verify our sentinel).
                $raw = Get-Content -LiteralPath $shimPath -Raw -ErrorAction SilentlyContinue
                if ($raw -and $raw -match 'ScoopBucket:OfficeShim:') {
                    Remove-Item -LiteralPath $shimPath -Force
                    Write-Host "  Removed Office shim: $shimPath"
                }
            }
        }
        VerifyScript = {
            $shimDir = Join-Path $env:USERPROFILE 'scoop\shims'
            if (-not (Test-Path -LiteralPath $shimDir)) { return $false }
            foreach ($shimName in @('winword','excel','outlook','powerpnt','onenote','msaccess','mspub')) {
                $shimPath = Join-Path $shimDir "$shimName.cmd"
                if (-not (Test-Path -LiteralPath $shimPath)) {
                    # Missing shims are tolerated only when the underlying
                    # Office binary is also absent (e.g. Publisher omitted
                    # by some Office editions). The install script logs a
                    # warning in that case; treat verification as passing
                    # for "expected-missing" apps.
                    continue
                }
                $raw = Get-Content -LiteralPath $shimPath -Raw -ErrorAction SilentlyContinue
                if (-not $raw -or $raw -notmatch 'ScoopBucket:OfficeShim:') { return $false }
            }
            return $true
        }
        NativeCommandScript = {
            param($Cli)

            $switchMap = @{
                winword  = @(
                    '/safe','/q','/a','/n','/w','/x','/r','/m','/l','/pxslt',
                    '/t','/f','/h','/regserver','/unregserver'
                )
                excel    = @(
                    '/safe','/automation','/embedded','/embed','/e','/m','/n','/o',
                    '/p','/r','/t','/x','/regserver','/unregserver'
                )
                outlook  = @(
                    '/safe','/resetnavpane','/cleanreminders','/cleanviews','/cleanrules',
                    '/cleanfreebusy','/cleanprofile','/cleanroamedprefs','/cleanrules',
                    '/cleansniff','/cleansubscriptions','/cleanviews','/profiles',
                    '/profile','/recycle','/select','/checkclient','/finder','/firstrun',
                    '/ical','/sniff','/importprf','/a','/c','/embedding','/promptimportprf',
                    '/altvba','/restore','/resettodobar','/resetfolders','/resetformregions',
                    '/resetfoldernames','/resetsearchcriteria','/resetsharedfolders',
                    '/safe:3'
                )
                powerpnt = @(
                    '/safe','/q','/a','/n','/x','/r','/regserver','/unregserver',
                    '/m','/restore'
                )
                onenote  = @(
                    '/safe','/q','/regserver','/unregserver','/x','/n','/m','/r'
                )
                msaccess = @(
                    '/safe','/excl','/ro','/runtime','/repair','/compact','/convert',
                    '/decrypt','/wrkgrp','/user','/pwd','/profile','/nostartup','/cmd',
                    '/x','/regserver','/unregserver'
                )
                mspub    = @(
                    '/safe','/q','/regserver','/unregserver','/x','/n'
                )
            }

            $switches = $switchMap[$Cli]
            if (-not $switches) { return '' }
            # Emit a Register-ArgumentCompleter block. The outer single-quoted
            # here-string keeps the inner $-vars literal so they're evaluated
            # inside the registered scriptblock at completion time, not now.
            $list = ($switches | ForEach-Object { "'$_'" }) -join ','
@"
Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @($list) |
        Where-Object { `$_ -like "`$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
        }
}
"@
        }
    }
    [Package]@{
        Name        = 'Claude for Excel'
        Installer   = 'custom'
        DependsOn   = @('Microsoft 365 Apps for Enterprise')
        UpdateMode  = 'SelfManaged'  # Hosted Office web add-in (AppSource); Microsoft serves updates server-side -- nothing to drive locally.
        Notes       = 'Office Web Add-in distributed exclusively via Microsoft AppSource (asset id WA200010001). No winget/choco/msstore path exists; install requires a one-time browser click. Detection scans HKCU\Software\Microsoft\Office\16.0\WEF\* for the Anthropic publisher.'
        CustomInstallScript = {
            param($pkg)
            $landing  = 'https://claude.com/claude-for-excel'
            $wefRoot  = 'HKCU:\Software\Microsoft\Office\16.0\WEF'

            function Test-ClaudeExcelInstalled {
                if (-not (Test-Path $wefRoot)) { return $false }
                $needles = @('Claude for Excel','Anthropic')
                $hit = Get-ChildItem -Path $wefRoot -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $key = $_
                        try { $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop } catch { return }
                        foreach ($prop in $props.PSObject.Properties) {
                            if ($prop.Name -like 'PS*') { continue }
                            $val = [string]$prop.Value
                            foreach ($n in $needles) {
                                if ($val -like "*$n*" -or $key.Name -like "*$n*") { return $true }
                            }
                        }
                    } | Where-Object { $_ }
                return [bool]$hit
            }

            if (Test-ClaudeExcelInstalled) {
                Write-Host '  Claude for Excel already registered in the Office WEF registry; skipping.'
                return
            }

            Write-Host '  Opening AppSource landing page; complete the "Get it now" flow in Excel.'
            try { Start-Process $landing | Out-Null } catch {
                Write-Warning "  Could not auto-open the browser: $($_.Exception.Message). Visit $landing manually."
            }

            $deadline = (Get-Date).AddSeconds(300)
            while ((Get-Date) -lt $deadline) {
                if (Test-ClaudeExcelInstalled) {
                    Write-Host '  Claude for Excel detected in the Office WEF registry.'
                    return
                }
                Start-Sleep -Seconds 5
            }
            Write-Warning "  Claude for Excel not detected within 5 minutes. A fresh Excel launch may be required for the registry to update."
        }
        VerifyScript = {
            $wefRoot = 'HKCU:\Software\Microsoft\Office\16.0\WEF'
            if (-not (Test-Path $wefRoot)) { return $false }
            $needles = @('Claude for Excel','Anthropic')
            $hit = Get-ChildItem -Path $wefRoot -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $key = $_
                    try { $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop } catch { return }
                    foreach ($prop in $props.PSObject.Properties) {
                        if ($prop.Name -like 'PS*') { continue }
                        $val = [string]$prop.Value
                        foreach ($n in $needles) {
                            if ($val -like "*$n*" -or $key.Name -like "*$n*") { return $true }
                        }
                    }
                } | Where-Object { $_ }
            return [bool]$hit
        }
    }
    [Package]@{
        # Windows ships OneDrive as a per-user install under
        # %LOCALAPPDATA%\Microsoft\OneDrive. This entry replaces that with
        # the machine-wide install (`OneDriveSetup.exe /allusers /silent`)
        # so every user on the box shares one C:\Program Files\Microsoft
        # OneDrive\OneDrive.exe binary -- mandatory for IT-managed
        # tenant-redirect policy (see Set-OneDriveConfig below) and for
        # the `onedrive` scoop shim to resolve to a stable path.
        #
        # Install nuances:
        # 1. The per-user install (if any) is uninstalled first via
        #    OneDriveSetup.exe /uninstall as a best-effort step.
        # 2. /allusers /silent spawns OneDrive.Sync.Service.exe
        #    /silentConfig as a background child. That child NEVER exits
        #    on its own and pins Start-Process -Wait against the parent
        #    job tree. We use Process.WaitForExit(timeout) on the parent
        #    only, then explicitly Stop-Process the sync service.
        # 3. OneDrive.exe is a GUI app with flat (not subcommand) switch
        #    surface; the shim uses the same `@start "" "<exe>" %*`
        #    detach pattern as the Office shims so the terminal returns
        #    immediately after e.g. `onedrive /addaccount`.
        Name        = 'Microsoft OneDrive (machine-wide)'
        Installer   = 'custom'
        CliCommands = @('onedrive')
        Completion  = 'native'
        UpdateMode  = 'SelfManaged'  # OneDrive auto-updates its own client; the install script only seeds the machine-wide binary.
        Notes       = 'Replaces the Windows-default per-user OneDrive with a machine-wide install via OneDriveSetup.exe /allusers /silent. /allusers requires admin; the per-user uninstall is best-effort. Shim at ~\scoop\shims\onedrive.cmd resolves to C:\Program Files\Microsoft OneDrive\OneDrive.exe. Switches per support.microsoft.com OneDrive command-line reference (flat switches, no subcommands).'
        ExpectedCompletions = @{
            onedrive = @('/addaccount','/background','/reset','/resetauthstate','/shutdown','/signout','/configure_business:')
        }
        CustomInstallScript = {
            param($pkg)

            $machineExe = Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'
            $perUserExe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDriveSetup.exe'
            $sysWow64Exe = Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'
            $system32Exe = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'

            Write-Host '  Stopping any running OneDrive instances...'
            Get-Process OneDrive, OneDriveSetup, 'OneDrive.Sync.Service' -ErrorAction SilentlyContinue |
                ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }

            # Best-effort per-user uninstall. Failures are tolerated --
            # /allusers will install alongside, but co-existence is messy.
            $perUserUninstaller = @($perUserExe, $sysWow64Exe, $system32Exe) |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($perUserUninstaller) {
                Write-Host "  Uninstalling per-user OneDrive via $perUserUninstaller /uninstall ..."
                try {
                    $p = Start-Process -FilePath $perUserUninstaller -ArgumentList '/uninstall' -PassThru -WindowStyle Hidden
                    if (-not $p.WaitForExit(60000)) {
                        Write-Warning "  Per-user OneDrive /uninstall did not exit in 60s; killing."
                        try { $p.Kill() } catch {}
                    }
                } catch {
                    Write-Warning "  Per-user OneDrive uninstall failed: $($_.Exception.Message)"
                }
            } else {
                Write-Host '  No per-user OneDriveSetup.exe found; skipping per-user uninstall.'
            }

            # Download the latest OneDriveSetup.exe.
            $installerPath = Join-Path $env:TEMP 'OneDriveSetup.exe'
            $downloadUrl   = 'https://go.microsoft.com/fwlink/?linkid=844652'
            Write-Host "  Downloading OneDriveSetup.exe from $downloadUrl ..."
            $oldProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
            } finally {
                $ProgressPreference = $oldProgress
            }

            Write-Host '  Installing OneDrive machine-wide (/allusers /silent)...'
            $proc = Start-Process -FilePath $installerPath -ArgumentList '/allusers','/silent' -PassThru
            if (-not $proc.WaitForExit(180000)) {
                Write-Warning '  OneDriveSetup.exe did not exit within 180s; killing.'
                try { $proc.Kill() } catch {}
            }
            if ($proc.HasExited -and $proc.ExitCode -ne 0) {
                Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
                throw "OneDriveSetup.exe exited with code $($proc.ExitCode)"
            }

            # /allusers spawns OneDrive.Sync.Service.exe /silentConfig
            # which runs indefinitely and would block any caller using
            # Start-Process -Wait. The binary install is already complete
            # by the time the parent exits, so stopping the sync service
            # is safe.
            Get-CimInstance Win32_Process -Filter "Name='OneDrive.Sync.Service.exe'" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                        Write-Host "  Stopped post-install OneDrive.Sync.Service.exe (PID $($_.ProcessId))."
                    } catch {}
                }

            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path -LiteralPath $machineExe)) {
                throw "OneDriveSetup.exe completed but expected binary '$machineExe' is missing."
            }
            $ver = (Get-Item -LiteralPath $machineExe).VersionInfo.FileVersion
            Write-Host "  OneDrive installed: $machineExe (v$ver)"

            # Scoop shim so `onedrive` resolves on PATH. Uses the same
            # `@start "" "<exe>" %*` detach pattern as the Office shims so
            # the terminal returns immediately after launching the GUI.
            $shimDir = Join-Path $env:USERPROFILE 'scoop\shims'
            if (-not (Test-Path -LiteralPath $shimDir)) {
                throw "Scoop shim directory '$shimDir' not found. Install scoop first (this bucket depends on it)."
            }
            $shimPath = Join-Path $shimDir 'onedrive.cmd'
            $content  = "@echo off`r`n" +
                        "@rem ScoopBucket:OneDriveShim:onedrive -- managed by MicrosoftOffice365.ps1`r`n" +
                        "@start `"`" `"$machineExe`" %*`r`n"
            Set-Content -LiteralPath $shimPath -Value $content -Encoding ASCII -NoNewline
            Write-Host "  Created OneDrive shim: $shimPath -> $machineExe"
        }
        CustomUninstallScript = {
            param($pkg)

            # Stop OneDrive cleanly then remove the shim and uninstall
            # the machine-wide binary. Restoring the per-user install is
            # left to Windows -- nothing to do here for that.
            Get-Process OneDrive, 'OneDrive.Sync.Service' -ErrorAction SilentlyContinue |
                ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }

            $shimDir  = Join-Path $env:USERPROFILE 'scoop\shims'
            $shimPath = Join-Path $shimDir 'onedrive.cmd'
            if (Test-Path -LiteralPath $shimPath) {
                $raw = Get-Content -LiteralPath $shimPath -Raw -ErrorAction SilentlyContinue
                if ($raw -and $raw -match 'ScoopBucket:OneDriveShim:') {
                    Remove-Item -LiteralPath $shimPath -Force
                    Write-Host "  Removed OneDrive shim: $shimPath"
                }
            }

            $machineSetup = Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDriveSetup.exe'
            if (Test-Path -LiteralPath $machineSetup) {
                Write-Host "  Uninstalling machine-wide OneDrive via $machineSetup /uninstall /allusers ..."
                try {
                    $p = Start-Process -FilePath $machineSetup -ArgumentList '/uninstall','/allusers' -PassThru -WindowStyle Hidden
                    if (-not $p.WaitForExit(120000)) {
                        Write-Warning '  OneDrive /uninstall did not exit in 120s; killing.'
                        try { $p.Kill() } catch {}
                    }
                } catch {
                    Write-Warning "  OneDrive uninstall failed: $($_.Exception.Message)"
                }
            }
        }
        VerifyScript = {
            $machineExe = Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'
            if (-not (Test-Path -LiteralPath $machineExe)) { return $false }
            $shimPath = Join-Path $env:USERPROFILE 'scoop\shims\onedrive.cmd'
            if (-not (Test-Path -LiteralPath $shimPath)) { return $false }
            $raw = Get-Content -LiteralPath $shimPath -Raw -ErrorAction SilentlyContinue
            if (-not $raw -or $raw -notmatch 'ScoopBucket:OneDriveShim:') { return $false }
            return $true
        }
        NativeCommandScript = {
            param($Cli)

            if ($Cli -ne 'onedrive') { return '' }

            # OneDrive.exe accepts flat switches (no subcommand tree).
            # Sources: Microsoft Learn OneDrive admin docs and the
            # OneDrive client itself. Switches are stable across versions.
            $switches = @(
                '/addaccount'
                '/background'
                '/reset'
                '/resetauthstate'
                '/shutdown'
                '/signout'
                '/configure_business:'
            )
            $list = ($switches | ForEach-Object { "'$_'" }) -join ','
@"
Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @($list) |
        Where-Object { `$_ -like "`$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
        }
}
"@
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'MicrosoftOffice365'

# OneDrive tenant-redirection policy and KFM rewriting moved to the
# personal post-install customization bundle
# MarkMichaelisOneDriveConfiguration. That bundle runs AFTER all install
# bundles to reshape state (sync roots, KFM, per-app settings) and is
# the first member of the MarkMichaelis* run-last category.
