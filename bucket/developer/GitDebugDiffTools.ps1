# Debug diff tools (#563, split out of GitConfigure): two difftools that only
# print the paths git hands a diff tool -- `git difftool -t debug-powershell`
# and `-t debug-cmd.exe`. Plain `git config --global` writes, so running it
# again changes nothing.

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Debug diff tools: git is not on PATH. Install Git first (Install-Package -Name Git).'
}

git config --global difftool.debug-powershell.cmd 'powershell -noprofile -command { Write-Output \"REMOTE=''$REMOTE'' LOCAL=''$LOCAL''\"}'
if ($LASTEXITCODE -ne 0) { throw "Debug diff tools: git config failed (exit $LASTEXITCODE)." }
git config --global difftool.debug-cmd.exe.cmd 'cmd.exe /C \"ECHO REMOTE=''$REMOTE'' LOCAL=''$LOCAL''\"}'
if ($LASTEXITCODE -ne 0) { throw "Debug diff tools: git config failed (exit $LASTEXITCODE)." }
