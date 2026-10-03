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
        the search. A name carrying a directory component is refused outright:
        `-LiteralPath` stops `Test-Path` from expanding a wildcard but does
        nothing about `..`, so `Join-Path <bucket> '..\Elsewhere.json'` would
        otherwise resolve a manifest OUTSIDE the bucket and the caller would
        report it as "found in the bucket".

    .PARAMETER Name
        Manifest base name, without the `.json` extension. Must be a single
        file name — anything with a directory component yields $null.

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

    # A manifest name is a file name, never a path. Refusing a directory
    # component keeps the search inside the bucket: '..\Elsewhere' or
    # 'C:\somewhere\Else' must not resolve, or a caller would announce a
    # manifest outside the bucket as one it found in the bucket.
    if ($Name -ne [System.IO.Path]::GetFileName($Name)) { return $null }

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
