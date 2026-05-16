function Import-PackageCompletion {
    <#
    .SYNOPSIS
        Register tab-completion for one or more CLIs in the current
        PowerShell session, without restarting pwsh.

    .DESCRIPTION
        Register-PackageCompletion persists each CLI's completion as a
        sentinel-delimited block in $PROFILE.AllUsersAllHosts so a new
        pwsh inherits the completers on startup. Import-PackageCompletion
        complements that by activating the completers in the *current*
        runspace, so users don't have to spawn a fresh terminal after
        Install-Package.

        The completion source is recomputed authoritatively from the
        declarative [Package] data (NativeCommandScript, PSCompletions
        catalog) via the same Resolve-PackageCompletionSource helper that
        Register-PackageCompletion uses — no profile file is parsed.
        The resolver returns a string of PowerShell source (whose body is
        typically a `Register-ArgumentCompleter -Native` call); this
        cmdlet compiles that source into a scriptblock and invokes it.
        Because Register-ArgumentCompleter is process-global, the
        registration takes effect in the caller's session.

    .PARAMETER Cli
        One or more bare command names (e.g. 'bw', 'gh'). Each is
        resolved to a [Package] by scanning every bundle's declarative
        $Packages collection for a matching CliCommands entry whose
        owning Package has Completion != 'none'.

    .PARAMETER Package
        Pass [Package] objects directly (avoids the bundle re-scan).
        Install-Package uses this overload because it already has the
        Package instances it just installed.

    .EXAMPLE
        Import-PackageCompletion -Cli bw
        bw <Tab>   # works immediately in the current session
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByCli')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(ParameterSetName = 'ByCli', Position = 0)]
        [string[]]$Cli,

        # `object[]` (not `Package[]`) because Install-Package's post-install
        # path feeds in JSON-deserialized PSCustomObjects from
        # Get-BundlePackages — PowerShell can't coerce PSCustomObject ->
        # Package and parameter binding throws. The end-block only reads
        # property names (Completion, CliCommands, NativeCommandScript,
        # NativeCommandOutputs), which works uniformly on both.
        [Parameter(ParameterSetName = 'ByPackage', ValueFromPipeline)]
        [object[]]$Package
    )

    begin {
        $results = New-Object System.Collections.Generic.List[object]
        $packagesToProcess = New-Object System.Collections.Generic.List[object]
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ByPackage') {
            foreach ($p in @($Package)) {
                if ($p) { [void]$packagesToProcess.Add($p) }
            }
        }
    }

    end {
        if ($PSCmdlet.ParameterSetName -eq 'ByCli') {
            $bundles = @(Get-BundlePackages)
            $allPackages = $bundles | ForEach-Object { $_.Packages }
            $requested = if ($Cli) { @($Cli) } else { @() }
            $matched = New-Object 'System.Collections.Generic.HashSet[string]'

            foreach ($p in $allPackages) {
                if ($p.Completion -eq 'none') { continue }
                if ($p.CliCommands.Count -eq 0) { continue }
                $picked = $false
                if ($requested.Count -eq 0) {
                    $picked = $true
                } else {
                    foreach ($c in $p.CliCommands) {
                        if ($requested -contains $c) { $picked = $true; [void]$matched.Add($c) }
                    }
                }
                if ($picked) { [void]$packagesToProcess.Add($p) }
            }

            foreach ($c in $requested) {
                if (-not $matched.Contains($c)) {
                    $results.Add([pscustomobject]@{
                        Cli = $c; Source = 'Skipped'; Action = 'NotFound'
                        Reason = "No declarative [Package] in any bundle exposes CLI '$c' with Completion != 'none'."
                    })
                }
            }
        }

        # De-duplicate: a single CLI may appear in multiple bundles, but
        # we only want to register it once per call.
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'

        foreach ($p in $packagesToProcess) {
            if ($p.Completion -eq 'none') { continue }
            foreach ($cliName in @($p.CliCommands)) {
                if (-not $seen.Add($cliName)) { continue }

                # Prefer the bundle-loader's pre-captured native output
                # (NativeCommandOutputs[$cliName]) when the package object
                # is a PSCustomObject from Get-BundlePackages — the live
                # NativeCommandScript scriptblock can't round-trip JSON,
                # so it's $null on that path. For real in-memory [Package]
                # callers, the script is intact and Resolve-... invokes
                # it directly.
                $preComputedNative = $null
                if ($p.PSObject.Properties.Name -contains 'NativeCommandOutputs' -and $p.NativeCommandOutputs) {
                    $no = $p.NativeCommandOutputs
                    if ($no -is [hashtable] -and $no.ContainsKey($cliName)) {
                        $preComputedNative = [string]$no[$cliName]
                    } elseif ($no.PSObject -and ($no.PSObject.Properties.Name -contains $cliName)) {
                        $preComputedNative = [string]$no.$cliName
                    }
                }

                $resolved = $null
                if ($preComputedNative -and $preComputedNative.Trim() -and $p.Completion -ne 'pscompletions') {
                    $guarded = "if (Get-Command $cliName -ErrorAction SilentlyContinue) {`r`n$preComputedNative}"
                    $resolved = @{ Source = 'Native'; Code = $guarded; PSCompletionsName = $null }
                } else {
                    $resolveSplat = @{ Cli = $cliName }
                    if ($p.NativeCommandScript -and $p.Completion -ne 'pscompletions') {
                        $resolveSplat['NativeCommand'] = $p.NativeCommandScript
                    }
                    if ($p.Completion -eq 'pscompletions') {
                        $resolveSplat['PreferPSCompletions'] = $true
                    }
                    $resolved = Resolve-PackageCompletionSource @resolveSplat
                }

                if ($p.Completion -eq 'native' -and $resolved.Source -eq 'PSCompletions') {
                    $resolved = @{ Source = 'Skipped'; Code = $null; PSCompletionsName = $null }
                }

                if ($resolved.Source -eq 'Skipped' -or -not $resolved.Code) {
                    $results.Add([pscustomobject]@{
                        Cli = $cliName; Source = 'Skipped'; Action = 'Skipped'
                        Reason = "No completion source available for '$cliName' (no native output, no PSCompletions catalog entry)."
                    })
                    continue
                }

                try {
                    # Register-ArgumentCompleter is process-global, so
                    # executing this scriptblock — even from within the
                    # module's scope — registers the completer in the
                    # caller's runspace.
                    [scriptblock]::Create($resolved.Code).InvokeReturnAsIs() | Out-Null
                    $results.Add([pscustomobject]@{
                        Cli = $cliName; Source = $resolved.Source; Action = 'Registered'
                        Reason = $null
                    })
                } catch {
                    $results.Add([pscustomobject]@{
                        Cli = $cliName; Source = $resolved.Source; Action = 'Failed'
                        Reason = $_.Exception.Message
                    })
                }
            }
        }

        return $results.ToArray()
    }
}
