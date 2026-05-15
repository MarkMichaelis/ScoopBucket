$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# PSCompletions powers the PSCompletions-backed tab completion fallback
# used by Register-PackageCompletion for CLIs whose `<tool> completion`
# subcommand emits nothing usable in PowerShell (bw, copilot, gcloud — see
# #73). Invoke-PackageInstall lazy-installs the module the first time a
# package with Completion='pscompletions'/'auto' is processed, but exposing
# it as a first-class declarative package means users can:
#   * Tab-complete its name in `Install-Package <Tab>`.
#   * Install it explicitly via `Install-Package PSCompletions` when
#     they don't yet need any of the CLIs that would lazy-pull it.
$Packages = [Package[]]@(
    [Package]@{
        Name                = 'PSCompletions'
        Installer           = 'custom'
        Completion          = 'none'
        Notes               = 'PowerShell module from PSGallery; required for the PSCompletions-backed completion fallback.'
        CustomInstallScript = {
            Install-PSCompletionsModule -Confirm:$false
        }
        VerifyScript        = {
            [bool](Get-Module -ListAvailable -Name PSCompletions)
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'PSCompletions'
