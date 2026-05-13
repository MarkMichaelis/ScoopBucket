# Root module for ScoopBucket.
#
# The [Package] class is loaded into the *caller* scope via the manifest's
# ScriptsToProcess entry (see ScoopBucket.psd1) so that bundle scripts can
# write `[Package]@{ ... }` after a plain `Import-Module ScoopBucket`,
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

foreach ($dir in @('Private', 'Public')) {
    $folder = Join-Path $PSScriptRoot $dir
    if (-not (Test-Path $folder)) { continue }
    foreach ($file in Get-ChildItem -Path $folder -Filter '*.ps1' -File) {
        . $file.FullName
    }
}
