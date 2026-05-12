
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

$OSPackages = @{
    'WindowsTerminal'=([PSCustomObject]@{ WingetName='Windows Terminal'; WinGetID='Microsoft.WindowsTerminal';  })
    '7Zip'=([PSCustomObject]@{ WingetName='7-Zip'; WinGetID='7Zip.7Zip';  })
#    'Notepad2-mod'=([PSCustomObject]@{ WingetName='Notepad2-mod'; WinGetID=' Notepad2mod.Notepad2mod';  })
    'Everything'=([PSCustomObject]@{ WingetName='Everything'; WinGetID='voidtools.Everything';  })
    'Everything Cli'=([PSCustomObject]@{ WingetName='Everything Cli'; WinGetID='voidtools.Everything.Cli';  })
    'Google Chrome'=([PSCustomObject]@{ WingetName='Google Chrome'; WinGetID='Google.Chrome';  })
    # Process Explorer / SysInternals Suite: winget repeatedly fails with
    # "Installer hash does not match" because download.sysinternals.com ships
    # rolling updates without bumping the winget manifest hash. Installed via
    # scoop extras/sysinternals below (suite includes procexp).
    'WinDirStat'=([PSCustomObject]@{ WingetName='WinDirStat'; WinGetID='WinDirStat.WinDirStat';  })
    'UniversalSilentSwitchFinder'=([PSCustomObject]@{ WingetName='UniversalSilentSwitchFinder'; WinGetID='WindowsPostInstallWizard.UniversalSilentSwitchFinder';  })
    'bat'=([PSCustomObject]@{ WingetName='bat'; WinGetID='sharkdp.bat';  }) # Supports Git integration which has not knowingly been configured.
    # ripgrep: installed via scoop main below (#73) so we pick up v14+, which
    # is required for `rg --generate complete-powershell` (the native command
    # wired into Register-CliCompletion). The winget BurntSushi.ripgrep.MSVC
    # package historically shipped v13 on CI windows-2025 images, where the
    # --generate flag does not exist.
    'fzf'=([PSCustomObject]@{ WingetName='fzf'; WinGetID='junegunn.fzf';  })# Needs PowerShell install of PSFzf module. See https://github.com/kelleyma49/PSFzf
    # FFmpeg: winget Gyan.FFmpeg has a recurring nested-installer path drift
    # (manifest expects ffmpeg-<ver>-full_build\bin\ffmpeg.exe, zip layout
    # changes per release). Installed via scoop main/ffmpeg below.
    'Google Cloud SDK'=([PSCustomObject]@{ WingetName='Google Cloud SDK'; WinGetID='Google.CloudSDK';  })
}

$OSPackages.VAlues | `
    ForEach-Object {
        Write-Host "Installing $($_.WingetName)..."
        Winget install --id $_.WingetID --scope machine
    }

# Scoop-installed packages (replacements for winget entries that suffer
# upstream hash / nested-installer drift — see #29, #43, #44).
Write-Host 'Installing ffmpeg (scoop main)...'
scoop install ffmpeg
# ripgrep via scoop main rather than winget BurntSushi.ripgrep.MSVC: scoop
# tracks upstream GitHub releases so we land on v14+, which is the minimum
# version that supports `rg --generate complete-powershell` (the native
# completion command wired into Register-CliCompletion below). See #73.
Write-Host 'Installing ripgrep (scoop main)...'
scoop install main/ripgrep
Write-Host 'Installing sysinternals suite (scoop extras)...'
scoop install extras/sysinternals

# extras/sysinternals unpacks the suite (procexp, procmon, psexec, handle, ...)
# but does NOT shim individual tools.  Append the install directory to Machine
# PATH so every tool in the suite is callable from the command line.
# Idempotent: only adds the entry if it isn't already present.
$siDir = $null
try { $siDir = (& scoop prefix sysinternals 2>$null | Select-Object -First 1) } catch { }
if ($siDir -and (Test-Path $siDir)) {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $alreadyPresent = ($machinePath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $siDir.TrimEnd('\') })
    if (-not $alreadyPresent) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$siDir", 'Machine')
        Write-Host "  Added sysinternals dir to Machine PATH: $siDir"
    } else {
        Write-Host "  sysinternals dir already on Machine PATH: $siDir"
    }
} else {
    Write-Warning "  Could not resolve sysinternals install dir via 'scoop prefix sysinternals'"
}


# Tab-completion registration: idempotent best-effort. Skipped (with a
# warning) when the session isn't elevated so a normal scoop reinstall
# still succeeds for users without admin rights.
#
# Per-CLI native registration commands are co-located with this bundle
# (which owns the corresponding install). Adding or removing a CLI here
# requires no edit to Utils.ps1.
#
# gcloud was historically wired here with `gcloud --quiet --help-format=ps1`
# but that subcommand does not exist (ps1 is not a real gcloud help format).
# It now relies on the PSCompletions fallback via Invoke-CliCompletionsSweep
# in bundles that call it. See #73.
try {
    Register-CliCompletion -Cli rg     -NativeCommand { rg --generate complete-powershell 2>$null } -Force -Confirm:$false -ErrorAction Stop | Out-Null
}
catch {
    Write-Warning "Skipping CLI tab-completion registration: $($_.Exception.Message)"
}


