function Resolve-BucketManifestPath {
    <#
    .SYNOPSIS
        Internal: locate a bare `<name>.json` scoop manifest anywhere in the
        bucket, including inside a category subfolder.

    .DESCRIPTION
        Install-Package / Uninstall-Package / Update-Package all end their
        name resolution with the same "bare manifest" fallback (dispatch case
        (c)): a name that no declarative `[Package]` and no bundle claims is
        still installable when the bucket ships a `<name>.json` manifest,
        because `scoop install <name>` can run that manifest's
        `installer.script` directly.

        That probe used to be a single `Join-Path <bucket> "<name>.json"`,
        which only ever saw the bucket ROOT. Once the bucket moved to the
        grouped layout (`bucket/os/`, `bucket/client/`, `bucket/developer/`,
        `bucket/ai/`, `bucket/admin/` — see #302/#300), every config-only
        manifest — the ones with no sibling `[Package[]]` declaration, e.g.
        `developer/GitConfigure.json`, `os/EnableRemoteDesktop.json` — became
        unreachable by name, even though `scoop` itself and this module's own
        tab completion (Get-PackageNameSuggestion) both search recursively.
        That mismatch is #452: completion offered a name the cmdlet then
        refused.

        Resolution order is deliberate:
          1. `<bucket>\<name>.json` — the bucket root wins, so an existing
             root-level manifest keeps its exact previous behavior and a
             root/subfolder name collision resolves the same way it always did.
          2. The first recursive match, ordered by full path, so a bucket that
             somehow carries the same manifest name in two subfolders still
             resolves deterministically run to run.

        Matching is on the file's base name (case-insensitively), not via a
        `-Filter` pattern, so a name carrying wildcard characters cannot widen
        the search.

    .PARAMETER Name
        Manifest base name, without the `.json` extension.

    .PARAMETER BucketPath
        The bucket directory to search. A missing or empty path yields $null.

    .OUTPUTS
        The full path of the matching manifest, or $null when none matches.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$BucketPath
    )

    if (-not $Name -or -not $BucketPath) { return $null }
    if (-not (Test-Path -LiteralPath $BucketPath -PathType Container)) { return $null }

    $rootCandidate = Join-Path $BucketPath "$Name.json"
    if (Test-Path -LiteralPath $rootCandidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $rootCandidate).Path
    }

    $match = Get-ChildItem -LiteralPath $BucketPath -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -ieq $Name } |
        Sort-Object -Property FullName |
        Select-Object -First 1

    if ($match) { return $match.FullName }
    return $null
}
