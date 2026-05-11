
. "$PSScriptRoot\Utils.ps1"


Function Resolve-BeyondCompareDir {
    # Returns the install directory containing BComp.exe for whichever
    # Beyond Compare version is available, or $null when none is found.
    # Probe order, newest first:
    #   1. Scoop apps (beyondcompare5, beyondcompare4, beyondcompare)
    #      against both per-user $env:SCOOP and global $env:SCOOP_GLOBAL.
    #   2. Program Files (and Program Files (x86)) for Beyond Compare
    #      {5,4} — covers manual / non-scoop installs.
    #   3. BComp.exe already on PATH (handles scoop-shimmed shims, etc.).
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
