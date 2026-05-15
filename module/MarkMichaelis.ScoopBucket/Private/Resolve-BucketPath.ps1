function Resolve-BucketPath {
    <#
    .SYNOPSIS
        Internal: locate the repo's bucket/ directory from the loaded
        module — robustly even when the module is loaded through a
        symlink/junction (the common case after Install-Module.ps1).

    .DESCRIPTION
        Resolution order:
          1. Explicit -BucketPath argument.
          2. $env:SCOOPBUCKET_BUCKET_PATH.
          3. Walk up from $PSScriptRoot (the caller's module-internal
             folder, e.g. Private/ or Public/), resolving any
             junction/symlink targets along the way back to the repo
             checkout, then append 'bucket'.

        If none of the candidates yields an existing directory, returns
        $null and lets the caller decide what to do (Get-Package returns
        an empty list; Install-Package can't proceed and the caller
        should set $env:SCOOPBUCKET_BUCKET_PATH).
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string]$BucketPath,
        [Parameter(Mandatory)][string]$CallerScriptRoot
    )

    if ($BucketPath) {
        if (Test-Path $BucketPath -PathType Container) { return (Resolve-Path $BucketPath).Path }
        return $null
    }
    if ($env:SCOOPBUCKET_BUCKET_PATH) {
        if (Test-Path $env:SCOOPBUCKET_BUCKET_PATH -PathType Container) {
            return (Resolve-Path $env:SCOOPBUCKET_BUCKET_PATH).Path
        }
    }

    # Walk: <caller>/Private → <module>/MarkMichaelis.ScoopBucket
    $moduleRoot = Split-Path -Parent $CallerScriptRoot

    # Follow a junction/symlink on the module folder itself so we end
    # up at the real on-disk location (the repo's module/MarkMichaelis.ScoopBucket).
    try {
        $item = Get-Item -LiteralPath $moduleRoot -Force -ErrorAction Stop
        if ($item.Target) {
            $target = $item.Target | Select-Object -First 1
            if ($target -and (Test-Path $target -PathType Container)) {
                $moduleRoot = (Resolve-Path $target).Path
            }
        } else {
            $moduleRoot = (Resolve-Path $moduleRoot).Path
        }
    } catch {
        # Fall through with unresolved path.
    }

    $modulesParent = Split-Path -Parent $moduleRoot           # …/module
    $repoRoot      = Split-Path -Parent $modulesParent        # …
    $candidate     = Join-Path $repoRoot 'bucket'
    if (Test-Path $candidate -PathType Container) { return (Resolve-Path $candidate).Path }

    return $null
}
