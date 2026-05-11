
. "$PSScriptRoot\Utils.ps1"


Function Get-BeyondCompareDirFromRegistry {
    # Return the newest Beyond Compare install directory recorded in the
    # Windows registry, or $null when nothing usable is found.
    #
    # Probes (highest version wins, HKCU preferred over HKLM so a per-user
    # install takes precedence on a multi-user box):
    #   HKCU,HKLM,HKLM\WOW6432Node :
    #     1. SOFTWARE\Scooter Software\Beyond Compare *  -> value ExePath
    #     2. SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\
    #          BeyondCompare*_is1  -> value InstallLocation
    # The trailing digit on subkey names ('Beyond Compare 5', 'BeyondCompare5_is1')
    # is treated as the version; bare 'Beyond Compare' counts as version 0
    # so any numbered variant outranks it.
    [CmdletBinding()]
    param()
    $candidates = New-Object System.Collections.Generic.List[object]
    $roots = @(
        'HKCU:\SOFTWARE\Scooter Software',
        'HKLM:\SOFTWARE\Scooter Software',
        'HKLM:\SOFTWARE\WOW6432Node\Scooter Software'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        try {
            foreach ($sub in Get-ChildItem -Path $root -ErrorAction Stop) {
                if ($sub.PSChildName -notlike 'Beyond Compare*') { continue }
                $exe = $null
                try { $exe = (Get-ItemProperty -Path $sub.PSPath -Name ExePath -ErrorAction Stop).ExePath } catch { }
                if ($exe -and (Test-Path $exe)) {
                    $dir = Split-Path -Parent $exe
                    if (Test-Path (Join-Path $dir 'BComp.exe')) {
                        $ver = 0
                        if ($sub.PSChildName -match '(\d+)\s*$') { $ver = [int]$Matches[1] }
                        $candidates.Add([pscustomobject]@{ Version = $ver; Dir = $dir }) | Out-Null
                    }
                }
            }
        } catch { }
    }
    $uninstallRoots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        try {
            foreach ($sub in Get-ChildItem -Path $root -ErrorAction Stop |
                              Where-Object { $_.PSChildName -like 'BeyondCompare*_is1' }) {
                $loc = $null
                try { $loc = (Get-ItemProperty -Path $sub.PSPath -Name InstallLocation -ErrorAction Stop).InstallLocation } catch { }
                if ($loc) {
                    $dir = $loc.TrimEnd('\','/')
                    if (Test-Path (Join-Path $dir 'BComp.exe')) {
                        $ver = 0
                        if ($sub.PSChildName -match 'BeyondCompare(\d+)_is1') { $ver = [int]$Matches[1] }
                        $candidates.Add([pscustomobject]@{ Version = $ver; Dir = $dir }) | Out-Null
                    }
                }
            }
        } catch { }
    }
    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object -Property Version -Descending | Select-Object -First 1).Dir
}


Function Resolve-BeyondCompareDir {
    # Returns the install directory containing BComp.exe for whichever
    # Beyond Compare version is available, or $null when none is found.
    # Probe order, newest first:
    #   1. Windows registry — Scooter Software product keys and the Inno
    #      uninstall record under HKCU / HKLM / HKLM\WOW6432Node. Catches
    #      both per-user (e.g. %LOCALAPPDATA%\Programs\Beyond Compare N)
    #      and per-machine installs without hardcoding directories.
    #   2. Scoop apps (beyondcompare5, beyondcompare4, beyondcompare)
    #      against per-user $env:SCOOP and global $env:SCOOP_GLOBAL.
    #      Scoop installs don't write to the registry, so this branch is
    #      mandatory.
    #   3. Program Files (and Program Files (x86)) for Beyond Compare
    #      {5,4} — fallback for installers that skipped the registry.
    #   4. BComp.exe already on PATH.
    $fromRegistry = Get-BeyondCompareDirFromRegistry
    if ($fromRegistry) { return $fromRegistry }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($env:SCOOP, $env:SCOOP_GLOBAL, "$env:USERPROFILE\scoop", 'C:\ProgramData\scoop')) {
        if (-not $root) { continue }
        foreach ($app in 'beyondcompare5','beyondcompare4','beyondcompare') {
            $candidates.Add("$root\apps\$app\current") | Out-Null
        }
    }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        foreach ($v in 5,4) { $candidates.Add("$pf\Beyond Compare $v") | Out-Null }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'BComp.exe'))) { return $c }
    }
    $cmd = Get-Command BComp.exe -ErrorAction Ignore
    if ($cmd) { return (Split-Path -Parent $cmd.Source) }
    return $null
}

Function Invoke-GitConfigBeyondCompare {
    $bcDir = Resolve-BeyondCompareDir

    if ($bcDir -and (Get-Command git -ErrorAction Ignore)) {
        git config --global diff.tool bc
        git config --global difftool.bc.path "$bcDir\BComp.exe"
        git config --global difftool.prompt false
        git config --global merge.tool bc
        git config --global mergetool.bc.path "$bcDir\BComp.exe"
        git config --global mergetool.bc.trustexitcode true
        git config --global mergetool.keepBackup false
        git config --global mergetool.prompt false
        git config --global alias.dt "difftool --dir-diff"
        Write-Host "Beyond Compare configured for git diff/merge: $bcDir"
    }
    else {
        Write-Warning "Beyond Compare or git not found. Skipping configuration."
    }
}
Invoke-GitConfigBeyondCompare
