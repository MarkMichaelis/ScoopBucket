
#region MarkMichaelis.ScoopBucket bundle module import (scoop-portable; see README)
$scoopBucketModule = 'MarkMichaelis.ScoopBucket'
$scoopBucketPsd1 = Join-Path $PSScriptRoot "..\..\module\$scoopBucketModule\$scoopBucketModule.psd1"
if (-not (Test-Path $scoopBucketPsd1)) {
    $scoopBucketRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $PSScriptRoot '..\..\..' }
    $scoopBucketFound = Get-ChildItem -Path (Join-Path $scoopBucketRoot "buckets\*\module\$scoopBucketModule\$scoopBucketModule.psd1") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($scoopBucketFound) { $scoopBucketPsd1 = $scoopBucketFound.FullName }
}
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module $scoopBucketModule -Force }
#endregion MarkMichaelis.ScoopBucket bundle module import


Function Invoke-GitConfigVisualStudio {
    if(-not (test-command vswhere)) {
        choco install vswhere
    }

    $vsInstallPath=vswhere -prerelease -latest -property installationPath
    if(-not ($vsInstallPath) ) {
        Write-Warning 'Visual Studio not installed'
        return
    }

    git config --global mergetool.visual-studio.path "\`"$vsInstallPath\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\vsdiffmerge.exe\`" \`"`$REMOTE\`" \`"`$LOCAL\`" \`"`$BASE\`" \`"`$MERGED\`" //m"
    git config --global mergetool.visual-studio.keepBackup false
    git config --global mergetool.visual-studio.trustExitCode true
    git config --global difftool.visual-studio.cmd "\`"$vsInstallPath\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\vsdiffmerge.exe\`" \`"`$LOCAL\`" \`"`$REMOTE\`" //t"
    git config --global difftool.visual-studio.keepBackup false

}
Invoke-GitConfigVisualStudio