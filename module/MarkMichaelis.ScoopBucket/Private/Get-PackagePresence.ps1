# Is a declared package installed? Asked without installing anything (#454).
#
# This is the one place each engine's "already installed" probe lives. The
# Install-<Engine>Package dispatchers call it before installing, and
# Install-Package -Name '*' calls it to decide whether an optional package
# (Default = $false) is present and should be upgraded, so the two answers can
# never drift apart.

function Get-PackagePresence {
    <#
    .SYNOPSIS
        Probe whether a package is installed, without installing it.

    .OUTPUTS
        Hashtable @{ Present; Reason }. Present is $true, $false, or $null
        when the answer is unknowable: the probe failed, or a custom package
        declares nothing to check. Reason names the evidence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package
    )

    $id = [string]$Package.Id
    $installer = [string]$Package.Installer
    # A CustomInstallScript makes the package custom whatever Installer says,
    # exactly as Invoke-PackageInstall dispatches it: the engine never installs
    # it, so the engine's inventory is not evidence. Its VerifyScript (or its
    # CliCommands) is.
    if ($Package.CustomInstallScript -or $installer -eq 'custom') { $installer = 'custom' }

    try {
        switch ($installer) {
            'winget' {
                # Exact match first, for Store ids (#516).
                $probe = Test-WingetPackageInstalled -Package $Package
                if ($probe.Installed) { return @{ Present = $true; Reason = "$($probe.Command) returned 0." } }
                return @{ Present = $false; Reason = "$($probe.Command) did not find it." }
            }
            'scoop' {
                # Keyed by app name, without the bucket prefix. Stays in-process:
                # `scoop list` is read-only and cannot run a manifest script, so
                # it cannot trigger the #451 session-state teardown.
                $bucket, $appName = $id -split '/', 2
                if (-not $appName) { $appName = $bucket }
                $listOut = & scoop list $appName 2>$null | Out-String
                if ($listOut -match "(?im)^\s*$([regex]::Escape($appName))\s+\S+") {
                    return @{ Present = $true; Reason = "scoop list $appName returned a row." }
                }
                return @{ Present = $false; Reason = "scoop list $appName returned no row." }
            }
            'choco' {
                $listOut = & choco list $id --local-only --no-progress 2>$null
                if ($listOut | Where-Object { $_ -match "^\s*$([regex]::Escape($id))\s" }) {
                    return @{ Present = $true; Reason = "choco list $id returned a row." }
                }
                return @{ Present = $false; Reason = "choco list $id returned no row." }
            }
            'npmGlobal' {
                if (-not (Get-Command npm -ErrorAction SilentlyContinue) -and
                    -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
                    return @{ Present = $false; Reason = 'npm is not on PATH.' }
                }
                # A tree; match the bare package name, ignoring the version.
                $listOut = & npm.cmd list -g --depth=0 2>$null | Out-String
                if ($listOut -match "(?im)^\S+\s+$([regex]::Escape($id))@") {
                    return @{ Present = $true; Reason = "npm list -g already lists $id." }
                }
                return @{ Present = $false; Reason = "npm list -g does not list $id." }
            }
            'dotnetTool' {
                if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                    return @{ Present = $false; Reason = 'dotnet is not on PATH.' }
                }
                $listOut = & dotnet tool list -g 2>$null | Out-String
                if ($listOut -match "(?im)^\s*$([regex]::Escape($id))\s+\S+") {
                    return @{ Present = $true; Reason = "dotnet tool list -g already lists $id." }
                }
                return @{ Present = $false; Reason = "dotnet tool list -g does not list $id." }
            }
            'custom' {
                if ($Package.VerifyScript) {
                    $ok = [bool](& $Package.VerifyScript $Package 2>$null)
                    return @{ Present = $ok; Reason = "VerifyScript returned $ok." }
                }
                $clis = @($Package.CliCommands | Where-Object { $_ })
                if ($clis.Count -gt 0) {
                    $missing = @($clis | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
                    if ($missing.Count -eq 0) { return @{ Present = $true; Reason = "$($clis -join ', ') resolve on PATH." } }
                    return @{ Present = $false; Reason = "$($missing -join ', ') do not resolve on PATH." }
                }
                return @{ Present = $null; Reason = 'A custom package with no VerifyScript or CliCommands; nothing to check.' }
            }
            default {
                return @{ Present = $null; Reason = "No presence probe for installer '$installer'." }
            }
        }
    } catch {
        return @{ Present = $null; Reason = "The $installer presence probe failed: $($_.Exception.Message)" }
    }
}
