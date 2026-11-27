# WSL Ubuntu (#563): the current Ubuntu LTS under WSL. It replaces the
# WSL-Ubuntu-1804 and WSL-Ubuntu-2004 manifests, which installed retired
# releases through Chocolatey (#564).
#
# --no-launch registers the distro without opening its first-run prompt for
# a Linux user name, which an unattended install could not answer; that
# prompt appears the first time `wsl -d Ubuntu-24.04` runs. A distro already
# registered is left alone, so running this again changes nothing. A machine
# without WSL may need a restart before the distro is usable.

$distro = 'Ubuntu-24.04'
if (-not (Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'WSL Ubuntu: wsl.exe is not available on this version of Windows.'
}
# wsl.exe writes UTF-16; drop the NULs so -match sees plain text.
$installed = ((& wsl.exe --list --quiet 2>$null) | Out-String) -replace "`0", ''
if ($installed -match "(?m)^\s*$([regex]::Escape($distro))\s*$") {
    Write-Host "  WSL Ubuntu: $distro is already installed."
    return
}
& wsl.exe --install --distribution $distro --no-launch
if ($LASTEXITCODE -ne 0) { throw "WSL Ubuntu: wsl --install --distribution $distro failed (exit $LASTEXITCODE)." }
