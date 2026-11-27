# A bundle script that is gone by the time Install-Package dispatches it -- a
# worktree removed while the picker was open -- would otherwise surface as the
# driver's "Cannot bind argument to parameter 'Packages' because it is an
# empty array" (#559). Name the file instead.
function Assert-BundleFileExists {
    param([Parameter(Mandatory)][string]$BundlePath)
    if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
        throw "Bundle file not found: '$BundlePath'. It was removed or moved after the package list was read; run Install-Package again."
    }
}
