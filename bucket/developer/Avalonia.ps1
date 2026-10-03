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

# Avalonia Accelerate COMMUNITY EDITION developer tooling -- OPT-IN.
#
# This is deliberately its own bundle rather than an entry in
# DeveloperBasePackages: Avalonia is a niche UI framework, so it must not
# install on every developer machine. Install it on demand with
#   Install-Package -Name Avalonia
# or `scoop install MarkMichaelis/Avalonia`.
#
# WHICH Avalonia? "Community edition" is a real, named product: Avalonia
# Accelerate Community Edition, the free tier of Avalonia's *commercial*
# tooling. The framework itself is MIT and ships only as a NuGet library, so
# there is nothing machine-level to install there. Accelerate Community covers
# four tools -- DevTools, Parcel, the Visual Studio extension and the VS Code
# extension -- and only DevTools is BOTH free at the Community level AND
# installable non-interactively:
#
#   1. AvaloniaUI.DeveloperTools — global dotnet tool providing `avdt`.
#   2. Avalonia.Templates        — free MIT `dotnet new avalonia.*` templates.
#
# Both require the .NET SDK on PATH. Like the Aspire bundle, this one is
# intended to run after DeveloperBasePackages (which installs dotnet), and the
# PostInstallScript below augments the session PATH with a canonical dotnet
# location as a best-effort fallback if the scoop shim isn't picked up yet.
#
# No DependsOn: DependsOn is same-bundle-only (Resolve-PackageOrder throws
# "DependsOn 'x' which is not defined in this bundle"), so a single-package
# bundle cannot declare a dependency on dotnet in DeveloperBasePackages --
# exactly as Aspire.ps1 does it. The SDK prerequisite is still enforced at
# install time: Install-DotnetToolPackage fails the package with
# "dotnet not on PATH. Install the .NET SDK first" when it is missing.
# Declaring 'Visual Studio' would be wrong here for a second reason too --
# Resolve-PackageOrder takes the TRANSITIVE CLOSURE of DependsOn under -Name,
# so it would turn `Install-Package -Name Avalonia` into a multi-GB IDE
# install (see #450).

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Avalonia Developer Tools'
        Installer   = 'dotnetTool'
        Id          = 'AvaloniaUI.DeveloperTools'
        # `dotnet tool install -g` installs into %USERPROFILE%\.dotnet\tools.
        # There is no machine-wide variant, so declare the per-user scope
        # rather than inheriting the 'global' default. Documentation only for
        # this engine: Scope is read by the scoop and winget engines, not by
        # Install-DotnetToolPackage.
        Scope       = 'user'
        CliCommands = @('avdt')
        Completion  = 'auto'
        Notes       = 'Avalonia Accelerate COMMUNITY EDITION tooling, shipped as its own OPT-IN bundle so it does not install on every developer machine. "Community edition of Avalonia" resolves to Avalonia Accelerate Community Edition -- the named free tier of Avalonia''s commercial tooling (the framework itself is MIT and ships only as a NuGet library, so there is nothing machine-level to install). Accelerate Community covers four tools: DevTools, Parcel, the Visual Studio extension and the VS Code extension. Only DevTools is BOTH free at the Community level AND installable non-interactively, so that is what this bundle installs: the AvaloniaUI.DeveloperTools global dotnet tool (verified NuGet publisher AvaloniaUI), exposing `avdt`. Deliberately NOT AvaloniaUI.Parcel -- its NuGet listing states "CLI is not available in free community license", so installing the CLI tool would deliver a binary the community licence does not cover; Community users get Parcel''s GUI only. The Visual Studio and VS Code extensions are Community-tier too but install through the VS Extensions manager and the VS Code marketplace, which no engine in this bucket drives. No winget or scoop package for Avalonia tooling exists (probed 2026-10-02: winget returns only third-party apps BUILT with Avalonia; scoop returns only the unrelated avalonia86 emulator), so dotnetTool is the only viable engine -- same shape as the Aspire bundle. The RID-agnostic id requires a .NET 10+ SDK (which resolves the platform asset automatically); on an 8/9-era SDK the RID-specific AvaloniaUI.DeveloperTools.Windows id is required instead. PostInstallScript additionally installs the free MIT Avalonia.Templates so `dotnet new avalonia.app|avalonia.mvvm|avalonia.xplat` works, mirroring Aspire''s Aspire.ProjectTemplates step. avdt ships no `completions powershell` subcommand and has no PSCompletions entry, so the completer is hand-curated (curated, not native -- #289/#293). It offers exactly `mcp` (start the DevTools MCP server) and `uninstall` -- the only subcommands Avalonia documents -- and deliberately offers NO flags, because avdt is a GUI-first inspector for which upstream publishes no CLI flag reference; guessing --help/--version would put unverified completions in front of the user. See #448.'
        ExpectedCompletions = @{ avdt = @('mcp','uninstall') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName avdt -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'mcp','uninstall'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
        PostInstallScript = {
            # Mirrors Aspire.ps1: the global tool alone does not give you
            # `dotnet new avalonia.*`. Avalonia.Templates is the framework's
            # own MIT-licensed template pack, independent of Accelerate
            # licensing, so it is safe to install for every user.
            if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                $candidates = @(
                    'C:\Program Files\dotnet',
                    (Join-Path $env:USERPROFILE 'scoop\apps\dotnet\current'),
                    (Join-Path $env:ProgramData 'scoop\apps\dotnet\current')
                ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'dotnet.exe')) }
                if ($candidates) { $env:PATH = "$($candidates[0]);$env:PATH" }
            }
            if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                Write-Host 'Installing the Avalonia project templates (Avalonia.Templates)...'
                & dotnet new install Avalonia.Templates 2>&1 | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "dotnet new install Avalonia.Templates exited with $LASTEXITCODE (often benign if already installed)."
                }
            } else {
                Write-Warning 'dotnet not on PATH; skipped Avalonia.Templates. Install it by hand with `dotnet new install Avalonia.Templates` once the .NET SDK is available.'
            }
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'Avalonia'
