#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Data-driven validation of every declarative bundle in bucket/.

.DESCRIPTION
    Replaces the per-bundle hardcoded test files. Get-Package gives us a
    flat view of every [Package] entry across every migrated bundle; the
    cases below assert structural / cross-cutting invariants that apply
    uniformly:

      - every package has a non-empty Name + a known Installer
      - scoop ids use the canonical '<bucket>/<name>' prefix
      - msstore Source is only used with the winget installer
      - DependsOn references resolve to other packages in this bucket
      - Package.Name values are unique across the whole bucket
      - declared CliCommands look like plausible short command names
      - HasNativeCommandScript is set whenever Completion='native'

    Bundle-specific assertions (e.g. "Beyond Compare has a
    PostInstallScript") are NOT re-encoded here; the data model itself
    is the source of truth, so we test the data model rather than
    duplicate the data in the tests.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force } 
    $script:allPkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:byName  = @{}
    foreach ($p in $script:allPkgs) {
        if (-not $script:byName.ContainsKey($p.Name)) {
            $script:byName[$p.Name] = @()
        }
        $script:byName[$p.Name] += $p
    }
}

# DISCOVERY-TIME data collection. The per-package `It -ForEach $script:pkgCases`
# cases below need $script:pkgCases populated at Pester DISCOVERY time, not at
# Run time (BeforeAll runs after discovery). Previously this lived in
# BeforeAll, which silently produced ZERO iterations for every -ForEach test
# — i.e. all per-package validation was inert. This block runs during the
# discovery pass so the cases fan out properly.
$scoopBucketPsd1Discovery = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1Discovery) { Import-Module $scoopBucketPsd1Discovery -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
# Generic-test consumers: one row per package, given to It -ForEach.
# Pester's -ForEach iterates over each hashtable's key/value pairs
# and exposes them as named variables ($Bundle, $Pkg) inside the It.
$script:pkgCases = foreach ($p in @(Get-Package -BucketPath $PSScriptRoot)) {
    @{ Bundle = $p.Bundle; Pkg = $p }
}

Describe 'Declarative bundles (data-driven)' -Tag 'Light','Bundle' {

    It 'discovers at least one migrated bundle' {
        ($script:allPkgs | Select-Object -ExpandProperty Bundle -Unique).Count |
            Should -BeGreaterThan 0
    }

    It 'discovers packages from the five canonical migrated bundles' {
        $bundles = $script:allPkgs | Select-Object -ExpandProperty Bundle -Unique
        foreach ($expected in 'OSBasePackages','DeveloperBasePackages','ClientBasePackages','MicrosoftOffice365','AIAgents') {
            $bundles | Should -Contain $expected
        }
    }

    It 'has unique Name within each bundle (cross-bundle duplicates are allowed by design)' {
        # Cross-bundle duplicate names are legitimate — e.g.
        #   * Visual Studio Code is declared in both OSBasePackages
        #     (baseline editor) and DeveloperBasePackages (developer
        #     surface) so either bundle works standalone.
        #   * Node.js / GitHub Copilot CLI / ChatGPT are declared in
        #     AIAgents (so AIAgents stands on its own) AND in
        #     DeveloperBasePackages / ChatGPT.ps1 (their canonical home).
        # The contract we actually need is that no single bundle's
        # `$Packages` array declares the same Name twice — i.e. the
        # bundle author never lost track of which entries are in their
        # own list.
        $dupWithinBundle = $script:allPkgs |
            Group-Object Bundle, Name |
            Where-Object Count -gt 1
        $dupWithinBundle | Should -BeNullOrEmpty -Because "within-bundle duplicates: $($dupWithinBundle.Name -join ', ')"
    }

    It 'every DependsOn reference resolves to a package in this bucket' {
        $names = [System.Collections.Generic.HashSet[string]]@($script:byName.Keys)
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($p in $script:allPkgs) {
            foreach ($dep in @($p.DependsOn)) {
                if (-not [string]::IsNullOrWhiteSpace($dep) -and -not $names.Contains($dep)) {
                    $missing.Add("$($p.Bundle)/$($p.Name) -> $dep")
                }
            }
        }
        $missing | Should -BeNullOrEmpty -Because "unresolved DependsOn: $($missing -join ', ')"
    }

    It 'every Companions reference resolves to a package in the same bundle' {
        # Companions is same-bundle-only for v1 -- mirrors the DependsOn
        # constraint in Resolve-PackageOrder. A cross-bundle Companions
        # reference is a bug because Resolve-PackageOrder runs per bundle.
        $byBundleName = @{}
        foreach ($p in $script:allPkgs) {
            if (-not $byBundleName.ContainsKey($p.Bundle)) {
                $byBundleName[$p.Bundle] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
            [void]$byBundleName[$p.Bundle].Add($p.Name)
        }
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($p in $script:allPkgs) {
            foreach ($comp in @($p.Companions)) {
                if (-not [string]::IsNullOrWhiteSpace($comp) -and -not $byBundleName[$p.Bundle].Contains($comp)) {
                    $missing.Add("$($p.Bundle)/$($p.Name) -> $comp")
                }
            }
        }
        $missing | Should -BeNullOrEmpty -Because "unresolved Companions (must be same-bundle): $($missing -join ', ')"
    }

    It '<Pkg.Name> (<Bundle>) declares a known Installer' -ForEach $script:pkgCases {
        $Pkg.Installer | Should -BeIn @('winget','scoop','choco','npmGlobal','dotnetTool','custom')
    }

    It '<Pkg.Name> (<Bundle>) has Id when Installer is not custom' -ForEach $script:pkgCases {
        if ($Pkg.Installer -ne 'custom') {
            $Pkg.Id | Should -Not -BeNullOrEmpty
        }
    }

    It '<Pkg.Name> (<Bundle>) uses bucket/name prefix when scoop' -ForEach $script:pkgCases {
        if ($Pkg.Installer -eq 'scoop') {
            $Pkg.Id | Should -Match '^[^/]+/[^/]+$'
        }
    }

    It '<Pkg.Name> (<Bundle>) only uses msstore Source with winget' -ForEach $script:pkgCases {
        if ($Pkg.Source -eq 'msstore') {
            $Pkg.Installer | Should -Be 'winget'
        }
    }

    It '<Pkg.Name> (<Bundle>) has NativeCommandScript when Completion=native or auto' -ForEach $script:pkgCases {
        if ($Pkg.Completion -in @('native','auto')) {
            $Pkg.HasNativeCommandScript | Should -BeTrue
        }
    }

    It '<Pkg.Name> (<Bundle>) has CliCommands when Completion is not none' -ForEach $script:pkgCases {
        if ($Pkg.Completion -in @('native','pscompletions','auto')) {
            @($Pkg.CliCommands).Count | Should -BeGreaterThan 0
        }
    }

    It '<Pkg.Name> (<Bundle>) registers Completion when CliCommands is non-empty' -ForEach $script:pkgCases {
        # Inverse of the assertion above: declaring CliCommands without picking
        # a Completion strategy silently ships a CLI with no Tab-completion.
        # Matches the Package.Validate() guard introduced after the Everything
        # CLI / Node.js / dotnet / etc. gap (25 packages were affected).
        if (@($Pkg.CliCommands).Count -gt 0) {
            $Pkg.Completion | Should -Not -Be 'none' -Because "package declares CliCommands ($(@($Pkg.CliCommands) -join ', ')) but Completion='none' -- pick native|pscompletions|auto and add ExpectedCompletions"
        }
    }

    It '<Pkg.Name> (<Bundle>) declares ExpectedCompletions for every CLI when Completion != none' -ForEach $script:pkgCases {
        if ($Pkg.Completion -in @('native','pscompletions','auto')) {
            $Pkg.ExpectedCompletions | Should -Not -BeNullOrEmpty
            foreach ($cli in @($Pkg.CliCommands)) {
                $Pkg.ExpectedCompletions.ContainsKey($cli) | Should -BeTrue -Because "every CliCommands entry needs an ExpectedCompletions entry so completion can be verified end-to-end"
                @($Pkg.ExpectedCompletions[$cli]).Count | Should -BeGreaterThan 0
            }
        }
    }

    It "<Pkg.Name> (<Bundle>) Completion='pscompletions' CLI is in upstream PSCompletions catalog" -ForEach $script:pkgCases {
        if ($Pkg.Completion -ne 'pscompletions') { return }
        $catalogPath = Join-Path $PSScriptRoot 'PSCompletionsCatalog.json'
        if (-not (Test-Path $catalogPath)) {
            Set-ItResult -Skipped -Because "PSCompletionsCatalog.json snapshot missing; run .github/scripts/Update-PSCompletionsCatalog.ps1"
            return
        }
        $catalog = @((Get-Content -Raw -Path $catalogPath | ConvertFrom-Json).Completions)
        foreach ($cli in @($Pkg.CliCommands)) {
            $catalog | Should -Contain $cli -Because "Completion='pscompletions' requires '$cli' to exist in https://github.com/abgox/PSCompletions/tree/main/completions; otherwise switch to Completion='auto' with a NativeCommandScript"
        }
    }

    It "<Pkg.Name> (<Bundle>) NativeCommandScript emits Register-ArgumentCompleter for every declared CLI" -ForEach $script:pkgCases {
        # Regression guard for the Sysinternals gap: a Package can declare
        # Completion='native'/'auto' with a NativeCommandScript that runs
        # without error but emits nothing for one or more of its CliCommands
        # entries. Resolve-PackageCompletionSource then silently returns
        # Source='Skipped' and the CLI ships with no tab-completion.
        #
        # Get-Package's NativeCommandOutputs is pre-computed by the bundle
        # loader (Get-BundlePackages): it invokes $p.NativeCommandScript
        # against each $cli the same way Resolve-PackageCompletionSource
        # does at install time and captures the resulting text. We assert
        # on that captured text here so the failure mode is caught at PR
        # time without needing the package installed.
        if ($Pkg.Completion -notin @('native','auto')) { return }
        $Pkg.HasNativeCommandScript | Should -BeTrue -Because "Completion='$($Pkg.Completion)' requires a NativeCommandScript"
        foreach ($cli in @($Pkg.CliCommands)) {
            $Pkg.NativeCommandOutputs.ContainsKey($cli) | Should -BeTrue -Because "Get-Package should expose NativeCommandOutputs for every declared CLI"
            $out = [string]$Pkg.NativeCommandOutputs[$cli]
            $trimmed = $out.Trim()
            if (-not $trimmed) {
                # The bundle loader (Get-BundlePackages) invoked the
                # NativeCommandScript but it emitted nothing. Two
                # legitimate reasons:
                #   1. The script delegates to the CLI binary
                #      (e.g. `rg --generate complete-powershell`)
                #      which isn't installed (or is too old) in the
                #      Light/PR runner. Heavy validate-installs reruns
                #      this same probe AFTER install and will catch
                #      genuine breakage there.
                #   2. The script is a static here-string but mis-uses
                #      its $Cli arg so it emits text for one CLI only,
                #      leaving others blank. Sysinternals-class bug.
                # We can't distinguish (1) from (2) statically, so we
                # only flag (2)-style breakage when at least ONE CLI on
                # the same package DID emit. That catches uneven
                # multi-CLI scripts without false-positive'ing on
                # single-CLI binary-delegating scripts.
                $anyEmitted = $false
                foreach ($otherCli in @($Pkg.CliCommands)) {
                    if ($otherCli -eq $cli) { continue }
                    $otherOut = [string]$Pkg.NativeCommandOutputs[$otherCli]
                    if ($otherOut.Trim()) { $anyEmitted = $true; break }
                }
                if ($anyEmitted) {
                    throw "NativeCommandScript emitted output for some CLIs in '$($Pkg.Name)' but NOT for '$cli'. The shared script likely doesn't honor its `$Cli arg for every declared CLI -- Resolve-PackageCompletionSource will silently skip '$cli' at install time."
                }
                Set-ItResult -Skipped -Because "NativeCommandScript for '$cli' produced no output (likely binary-dependent and not on PATH in this runner). Heavy validate-installs covers this end-to-end."
                continue
            }
            $trimmed | Should -Match 'Register-ArgumentCompleter' -Because "NativeCommandScript output for CLI '$cli' must contain a Register-ArgumentCompleter call so the profile block actually wires tab-completion"
        }
    }

    It '<Pkg.Name> (<Bundle>) declares plausible short CLI names' -ForEach $script:pkgCases {
        foreach ($cli in @($Pkg.CliCommands)) {
            $cli | Should -Match '^[A-Za-z0-9._\-]+$' -Because "CliCommands must be bare command names (no paths/quotes)"
            $cli.Length | Should -BeLessThan 40
        }
    }

    It '<Pkg.Name> (<Bundle>) has Scope=global by default unless explicitly user' -ForEach $script:pkgCases {
        # Once the schema default flipped to 'global', the only legitimate
        # non-global value is 'user' for the rare per-user-only package.
        # 'machine' is still accepted as a legacy synonym, but should not
        # appear in newly-migrated bundles.
        $Pkg.Scope | Should -BeIn @('global','user')
    }
}

Describe 'Specific cross-bundle placement contracts' -Tag 'Light','Bundle' {
    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force } 
        $script:byBundle = @{}
        foreach ($p in @(Get-Package -BucketPath $PSScriptRoot)) {
            if (-not $script:byBundle.ContainsKey($p.Bundle)) {
                $script:byBundle[$p.Bundle] = @()
            }
            $script:byBundle[$p.Bundle] += $p
        }
    }

    It 'Claude for Excel is owned by the MicrosoftOffice365 bundle' {
        $script:byBundle.MicrosoftOffice365.Name | Should -Contain 'Claude for Excel'
        $script:byBundle.AIAgents.Name           | Should -Not -Contain 'Claude for Excel'
        $script:byBundle.ClientBasePackages.Name | Should -Not -Contain 'Claude for Excel'
    }

    It 'Microsoft OneDrive (machine-wide) is owned by the MicrosoftOffice365 bundle' {
        # Issue #188: supersedes the shim-only 'OneDrive CLI shim' (issue
        # #183). The new package both installs OneDrive machine-wide via
        # OneDriveSetup.exe /allusers /silent AND manages the onedrive
        # scoop shim. The legacy shim-only package must NOT coexist with
        # this one (they both register CliCommands=@('onedrive') and would
        # collide on the shim file + completion registration).
        $script:byBundle.MicrosoftOffice365.Name | Should -Contain 'Microsoft OneDrive (machine-wide)'
        $script:byBundle.MicrosoftOffice365.Name | Should -Not -Contain 'OneDrive CLI shim'
        $script:byBundle.AIAgents.Name           | Should -Not -Contain 'Microsoft OneDrive (machine-wide)'
        $script:byBundle.OSBasePackages.Name     | Should -Not -Contain 'Microsoft OneDrive (machine-wide)'
    }

    It 'Microsoft OneDrive (machine-wide) advertises the install-time switches the user actually needs post-/allusers' {
        # /addaccount, /signout, /configure_business: are the user-facing
        # entry points after a fresh machine-wide install (linking the
        # first AAD identity, signing out, pointing at a tenant). The
        # legacy shim-only package omitted /addaccount and /signout
        # because it presumed a per-user OneDrive that was already
        # signed in. Asserting these here ensures the new package's
        # completion table reflects the post-install workflow.
        $od = $script:byBundle.MicrosoftOffice365 | Where-Object Name -eq 'Microsoft OneDrive (machine-wide)'
        $od | Should -Not -BeNullOrEmpty
        $od.ExpectedCompletions.ContainsKey('onedrive') | Should -BeTrue
        $od.ExpectedCompletions['onedrive'] | Should -Contain '/addaccount'
        $od.ExpectedCompletions['onedrive'] | Should -Contain '/signout'
        $od.ExpectedCompletions['onedrive'] | Should -Contain '/configure_business:'
    }

    It 'no two packages within a bundle declare the same CliCommands entry' {
        # Regression guard for the issue #188 conflict: the new
        # machine-wide OneDrive package and the legacy 'OneDrive CLI
        # shim' both declared CliCommands=@('onedrive'). Two packages
        # in the same bundle owning the same CLI means the bundle
        # loader writes one shim then immediately overwrites it, and
        # the completion registration runs twice -- a silent ambiguity
        # that no other test caught.
        $collisions = foreach ($bundle in $script:byBundle.Keys) {
            $byCli = @{}
            foreach ($pkg in $script:byBundle[$bundle]) {
                foreach ($cli in @($pkg.CliCommands)) {
                    if (-not $byCli.ContainsKey($cli)) { $byCli[$cli] = @() }
                    $byCli[$cli] += $pkg.Name
                }
            }
            foreach ($cli in $byCli.Keys) {
                if (@($byCli[$cli]).Count -gt 1) {
                    [pscustomobject]@{
                        Bundle   = $bundle
                        Cli      = $cli
                        Packages = $byCli[$cli]
                    }
                }
            }
        }
        $collisions | Should -BeNullOrEmpty -Because "within-bundle CLI duplicates: $(($collisions | ForEach-Object { "$($_.Bundle):$($_.Cli) -> $($_.Packages -join '+')" }) -join '; ')"
    }

    It 'Claude Desktop is owned by the AIAgents bundle' {
        $script:byBundle.AIAgents.Name           | Should -Contain 'Claude Desktop'
        $script:byBundle.ClientBasePackages.Name | Should -Not -Contain 'Claude Desktop'
    }

    It 'Visual Studio Code is declared in both OSBasePackages and DeveloperBasePackages' {
        $script:byBundle.OSBasePackages.Name        | Should -Contain 'Visual Studio Code'
        $script:byBundle.DeveloperBasePackages.Name | Should -Contain 'Visual Studio Code'
    }

    It 'Sysinternals Suite has no PostInstallScript (scoop bin shims handle CLI exposure)' {
        $si = $script:byBundle.OSBasePackages | Where-Object Name -eq 'Sysinternals Suite'
        $si.HasPostInstallScript | Should -BeFalse
    }

    It 'Beyond Compare has a PostInstallScript for the bcomp.com shim' {
        $bc = $script:byBundle.DeveloperBasePackages | Where-Object Name -eq 'Beyond Compare'
        $bc.HasPostInstallScript | Should -BeTrue
    }

    It 'Get-Package surfaces WingetExtraArgs through the child-runspace bundle loader (#161)' {
        # Regression: PR #159 added WingetExtraArgs on the [Package] class
        # and to Test-Installs.ps1's CI wrapper, but the curated hashtable
        # in Get-BundlePackages.ps1's probe (and Get-Package's flattener)
        # omitted the field, so it round-tripped as $null. Result: Handy
        # was installed in CI without --skip-dependencies and failed with
        # APPINSTALLER_CLI_ERROR_INSTALL_MISSING_DEPENDENCY (-1978334972)
        # on KhronosGroup.VulkanRT 1.4.350.0. Lock in the contract.
        $handy = $script:byBundle.ClientBasePackages | Where-Object Name -eq 'Handy'
        $handy                                          | Should -Not -BeNullOrEmpty
        $handy.PSObject.Properties.Name                 | Should -Contain 'WingetExtraArgs'
        @($handy.WingetExtraArgs)                       | Should -Contain '--skip-dependencies'
    }
}
