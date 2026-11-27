# posh-git (#563, split out of GitConfigure): the PowerShell module that puts
# git status in the prompt and completes git commands, loaded from the
# all-users profile with -StartSshAgent (which needs the ssh-agent item).
#
# Install-Module -Force also updates an installed copy. Add-PoshGitToProfile
# skips a profile that already imports posh-git, so running this again adds
# nothing.

Install-Module posh-git -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
Import-Module posh-git -ErrorAction Stop
Add-PoshGitToProfile -AllHosts -AllUsers -StartSshAgent -ErrorAction Stop
