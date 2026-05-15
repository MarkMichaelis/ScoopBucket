function Invoke-BundleScript {
    <#
    .SYNOPSIS
        Internal: launch a declarative bundle .ps1 in a child pwsh and
        invoke its captured `$Packages` collection through the real
        `Invoke-PackageInstall` driver, optionally filtered by -Name.

    .DESCRIPTION
        Extracted from `Install-Package` so the same dispatch machinery
        serves both:
          (a) `Install-Package <PackageName>` — passes a -Name filter
              so DependsOn closure runs but unrelated packages don't.
          (b) `Install-Package <BundleName>`  — omits -Name so the
              entire bundle installs.

        We can't dot-source the bundle in-proc because the bundle's
        first line re-imports the module, which would replace any local
        Invoke-PackageInstall shim we'd tried to inject. Instead we
        strip the bundle's Import-Module preamble and its terminal
        `Invoke-PackageInstall -Packages $Packages -Bundle '...'` call,
        evaluate the remainder so `$Packages` is assigned, and dispatch
        manually with the filter applied.

    .PARAMETER BundlePath
        Absolute path to the bundle's `.ps1` file.

    .PARAMETER Bundle
        Bundle name (used for logging only).

    .PARAMETER Names
        Optional -Name filter. When omitted the whole bundle installs.

    .PARAMETER DryRun, SkipCompletion, ForceCompletion
        Passed through to `Invoke-PackageInstall`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Names,
        [switch]$DryRun,
        [switch]$SkipCompletion,
        [switch]$ForceCompletion
    )

    if ($Names -and $Names.Count -gt 0) {
        Write-Host ""
        Write-Host "Install-Package: dispatching $($Names -join ', ') via $Bundle..."
    }

    $pwsh = (Get-Process -Id $PID).Path
    if (-not $pwsh) { $pwsh = 'pwsh' }
    $modulePsd1 = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'

    $flags = @()
    if ($DryRun)          { $flags += '-DryRun' }
    if ($SkipCompletion)  { $flags += '-SkipCompletion' }
    if ($ForceCompletion) { $flags += '-ForceCompletion' }
    $flagsStr = $flags -join ' '

    $nameFilterLiteral = ''
    if ($Names -and $Names.Count -gt 0) {
        $namesJson = ($Names | ConvertTo-Json -Compress)
        $nameFilterLiteral = "`$names = '$namesJson' | ConvertFrom-Json"
        $nameFilterArg = '-Name @($names)'
    } else {
        $nameFilterArg = ''
    }

    $launch = @"
`$ErrorActionPreference='Continue'
Import-Module '$modulePsd1' -Force
$nameFilterLiteral
`$realDriver = Get-Command Invoke-PackageInstall -Module MarkMichaelis.ScoopBucket

# Strip the bundle's `Import-Module` preamble (already imported above)
# and its terminal `Invoke-PackageInstall ...` line (we dispatch
# ourselves below, with `-Name` filter applied when requested).
`$bundleText = Get-Content -Raw -LiteralPath '$BundlePath'
`$bundleStripped = `$bundleText -replace '(?ms)^\s*\`$scoopBucketPsd1\s*=.*?Import-Module\s+MarkMichaelis\.ScoopBucket\s+-Force\s*\}\s*', ''
`$bundleStripped = `$bundleStripped -replace '(?m)^\s*Invoke-PackageInstall\s+-Packages\s+\`$Packages\s+-Bundle\s+''[^'']+''\s*`$', ''
`$Packages = `$null
. ([scriptblock]::Create(`$bundleStripped))
if (`$null -eq `$Packages) {
    Write-Error "Install-Package: bundle '$Bundle' did not assign `\`$Packages."
    return
}
& `$realDriver -Packages `$Packages -Bundle '$Bundle' $nameFilterArg $flagsStr
"@

    $tmp = Join-Path $env:TEMP "ScoopBucket-install-$Bundle-$PID.ps1"
    try {
        Set-Content -Path $tmp -Value $launch -Encoding UTF8
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp
    } finally {
        Remove-Item -Path $tmp -ErrorAction Ignore
    }
}
