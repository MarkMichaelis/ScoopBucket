function Save-Artifact {
    <#
    .SYNOPSIS
        Persist a CI/test diagnostic artifact under
        `<Root>\<RepoName>\<Kind>\` with rotation + age pruning.

    .DESCRIPTION
        Serializes `$Data` once to JSON and writes two files in the
        kind directory:

          - `<Kind>-<UTC yyyyMMdd-HHmmss>.json`  (rotating snapshot)
          - `latest.json`                        (stable path; always
                                                 overwritten with the
                                                 most recent payload)

        Then applies a retention policy to the directory:

          1. Delete any timestamped file whose `LastWriteTime` is
             older than 1 day.
          2. Of the remaining timestamped files, keep only the 5
             newest by `LastWriteTime`.
          3. `latest.json` is exempt from both rules.

        Producer scripts call this in place of writing diagnostic
        JSON into the repo root, keeping the working tree clean and
        bounding disk usage on busy dev boxes / runners.

    .PARAMETER Kind
        Logical artifact name (e.g. `cli-availability`,
        `test-results`). Becomes a subdirectory and the timestamped
        filename prefix.

    .PARAMETER Data
        Object to serialize via `ConvertTo-Json -Depth $Depth`. Pass
        a single object (it will be wrapped if it isn't already an
        array). `$null` is permitted and serializes to `null`.

    .PARAMETER Depth
        `ConvertTo-Json -Depth`. Defaults to 5; bump for nested
        payloads (e.g. CLI-availability is 6).

    .PARAMETER Root
        Root directory under which `<RepoName>\<Kind>` lives.
        Defaults to `$env:TEMP`.

    .PARAMETER RepoName
        Override the auto-detected repo name. Defaults to
        `ScoopBucket`; producer scripts always have this constant.

    .OUTPUTS
        [string] The absolute path of the timestamped file.

    .EXAMPLE
        Save-Artifact -Kind 'cli-availability' -Data $results -Depth 6
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Kind,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Data,

        [int] $Depth = 5,

        [string] $Root,

        [string] $RepoName = 'ScoopBucket'
    )

    if (-not $Root) { $Root = $env:TEMP }
    if (-not $Root) {
        throw "Save-Artifact: cannot resolve a writable root (\$env:TEMP is empty). Pass -Root explicitly."
    }

    $kindDir = Join-Path (Join-Path $Root $RepoName) $Kind
    if (-not (Test-Path -LiteralPath $kindDir)) {
        New-Item -ItemType Directory -Path $kindDir -Force | Out-Null
    }

    $stamp     = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $fileName  = "{0}-{1}.json" -f $Kind, $stamp
    $stamped   = Join-Path $kindDir $fileName
    $latest    = Join-Path $kindDir 'latest.json'

    $json = $Data | ConvertTo-Json -Depth $Depth
    if ($null -eq $json) { $json = 'null' }

    # If a same-second invocation already wrote the timestamped file
    # (rapid back-to-back calls in tests / tight loops), disambiguate
    # with a short suffix. Retry until we land on a free path so two
    # calls landing in the same UTC second can't overwrite each other.
    if (Test-Path -LiteralPath $stamped) {
        do {
            $suffix   = '{0}-{1:x4}' -f [DateTime]::UtcNow.ToString('fff'), (Get-Random -Maximum 0x10000)
            $fileName = "{0}-{1}-{2}.json" -f $Kind, $stamp, $suffix
            $stamped  = Join-Path $kindDir $fileName
        } while (Test-Path -LiteralPath $stamped)
    }

    Set-Content -LiteralPath $stamped -Value $json -Encoding UTF8
    Set-Content -LiteralPath $latest  -Value $json -Encoding UTF8

    # Retention: prune by age first, then cap by count. latest.json is
    # always exempt — it's the stable reader contract.
    $cutoff = [DateTime]::UtcNow.AddDays(-1)
    $timestamped = Get-ChildItem -LiteralPath $kindDir -File -Filter "$Kind-*.json" -ErrorAction SilentlyContinue
    foreach ($f in $timestamped) {
        if ($f.LastWriteTimeUtc -lt $cutoff) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $remaining = Get-ChildItem -LiteralPath $kindDir -File -Filter "$Kind-*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if ($remaining.Count -gt 5) {
        foreach ($f in $remaining[5..($remaining.Count - 1)]) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    return $stamped
}
