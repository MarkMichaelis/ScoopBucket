#requires -Version 7.0
<#
.SYNOPSIS
    Refresh data/PSCompletionsCatalog.json from the upstream
    abgox/PSCompletions completions/ directory.

.DESCRIPTION
    The CompletionContract Light test (Bundles.Tests.ps1) cross-checks
    every Package declared with Completion='pscompletions' against the
    cached list of available PSCompletions catalog entries. Run this
    script whenever the upstream catalog changes (or on a schedule) to
    refresh the snapshot.

.EXAMPLE
    pwsh -File .github/scripts/Update-PSCompletionsCatalog.ps1
#>
[CmdletBinding()]
param(
    [string]$OutPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data\PSCompletionsCatalog.json')
)

$ErrorActionPreference = 'Stop'

$apiUrl = 'https://api.github.com/repos/abgox/PSCompletions/contents/completions'
Write-Host "Fetching $apiUrl ..."
$headers = @{ 'User-Agent' = 'ScoopBucket-Update-PSCompletionsCatalog' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "token $env:GITHUB_TOKEN" }

$entries = Invoke-RestMethod -Uri $apiUrl -Headers $headers
$names = @($entries | Where-Object { $_.type -eq 'dir' } | Select-Object -ExpandProperty name | Sort-Object)

$payload = [ordered]@{
    Source         = $apiUrl
    RefreshScript  = '.github/scripts/Update-PSCompletionsCatalog.ps1'
    Completions    = $names
}

$json = ($payload | ConvertTo-Json -Depth 4)
$outDir = Split-Path -Parent $OutPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Set-Content -Path $OutPath -Value $json -Encoding UTF8
Write-Host "Wrote $($names.Count) entries to $OutPath"
