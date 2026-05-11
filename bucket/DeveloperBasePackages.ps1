
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'nodejs' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

#hub - GitHub CLI
# BeyondCompare: winget only ships a user-scope MSIX (`ScooterSoftware.BeyondCompare.4`)
# which fails machine-scope install in CI; the scoop `extras/beyondcompare`
# manifest installs cleanly. Refs #14/#46.
'dotnet', 'VisualStudio2026Enterprise', 'extras/beyondcompare' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install -g $_
}

# BeyondCompare CLI surface fix-up: scoop's `extras/beyondcompare` manifest
# shims `BCompare.exe` (-> bcompare) and `BComp.exe` (-> bcomp).  But `BComp.exe`
# is the *GUI* launcher that returns immediately; for a shell or VCS hook the
# console-waiting `BComp.com` is what you want.  Replace the `bcomp` shim and
# put the install dir on Machine PATH so `bcomp.exe` and `BCompare.exe` remain
# reachable by explicit name.  Idempotent.
$bcDir = $null
try { $bcDir = (& scoop prefix beyondcompare 2>$null | Select-Object -First 1) } catch { }
if ($bcDir -and (Test-Path (Join-Path $bcDir 'BComp.com'))) {
    & scoop shim rm bcomp 2>&1 | Out-Null
    & scoop shim add bcomp (Join-Path $bcDir 'BComp.com') 2>&1 | ForEach-Object { Write-Host "  $_" }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $alreadyPresent = ($machinePath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $bcDir.TrimEnd('\') })
    if (-not $alreadyPresent) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$bcDir", 'Machine')
        Write-Host "  Added BeyondCompare dir to Machine PATH: $bcDir"
    }
}

$WingetPackages = @{
    'VisualStudioCode'=([PSCustomObject]@{ WingetName='Visual Studio Code'; WinGetID='Microsoft.VisualStudioCode'; })
#    'Cursor'=([PSCustomObject]@{ WingetName='Cursor'; WinGetID='Anysphere.Cursor'; })
    'CopilotCLI'=([PSCustomObject]@{ WingetName='Copilot CLI'; WinGetID='GitHub.Copilot'; })
#    'AIShell'=([PSCustomObject]@{ WingetName='AI Shell'; WinGetID='Microsoft.AIShell'; })
    'Python'=([PSCustomObject]@{ WingetName='Python'; WinGetID='Python.Python.3.14'; })
#    'Miniforge3'=([PSCustomObject]@{ WingetName='Miniforge3'; WinGetID='CondaForge.Miniforge3'; })
}

$WingetPackages.Values | `
    ForEach-Object { 
        Write-Host "Installing $($_.WingetName)..."
        winget install --scope machine --id $_.WinGetID
    }

# Aspire requires the .NET SDK (installed above as `dotnet`) and is normally
# paired with Visual Studio (installed above) and/or VS Code. Place this
# install last so the SDK and Visual Studio are present when the Aspire CLI
# registers its global dotnet tool and project templates.
'Aspire' | ForEach-Object {
    Write-Host "Installing $_..."
    Install-BucketApp $_
}




# Tab-completion registration: idempotent best-effort. Skipped (with a
# warning) when the session isn't elevated so a normal scoop reinstall
# still succeeds for users without admin rights.
try {
    Register-AllCliCompletions -Force -Confirm:$false -ErrorAction Stop | Out-Null
}
catch {
    Write-Warning "Skipping CLI tab-completion registration: $($_.Exception.Message)"
}
