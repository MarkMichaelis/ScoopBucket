
. "$PSScriptRoot\Utils.ps1"


Function Invoke-GitConfigBeyondCompare {
    # Resolve Beyond Compare install directory: prefer Scoop, fall back to Program Files
    $bcDir = $null
    if ($env:SCOOP -and (Test-Path "$env:SCOOP\apps\beyondcompare\current\BComp.exe")) {
        $bcDir = "$env:SCOOP\apps\beyondcompare\current"
    }
    elseif (Test-Path "${env:ProgramFiles}\Beyond Compare 4\BComp.exe") {
        $bcDir = "${env:ProgramFiles}\Beyond Compare 4"
    }

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