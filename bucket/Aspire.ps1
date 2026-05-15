$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Microsoft .NET Aspire delivers two artefacts:
#   1. Aspire.Cli           — global dotnet tool providing the `aspire` command.
#   2. Aspire.ProjectTemplates — `dotnet new aspire-*` templates.
# Both require the .NET SDK to be on PATH. This bundle is intended to run
# after DeveloperBasePackages (which installs dotnet); the PostInstallScript
# below augments the session PATH with a canonical dotnet location as a
# best-effort fallback if the scoop shim isn't picked up yet.

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Aspire CLI'
        Installer   = 'dotnetTool'
        Id          = 'Aspire.Cli'
        CliCommands = @('aspire')
        Notes       = 'Global dotnet tool. Requires dotnet SDK on PATH.'
        PostInstallScript = {
            if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                $candidates = @(
                    'C:\Program Files\dotnet',
                    (Join-Path $env:USERPROFILE 'scoop\apps\dotnet\current'),
                    (Join-Path $env:ProgramData 'scoop\apps\dotnet\current')
                ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'dotnet.exe')) }
                if ($candidates) { $env:PATH = "$($candidates[0]);$env:PATH" }
            }
            if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                Write-Host 'Installing the Aspire project templates (Aspire.ProjectTemplates)...'
                & dotnet new install Aspire.ProjectTemplates 2>&1 | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "dotnet new install Aspire.ProjectTemplates exited with $LASTEXITCODE (often benign if already installed)."
                }
            }
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'Aspire'
