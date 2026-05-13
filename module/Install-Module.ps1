[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

<#
.SYNOPSIS
    Symlink the ScoopBucket module into the current user's PSModulePath so
    `Import-Module ScoopBucket` (and auto-loading of `Install-Package`,
    `Get-Package`, `Invoke-PackageInstall`) works from any PowerShell
    session on this machine.

.DESCRIPTION
    Creates a junction (no admin required for user-scope module paths)
    from $HOME\Documents\PowerShell\Modules\ScoopBucket to this repo's
    module/ScoopBucket folder. Re-running is idempotent; pass -Force to
    replace an existing entry (file, real directory, or stale junction).

.NOTES
    PowerShell auto-imports modules located on $env:PSModulePath the first
    time one of their exported functions is referenced, so once installed
    you can use the helpers without an explicit Import-Module.
#>

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'ScoopBucket'
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Source module folder not found: $source"
}

# Resolve a user-scope module path. $env:PSModulePath splits on ';' on
# Windows; we want one under the user profile (writable without admin).
$userModulePath = $env:PSModulePath -split [System.IO.Path]::PathSeparator |
    Where-Object {
        $_ -and ($_ -like "$HOME\*" -or $_ -like "$env:USERPROFILE\*")
    } |
    Select-Object -First 1

if (-not $userModulePath) {
    $userModulePath = Join-Path $HOME 'Documents\PowerShell\Modules'
}

if (-not (Test-Path -LiteralPath $userModulePath -PathType Container)) {
    Write-Verbose "Creating module path: $userModulePath"
    if ($PSCmdlet.ShouldProcess($userModulePath, 'New-Item -ItemType Directory')) {
        New-Item -ItemType Directory -Force -Path $userModulePath | Out-Null
    }
}

$target = Join-Path $userModulePath 'ScoopBucket'

if (Test-Path -LiteralPath $target) {
    $existing = Get-Item -LiteralPath $target -Force
    $isJunction = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isJunction -and $existing.Target -and ((Resolve-Path -LiteralPath $existing.Target).Path -eq (Resolve-Path -LiteralPath $source).Path)) {
        Write-Host "ScoopBucket module already linked at: $target"
        return
    }
    if (-not $Force) {
        throw "An entry already exists at $target. Re-run with -Force to replace it."
    }
    if ($PSCmdlet.ShouldProcess($target, 'Remove existing entry')) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

if ($PSCmdlet.ShouldProcess("$target -> $source", 'New-Item -ItemType Junction')) {
    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    Write-Host "Linked ScoopBucket module: $target -> $source"
    Write-Host "Test with: Import-Module ScoopBucket -Force; Get-Command -Module ScoopBucket"
}
