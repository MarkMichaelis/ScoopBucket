. "$PSScriptRoot\Utils.ps1"

# Microsoft .NET Aspire is delivered as two artefacts on a developer machine:
#   1. The Aspire CLI - a global dotnet tool packaged as `Aspire.Cli` on
#      NuGet; it provides the `aspire` command for running and templating
#      Aspire app hosts.
#   2. The Aspire project templates (`Aspire.ProjectTemplates` on NuGet) -
#      consumed by Visual Studio's New Project dialog and by `dotnet new
#      aspire-*` from the CLI / VS Code's C# Dev Kit.
# Both require the .NET SDK to be on PATH; this manifest is intended to run
# AFTER Visual Studio (which carries the SDK) and the standalone scoop
# `dotnet` install, so PATH should already include dotnet.

Function Install-Aspire {
    Write-Host "Running $($MyInvocation.MyCommand.Name)..."

    if (-not (Test-Command dotnet)) {
        # The scoop dotnet shim may not be on PATH yet if scoop just installed
        # it - probe the canonical install locations and prepend the first hit.
        $candidates = @(
            'C:\Program Files\dotnet',
            (Join-Path $env:USERPROFILE 'scoop\apps\dotnet\current'),
            (Join-Path $env:ProgramData 'scoop\apps\dotnet\current')
        ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'dotnet.exe')) }
        if ($candidates) {
            $env:PATH = "$($candidates[0]);$env:PATH"
            Write-Host "Added $($candidates[0]) to PATH for this session."
        }
    }

    if (-not (Test-Command dotnet)) {
        Write-Warning 'dotnet was not found on PATH. Install the .NET SDK (e.g. via DeveloperBasePackages) before installing Aspire.'
        return
    }

    Write-Host 'Installing/updating the Aspire CLI (global dotnet tool: Aspire.Cli)...'
    & dotnet tool update --global Aspire.Cli 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        # `tool update` exits non-zero when the tool isn't installed yet - fall
        # back to `tool install` so the script handles both first-run and
        # subsequent (idempotent) invocations.
        & dotnet tool install --global Aspire.Cli 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "dotnet tool install Aspire.Cli failed with exit code $LASTEXITCODE."
        }
    }

    Write-Host 'Installing the Aspire project templates (Aspire.ProjectTemplates)...'
    & dotnet new install Aspire.ProjectTemplates 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        # `dotnet new install` returns non-zero when the templates are already
        # installed at the requested version - downgrade to a warning rather
        # than failing the whole bundle install.
        Write-Warning "dotnet new install Aspire.ProjectTemplates exited with code $LASTEXITCODE (often benign if already installed)."
    }
}

Install-Aspire
