$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Refs:
#   #14/#46  BeyondCompare: winget MSIX is user-scope only -> scoop extras
#   #73      copilot completion via PSCompletions (no native PS completion command)

$Packages = [Package[]]@(
    [Package]@{ Name = 'Node.js';                       Installer = 'choco';  Id = 'nodejs';                                              CliCommands = @('node','npm') }

    [Package]@{ Name = 'dotnet';                        Installer = 'scoop';  Id = 'main/dotnet';                                          CliCommands = @('dotnet') }
    [Package]@{ Name = 'Visual Studio';                 Installer = 'scoop';  Id = 'MarkMichaelis/VisualStudio2026Enterprise';             CliCommands = @('devenv') }
    [Package]@{
        Name        = 'Beyond Compare'
        Installer   = 'scoop'
        Id          = 'extras/beyondcompare'
        CliCommands = @('bcomp','bcompare')
        Notes       = 'Keep scoop default bcomp shim (BComp.exe, GUI launcher). Add a separate bcomp.com shim for BComp.com (console-waiting variant) so git/scripted callers can request blocking semantics on demand. Refs #14/#46.'
        PostInstallScript = {
            try {
                $dir = (& scoop prefix beyondcompare 2>$null | Select-Object -First 1)
                $bcompCom = if ($dir) { Join-Path $dir 'BComp.com' } else { $null }
                if ($bcompCom -and (Test-Path $bcompCom)) {
                    # Drop any prior bcomp.com shim before re-adding so the
                    # PostInstallScript stays idempotent across re-runs.
                    & scoop shim rm bcomp.com 2>&1 | Out-Null
                    & scoop shim add bcomp.com $bcompCom 2>&1 | ForEach-Object { Write-Host "  $_" }
                }
            } catch {
                Write-Warning "Beyond Compare bcomp.com shim setup failed: $($_.Exception.Message)"
            }
        }
    }

    [Package]@{ Name = 'Visual Studio Code';            Installer = 'winget'; Id = 'Microsoft.VisualStudioCode';                            CliCommands = @('code') }
    [Package]@{
        Name        = 'GitHub Copilot CLI'
        Installer   = 'winget'
        Id          = 'GitHub.Copilot'
        CliCommands = @('copilot')
        Notes       = '`copilot completion` only supports bash/zsh/fish; not in PSCompletions catalog. No PS completion shipped — track upstream (#73).'
    }
    [Package]@{ Name = 'Python';                        Installer = 'winget'; Id = 'Python.Python.3.14';                                    CliCommands = @('python') }

    [Package]@{
        Name        = 'Aspire'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/Aspire'
        CliCommands = @('aspire')
        DependsOn   = @('dotnet','Visual Studio')
        Notes       = 'Bundle manifest invokes `dotnet tool install --global Aspire.Cli` + project templates. DependsOn ensures dotnet+VS are in place first.'
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'DeveloperBasePackages'
