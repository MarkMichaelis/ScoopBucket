function Get-BundlePackages {
    <#
    .SYNOPSIS
        Internal: load every bucket/*.ps1 in a fresh runspace and capture
        the $Packages variable each bundle defines. Returns an array of
        PSCustomObjects with Bundle, BundlePath, and Packages members.
    .DESCRIPTION
        The cross-bundle loader for Install-Package / Get-Package.
        Migrated bundles use a sentinel — `$Packages = [Package[]]@(...)`
        followed by `Invoke-PackageInstall -Packages $Packages -Bundle …`
        — and we capture `$Packages` after the bundle assigns it but
        before `Invoke-PackageInstall` runs.

        To avoid actually executing each bundle's installers when we
        only want to *read* the declarative collection, we patch
        Invoke-PackageInstall in the child runspace to be a no-op
        capture function. Bundles that have not yet been migrated to
        the declarative form (i.e. don't assign a `$Packages` variable)
        contribute nothing — they are silently skipped, not errors.

        The repo's bucket/ directory is auto-detected by walking up from
        the loaded module's location. Override with $env:SCOOPBUCKET_BUCKET_PATH.
    .PARAMETER BucketPath
        Override the auto-detected bucket directory.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [string]$BucketPath
    )

    if (-not $BucketPath) {
        $BucketPath = Resolve-BucketPath -BucketPath $BucketPath -CallerScriptRoot $PSScriptRoot
    }

    if (-not $BucketPath -or -not (Test-Path $BucketPath)) {
        Write-Verbose "Get-BundlePackages: bucket directory not found (looked for $BucketPath). Returning empty."
        return @()
    }

    $bundles = Get-ChildItem -Path $BucketPath -Filter '*.ps1' -File |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
        Where-Object { $_.Name -ne 'Utils.ps1' -and $_.Name -ne 'Invoke-Tests.ps1' }

    $modulePsd1 = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'

    $packageClass = Join-Path (Split-Path -Parent $PSScriptRoot) 'Classes\Package.ps1'

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($bundle in $bundles) {
        $bundleName = [System.IO.Path]::GetFileNameWithoutExtension($bundle.Name)
        $captured = $null

        # Fast pre-filter: only dot-source bundles that look migrated —
        # i.e. their source text mentions `Invoke-PackageInstall`. Running
        # a legacy imperative bundle in a child runspace would trigger
        # real installs (winget/scoop/choco), so skip them outright.
        $bundleText = Get-Content -Raw -LiteralPath $bundle.FullName -ErrorAction SilentlyContinue
        if (-not $bundleText -or $bundleText -notmatch '(?m)^\s*Invoke-PackageInstall\b') {
            $results.Add([pscustomobject]@{
                Bundle     = $bundleName
                BundlePath = $bundle.FullName
                Packages   = @()
            })
            continue
        }

        # Run the bundle in a child pwsh -NoProfile. We deliberately do
        # NOT Import-Module MarkMichaelis.ScoopBucket in the probe because the module's
        # exported `Invoke-PackageInstall` would shadow any local
        # override. Instead we dot-source just the Package class (needed
        # so `[Package]@{...}` parses) and inject our own
        # Invoke-PackageInstall + Get-ScoopBucketModulePath shims.
        $probe = @"
`$ErrorActionPreference='SilentlyContinue'
. '$packageClass'
function Import-Module { param([Parameter(ValueFromRemainingArguments)]`$Args) }   # no-op shim
function Get-ScoopBucketModulePath { return '$packageClass' }

function global:Invoke-PackageInstall {
    param([Parameter(Mandatory)][object[]]`$Packages, [Parameter(Mandatory)][string]`$Bundle, [Parameter(ValueFromRemainingArguments)]`$Remaining)
    # Mark the runspace as a probe so bundle scripts that continue past
    # this shimmed call (e.g. AIAgents.ps1's MCP wiring) can short-circuit
    # before performing real side effects.
    `$global:__SBPKG_IS_PROBE = `$true
    `$exported = foreach (`$p in `$Packages) {
        # Pre-invoke the NativeCommandScript per declared CLI inside this
        # child runspace so the parent process can assert on what the
        # completion machinery would actually emit at install time, without
        # round-tripping scriptblocks through JSON (which would strip them).
        `$nativeOutputs = @{}
        if (`$p.NativeCommandScript) {
            foreach (`$cli in @(`$p.CliCommands)) {
                `$out = ''
                try { `$out = & `$p.NativeCommandScript `$cli 2>`$null | Out-String } catch { `$out = '' }
                `$nativeOutputs[`$cli] = `$out
            }
        }
        @{
            Name        = `$p.Name
            Installer   = `$p.Installer
            Id          = `$p.Id
            Source      = `$p.Source
            Scope       = `$p.Scope
            CliCommands = @(`$p.CliCommands)
            Completion  = `$p.Completion
            ExpectedCompletions = `$p.ExpectedCompletions
            NativeCommandOutputs = `$nativeOutputs
            DependsOn   = @(`$p.DependsOn)
            Companions  = @(`$p.Companions)
            CISkip      = `$p.CISkip
            Notes       = `$p.Notes
            WingetExtraArgs = @(`$p.WingetExtraArgs)
            UpdateTimeoutMinutes = [int]`$p.UpdateTimeoutMinutes
            UpdateMode  = `$p.UpdateMode
            HasPostInstallScript   = [bool]`$p.PostInstallScript
            HasPostUpdateScript    = [bool]`$p.PostUpdateScript
            HasCustomInstallScript = [bool]`$p.CustomInstallScript
            HasVerifyScript        = [bool]`$p.VerifyScript
            HasNativeCommandScript = [bool]`$p.NativeCommandScript
        }
    }
    Write-Output ('__SBPKG__' + (@{ Bundle = `$Bundle; Packages = @(`$exported) } | ConvertTo-Json -Depth 6 -Compress))
    return @()
}

# Stub helpers and engine CLIs some bundles dot-source / invoke so we
# never trigger real installs while just inventorying packages.
function Test-Command { param([string]`$c) `$null -ne (Get-Command `$c -ErrorAction SilentlyContinue) }
function Install-BucketApp { param([Parameter(Mandatory)][string]`$Name) }
function Install-LocalManifest { param() }
function Invoke-CliCompletionsSweep { param() }
function Register-CliCompletion { param() }
function winget { }
function scoop  { }
function choco  { }
function npm    { }
function dotnet { }

try {
    & '$($bundle.FullName)' 2>`$null
} catch {
    Write-Host '__SCOOPBUCKET_BUNDLE_ERROR__'
}
"@

        $tmp = Join-Path $env:TEMP "ScoopBucket-getbundle-$bundleName-$PID.ps1"
        try {
            Set-Content -Path $tmp -Value $probe -Encoding UTF8 -WhatIf:$false
            $pwsh = (Get-Process -Id $PID).Path
            if (-not $pwsh) { $pwsh = 'pwsh' }
            $output = & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>$null
            $jsonLine = $output | Where-Object { $_ -is [string] -and $_.StartsWith('__SBPKG__') } | Select-Object -First 1
            if ($jsonLine) {
                $captured = $jsonLine.Substring('__SBPKG__'.Length) | ConvertFrom-Json -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Verbose "Get-BundlePackages: $bundleName probe threw: $($_.Exception.Message)"
        } finally {
            Remove-Item -Path $tmp -ErrorAction Ignore -WhatIf:$false
        }

        if ($captured -and $captured.Packages) {
            $results.Add([pscustomobject]@{
                Bundle     = $captured.Bundle
                BundlePath = $bundle.FullName
                Packages   = @($captured.Packages)
            })
        } else {
            # Not yet migrated; surface as empty so callers can report
            # incomplete coverage rather than silently dropping the bundle.
            $results.Add([pscustomobject]@{
                Bundle     = $bundleName
                BundlePath = $bundle.FullName
                Packages   = @()
            })
        }
    }

    return ,$results.ToArray()
}
