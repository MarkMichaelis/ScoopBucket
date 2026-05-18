$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
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
)

Invoke-PackageInstall -Packages $Packages -Bundle 'MicrosoftOffice365'

# OneDrive tenant-redirection policy. Tied to Office, not a package, so it
# runs after the package pass instead of being modelled as a Package entry.
Function Get-Office365TenantId {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)][string]$TenantName
    )
    Invoke-RestMethod -Uri "https://login.windows.net/$TenantName.onmicrosoft.com/.well-known/openid-configuration" -UseBasicParsing | `
        Select-Object 'token_endpoint' | Where-Object {
            $_ -match 'https://login.windows.net/(?<TenantId>.+)/oauth2/token'
        } | ForEach-Object { [PSCustomObject]$matches } | Select-Object TenantId
}

Function Set-OneDriveConfig {
    if (-not (Test-Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive')) {
        New-Item -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive' | Out-Null
    }
    if (-not (Test-Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir')) {
        New-Item -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' | Out-Null
    }
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' `
        -Name "$(Get-Office365TenantId 'IntelliTectSP')" -Value 'C:\OneDrive\IntelliTect'
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' `
        -Name "$(Get-Office365TenantId 'Michaelises')"  -Value 'C:\OneDrive\Michaelises'

    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' `
        -Name 'GPOSetUpdateRing' -Value 'dword:00000004'
}

try { Set-OneDriveConfig } catch {
    Write-Warning "Set-OneDriveConfig failed: $($_.Exception.Message)"
}
