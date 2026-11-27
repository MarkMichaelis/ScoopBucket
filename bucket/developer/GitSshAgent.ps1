# ssh-agent (#563, split out of GitConfigure): Windows ships the OpenSSH
# agent service disabled. Set it to start manually, so posh-git's
# Start-SshAgent (and ssh-add) can start it. A service already set to start
# automatically is left alone, and running this again changes nothing.

$service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Warning 'ssh-agent: there is no ssh-agent service; add the OpenSSH Client optional feature (Settings > System > Optional features), then install this again.'
    return
}
if ($service.StartType -eq 'Disabled') {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated) { throw 'ssh-agent: changing a service needs an elevated (Run as administrator) PowerShell; install this again from one.' }
    Set-Service -Name 'ssh-agent' -StartupType Manual -ErrorAction Stop
    Write-Host '  ssh-agent: service set to start manually.'
}
