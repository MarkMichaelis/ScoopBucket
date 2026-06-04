# Root module for ScoopBucket.
#
# The [Package] class is loaded into the *caller* scope via the manifest's
# ScriptsToProcess entry (see MarkMichaelis.ScoopBucket.psd1) so that bundle scripts can
# write `[Package]@{ ... }` after a plain `Import-Module MarkMichaelis.ScoopBucket`,
# without the strict-load semantics of `using module`.
#
# This .psm1 then dot-sources the rest of the module's surface area into
# the module scope: private helpers first (they may be called by public
# functions), then public functions. Only the public functions appear in
# the manifest's FunctionsToExport list.

$ErrorActionPreference = 'Stop'

# Re-dot-source the class inside the module scope so internal functions
# can also reference [Package] (ScriptsToProcess only loads it into the
# caller scope).
. (Join-Path $PSScriptRoot 'Classes\Package.ps1')
. (Join-Path $PSScriptRoot 'Classes\PackageResult.ps1')

foreach ($dir in @('Private', 'Public')) {
    $folder = Join-Path $PSScriptRoot $dir
    if (-not (Test-Path $folder)) { continue }
    foreach ($file in Get-ChildItem -Path $folder -Filter '*.ps1' -File | Where-Object { $_.Name -notmatch '\.Tests\.ps1$' }) {
        . $file.FullName
    }
}

# Resolve $env:SCOOP and dot-source scoop's lightweight internal
# libraries (parse_app / Find-BucketDirectory) into module scope so
# the `scoop` / `Get-LocalBucket` wrappers can call them. The heavy
# scoop-search.ps1 (~1.8s) is intentionally deferred and lazy-loaded
# from inside the `scoop search -PSCustomObject` branch (see
# Initialize-ScoopSearchEnvironment in Private/Legacy.ps1).
#
# IMPORTANT: invoke with the dot-source operator (`.`) so the inner
# `. $p` calls inside Initialize-ScoopEnvironment land in the .psm1
# (module) scope. A plain function call would put them in the
# function's local scope where they evaporate on return, leaving
# parse_app / Find-BucketDirectory undefined for the `scoop` wrapper
# that calls them later.
try { . Initialize-ScoopEnvironment } catch { Write-Verbose "Initialize-ScoopEnvironment: $($_.Exception.Message)" }

# Wire up Tab completion for `Install-Package -Name <tab>` and
# `Get-Package -Name <tab>` so callers don't need to remember exact
# package spellings. The completer is regex-driven and cached, so it's
# safe to register unconditionally at module load.
try { Register-PackageNameCompleter } catch { Write-Verbose "Register-PackageNameCompleter: $($_.Exception.Message)" }
