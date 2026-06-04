<#
.SYNOPSIS
    Run Pester tests for the MarkMichaelis Scoop bucket.

.DESCRIPTION
    Wraps Invoke-Pester with sensible defaults for this repository.
    By default runs only Light-tagged tests — i.e., the fast pre-push gate.
    To run heavy / install-touching tests, pass -Tag Heavy,Install or -Tag All.

.PARAMETER Tag
    Pester tag(s) to include. Defaults to 'Light'. Pass 'All' to run every test
    regardless of tag (this is translated to no -Tag filter).

.PARAMETER ExcludeTag
    Pester tag(s) to exclude. Defaults to none.

.PARAMETER Pattern
    Glob pattern (relative to bucket/) for test file names, without the
    .Tests.ps1 suffix. Defaults to '*' (all tests).

.EXAMPLE
    # Fast pre-push run
    .\Invoke-Tests.ps1

.EXAMPLE
    # Full integration run on a real Windows dev machine
    .\Invoke-Tests.ps1 -Tag Heavy,Install

.EXAMPLE
    # Run just the Claude tests
    .\Invoke-Tests.ps1 -Pattern Claude -Tag All
#>
[CmdletBinding()]
param(
    [string[]]$Tag = @('Light'),
    [string[]]$ExcludeTag = @(),
    [string]$Pattern = '*',

    # Emit the discovered test files and return WITHOUT running Pester. Lets
    # the discovery contract be asserted in a fast, side-effect-free test.
    [switch]$ListOnly
)

# Discover recursively so member tests co-located in group subfolders
# (bucket/os, bucket/developer, bucket/admin, ...) rejoin the gate. A
# non-recursive glob silently dropped them after the group reorg (#300).
$matched = @(Get-ChildItem -Path $PSScriptRoot -Filter "$Pattern.Tests.ps1" -File -Recurse -ErrorAction SilentlyContinue)
if (-not $matched) {
    Write-Warning "No test files matched: $Pattern.Tests.ps1 under $PSScriptRoot"
    return
}

if ($ListOnly) {
    return $matched
}

# Ensure Pester v5+ is available. v3 is the Windows in-box version and won't
# understand BeforeAll/AfterAll the way our templates use them.
$pester = Get-Module -ListAvailable -Name Pester |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    Write-Host 'Installing Pester 5+...'
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck -Scope CurrentUser
}
Import-Module Pester -MinimumVersion 5.0.0

Write-Host "Found $($matched.Count) test file(s) matching '$Pattern.Tests.ps1':"
$matched | ForEach-Object { Write-Host "  $($_.Name)" }

$config = New-PesterConfiguration
$config.Run.Path        = $matched.FullName
$config.Output.Verbosity = 'Detailed'
if ($Tag -and ($Tag -notcontains 'All')) {
    $config.Filter.Tag = $Tag
}
if ($ExcludeTag) {
    $config.Filter.ExcludeTag = $ExcludeTag
}

Invoke-Pester -Configuration $config
