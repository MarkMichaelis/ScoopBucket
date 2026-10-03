<#
.SYNOPSIS
    Regression guard for #451: scoop's install internals must stay reachable
    for the whole of a scoop install driven through the module.

.DESCRIPTION
    Scoop's `install_app` (lib\install.ps1) runs the manifest's
    `installer.script` via `Invoke-Installer` and then, on the very next
    line, calls `ensure_install_dir_not_in_path` -- a sibling function
    dot-sourced from the same lib file into libexec\scoop-install.ps1's
    script scope.

    Every bundle manifest in this bucket has an `installer.script` that runs
    a `bucket\**\<Bundle>.ps1` whose header does
    `Import-Module MarkMichaelis.ScoopBucket -Force`. `-Force` means
    Remove-Module + Import-Module. If scoop is running *in-process inside
    this module's session state*, removing the module tears that session
    state down while scoop-install.ps1 is still executing inside it: every
    function scoop dot-sourced disappears mid-install and `install_app`
    dies on `ensure_install_dir_not_in_path`.

    The invariant this file pins is therefore NOT a file list -- adding
    'lib\install.ps1' to Initialize-ScoopEnvironment's $required does
    nothing, because scoop-install.ps1 already sources it itself. The
    invariant is that the module must run scoop's entry script in a
    *separate process*, where nothing the module does can unload the
    session state scoop is living in.

    The stub scoop below mirrors the real topology (bin\scoop.ps1 ->
    libexec\scoop-install.ps1 -> lib\install.ps1) so the test fails for the
    behavioural reason -- "The term 'ensure_install_dir_not_in_path' is not
    recognized" -- and not because of anything about the real machine.
#>

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    function script:New-StubScoopRoot {
        <#
        .SYNOPSIS
            Build a throwaway scoop root whose install path mirrors the real
            scoop 0.6.0 shape: an entry script that dispatches to libexec,
            a libexec\scoop-install.ps1 that dot-sources lib\install.ps1,
            and an install_app that runs the manifest installer script and
            then calls a sibling function from that same lib file.
        .OUTPUTS
            Hashtable with Root / MarkerPath.
        #>
        param([Parameter(Mandatory)][string]$ModulePsd1)

        $root    = Join-Path ([IO.Path]::GetTempPath()) "sb451-$([guid]::NewGuid().ToString('N'))"
        $current = Join-Path $root 'apps\scoop\current'
        $lib     = Join-Path $current 'lib'
        $libexec = Join-Path $current 'libexec'
        $bin     = Join-Path $current 'bin'
        $shims   = Join-Path $root 'shims'
        New-Item -ItemType Directory -Force -Path $lib, $libexec, $bin, $shims | Out-Null

        # Lightweight libs Initialize-ScoopEnvironment dot-sources. Present so
        # a re-init against this stub root cannot fail for an unrelated reason.
        foreach ($name in 'core.ps1', 'buckets.ps1', 'manifest.ps1') {
            Set-Content -LiteralPath (Join-Path $lib $name) -Value '# stub' -Encoding utf8
        }

        # The bundle script a real manifest's installer.script runs. Its
        # `-Force` re-import is the whole point of the test.
        $markerPath = Join-Path $root 'bundle-ran.txt'
        $bundlePath = Join-Path $root 'StubBundle.ps1'
        Set-Content -LiteralPath $bundlePath -Encoding utf8 -Value @"
# Mirrors the `#region MarkMichaelis.ScoopBucket bundle module import` header
# every bucket\**\<Bundle>.ps1 carries.
Import-Module '$ModulePsd1' -Force
Set-Content -LiteralPath '$markerPath' -Value 'bundle ran' -Encoding utf8
"@

        # lib\install.ps1 -- install_app runs the installer script (as scoop's
        # Invoke-Installer / Invoke-HookScript do, via a scriptblock in the
        # CURRENT session state) and then calls its sibling.
        Set-Content -LiteralPath (Join-Path $lib 'install.ps1') -Encoding utf8 -Value @"
function install_app(`$app) {
    Invoke-Command ([scriptblock]::Create('& ''$bundlePath'''))
    ensure_install_dir_not_in_path `$app `$false
    Write-Output "'`$app' was installed successfully!"
}

function ensure_install_dir_not_in_path(`$dir, `$global) { }
"@

        # libexec\scoop-install.ps1 -- dot-sources the lib into its own script
        # scope, exactly as scoop 0.6.0 does.
        Set-Content -LiteralPath (Join-Path $libexec 'scoop-install.ps1') -Encoding utf8 -Value @'
. "$PSScriptRoot\..\lib\install.ps1"
$apps = @($args | Where-Object { $_ -notlike '-*' })
foreach ($app in $apps) { install_app $app }
'@

        # libexec\scoop-list.ps1 -- header only by default, so the engine's
        # AlreadyInstalled probe sees no row and proceeds to install. With
        # $env:SB451_STUB_LIST_ROW set it reports a row, which is what the
        # update engine's presence probe needs.
        Set-Content -LiteralPath (Join-Path $libexec 'scoop-list.ps1') -Encoding utf8 -Value @'
Write-Output 'Installed apps:'
if ($env:SB451_STUB_LIST_ROW) { Write-Output "$env:SB451_STUB_LIST_ROW 1.0.0 stub" }
'@

        # libexec\scoop-update.ps1 -- scoop reports per-app status with
        # Write-Host, so this mirrors that: out of process it has to reach the
        # engine as the child's stdout for the "(latest version)" marker to
        # survive and map to AlreadyLatest.
        Set-Content -LiteralPath (Join-Path $libexec 'scoop-update.ps1') -Encoding utf8 -Value @'
$app = @($args | Where-Object { $_ -notlike '-*' })[0]
Write-Host "${app}: 1.0.0 (latest version)"
'@

        Set-Content -LiteralPath (Join-Path $bin 'scoop.ps1') -Encoding utf8 -Value @'
Set-StrictMode -Off
$subCommand = $Args[0]
$arguments = @($Args | Select-Object -Skip 1)
$cmdPath = Join-Path $PSScriptRoot "..\libexec\scoop-$subCommand.ps1"
if (-not (Test-Path -LiteralPath $cmdPath)) {
    Write-Output "stub scoop: no command '$subCommand'"
    return
}
& $cmdPath @arguments
'@

        # shims\scoop.ps1 -- the on-PATH forwarder, same shape as the real one.
        Set-Content -LiteralPath (Join-Path $shims 'scoop.ps1') -Encoding utf8 -Value @'
$path = Join-Path $PSScriptRoot '..\apps\scoop\current\bin\scoop.ps1'
& $path @args
'@

        return @{ Root = $root; MarkerPath = $markerPath }
    }
}

Describe 'scoop installs driven through the module survive a bundle -Force re-import' -Tag 'Light', 'Module' {

    BeforeEach {
        Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction Ignore
        # Import against the REAL scoop first so module scope holds the real
        # parse_app / Find-BucketDirectory, then swap in the stub root. That
        # is the production ordering: the module is imported once at profile
        # load, long before any install runs.
        Import-Module $script:psd1 -Force
        $script:stub       = script:New-StubScoopRoot -ModulePsd1 $script:psd1
        $script:savedScoop = $env:SCOOP
        $script:savedPath  = $env:PATH
        $env:SCOOP = $script:stub.Root
        $env:PATH = (Join-Path $script:stub.Root 'shims') + ';' + $env:PATH
    }

    AfterEach {
        $env:SCOOP = $script:savedScoop
        $env:PATH = $script:savedPath
        Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction Ignore
        Remove-Item -LiteralPath $script:stub.Root -Recurse -Force -ErrorAction Ignore
    }

    It 'reports Installed instead of losing ensure_install_dir_not_in_path mid-install' {
        $pkg = [pscustomobject]@{
            Name      = 'stubapp'
            Installer = 'scoop'
            Id        = 'stub/stubapp'
            Scope     = 'global'
        }
        $mod = Get-Module MarkMichaelis.ScoopBucket

        # Install-ScoopPackage is module-private, so invoke it through the
        # module's session state -- which is also the session state a real
        # Install-Package sweep runs in, and the one a `-Force` re-import
        # destroys.
        $result = $mod.Invoke({ param($p) Install-ScoopPackage -Package $p }, $pkg)

        $result.State | Should -Be 'Installed' -Because "scoop's install internals must stay reachable for the whole install; #451 saw 'The term ensure_install_dir_not_in_path is not recognized' here"
    }

    It 'actually ran the bundle script that re-imports the module with -Force' {
        # Guards the test itself: without this the assertion above could pass
        # on a stub that never exercised the teardown.
        $pkg = [pscustomobject]@{
            Name      = 'stubapp'
            Installer = 'scoop'
            Id        = 'stub/stubapp'
            Scope     = 'global'
        }
        $mod = Get-Module MarkMichaelis.ScoopBucket
        $null = $mod.Invoke({ param($p) Install-ScoopPackage -Package $p }, $pkg)

        Test-Path -LiteralPath $script:stub.MarkerPath | Should -BeTrue -Because 'the stub manifest installer.script must have run Import-Module -Force'
    }
}

Describe 'scoop updates driven through the module keep their output markers' -Tag 'Light', 'Module' {
    # The update engines capture scoop's chatter with `*>&1` and then regex it
    # for "(latest version)" / "is already installed" to tell Updated from
    # AlreadyLatest. Moving the call out of process changed where that text
    # comes from -- the child's stdout rather than the in-process Information
    # stream -- so pin that the marker still survives the crossing.
    BeforeEach {
        Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction Ignore
        Import-Module $script:psd1 -Force
        $script:stub = script:New-StubScoopRoot -ModulePsd1 $script:psd1
        $script:savedScoop = $env:SCOOP
        $script:savedPath = $env:PATH
        $env:SCOOP = $script:stub.Root
        $env:PATH = (Join-Path $script:stub.Root 'shims') + ';' + $env:PATH
        $env:SB451_STUB_LIST_ROW = 'stubapp'
    }

    AfterEach {
        $env:SCOOP = $script:savedScoop
        $env:PATH = $script:savedPath
        Remove-Item Env:\SB451_STUB_LIST_ROW -ErrorAction Ignore
        Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction Ignore
        Remove-Item -LiteralPath $script:stub.Root -Recurse -Force -ErrorAction Ignore
    }

    It 'maps a child-process "(latest version)" line to AlreadyLatest' {
        $pkg = [pscustomobject]@{
            Name      = 'stubapp'
            Installer = 'scoop'
            Id        = 'stub/stubapp'
            Scope     = 'global'
        }
        $mod = Get-Module MarkMichaelis.ScoopBucket
        $result = $mod.Invoke({ param($p) Update-ScoopPackage -Package $p }, $pkg)

        $result.State | Should -Be 'AlreadyLatest' -Because "scoop's Write-Host status has to reach the engine across the process boundary or every update would read as Updated"
    }
}

Describe 'Invoke-ScoopCommand plumbing' -Tag 'Light', 'Module' {

    BeforeAll { Import-Module $script:psd1 -Force }

    It 'classifies only the scoop subcommands that execute manifest scripts as mutating' {
        # install / uninstall / update / import are the four libexec commands
        # that reach install_app / uninstall_app / Invoke-HookScript in scoop
        # 0.6.0; everything else must stay in-process so a sweep does not pay a
        # process launch per read-only probe.
        $mod = Get-Module MarkMichaelis.ScoopBucket
        foreach ($cmd in 'install', 'uninstall', 'update', 'import', 'INSTALL') {
            $mod.Invoke({ param($c) Test-ScoopCommandRunsManifestScript $c }, $cmd) |
                Should -BeTrue -Because "'$cmd' runs a manifest script"
        }
        foreach ($cmd in 'list', 'status', 'info', 'which', 'prefix', 'search', 'bucket', 'hold', 'cleanup', 'cache', 'export') {
            $mod.Invoke({ param($c) Test-ScoopCommandRunsManifestScript $c }, $cmd) |
                Should -BeFalse -Because "'$cmd' cannot run a manifest script"
        }
    }

    It 'runs a PowerShell executable, never whatever process happens to host the runspace' {
        # The module can be imported into a runspace embedded in an arbitrary
        # host; `& <that host> -File scoop.ps1` would be nonsense.
        $resolved = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PowerShellHostPath }
        [System.IO.Path]::GetFileNameWithoutExtension($resolved) |
            Should -BeIn @('pwsh', 'powershell')
    }

    It 'fails with an actionable message when scoop cannot be located' {
        $mod = Get-Module MarkMichaelis.ScoopBucket
        {
            $mod.Invoke({
                    Mock Resolve-ScoopEntryScript { $null }
                    Invoke-ScoopCommand 'list'
                })
        } | Should -Throw -ExpectedMessage '*could not locate*'
    }
}

Describe 'mutating scoop dispatches run out of process' -Tag 'Light', 'Module' {
    # Drift guard: any scoop subcommand that can execute a manifest's
    # installer / uninstaller script must go through Invoke-ScoopCommand (a
    # child process). An in-process `& scoop <install|uninstall|update>` is
    # the #451 defect, and it is an easy thing to reintroduce by copying a
    # neighbouring read-only probe.
    BeforeDiscovery {
        $moduleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket'
        # Legacy.ps1 is deliberately NOT in this list. Its `scoop` wrapper
        # decides at RUNTIME via Test-ScoopCommandRunsManifestScript, so its
        # surviving `scoop.ps1 @args` branch and its `scoop.ps1 bucket rm ...`
        # calls are safe but would fail the literal allowlist below. The wrapper
        # gets behavioural coverage instead -- see the routing Describe above.
        $script:mutatingEngines = @(
            @{ File = (Join-Path $moduleDir 'Private\Install-ScoopPackage.ps1') }
            @{ File = (Join-Path $moduleDir 'Private\Uninstall-ScoopPackage.ps1') }
            @{ File = (Join-Path $moduleDir 'Private\Update-ScoopPackage.ps1') }
            @{ File = (Join-Path $moduleDir 'Private\Update-AllScoopPackages.ps1') }
            @{ File = (Join-Path $moduleDir 'Public\Install-Package.ps1') }
        )
    }

    It '<File> dispatches through Invoke-ScoopCommand' -ForEach $script:mutatingEngines {
        $content = Get-Content -LiteralPath $File -Raw
        $content | Should -Match 'Invoke-ScoopCommand'
    }

    It '<File> makes no in-process scoop call beyond the read-only probes' -ForEach $script:mutatingEngines {
        # Deliberately NOT a "does it mention install/uninstall/update" regex:
        # that only fires when the splatted variable happens to be named
        # $installArgs, so `scoop.ps1 @args` would slip straight through.
        # Instead, enumerate EVERY surviving in-process scoop invocation and
        # require its first argument to be a literal read-only subcommand.
        $content = Get-Content -LiteralPath $File -Raw
        $calls = [regex]::Matches($content, '(?m)(?:&\s+scoop|scoop\.ps1)\s+(?<arg>\S+)') |
            ForEach-Object { $_.Groups['arg'].Value }
        foreach ($call in $calls) {
            $call | Should -BeIn @('list', 'status') -Because "in-process 'scoop $call' can execute a manifest installer script and unload this module mid-run (#451); route it through Invoke-ScoopCommand"
        }
    }
}

Describe 'real scoop keeps its install internals reachable from the module path' -Tag 'Heavy', 'Install' {
    # Live counterpart to the stub test above: drives the REAL installed scoop
    # through the module's engine with a throwaway local manifest whose
    # installer.script re-imports the module with -Force. This is the guard
    # that notices if a future scoop release reshuffles install_app's helpers
    # (or how libexec\scoop-install.ps1 loads them) in a way the module path
    # cannot survive -- the stub above can only pin our own dispatch contract.
    #
    # Heavy/Install: it installs (and removes) one tiny app. Local only; the
    # Light gate never runs it.
    #
    # Note on the pre-fix failure mode: because this probe installs from a
    # manifest PATH, the old in-process route died even earlier, in the legacy
    # `scoop` wrapper's install branch (`-match "^$args$"` treats the path as a
    # regex). The Light stub test above is the one that pins the exact #451
    # error; this one pins that the real scoop install path works end to end.
    BeforeAll {
        $script:appName = 'sb451liveprobe'
        $script:probeRoot = Join-Path ([IO.Path]::GetTempPath()) "sb451-live-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $script:probeRoot | Out-Null

        $payload = Join-Path $script:probeRoot 'payload.txt'
        Set-Content -LiteralPath $payload -Value 'issue 451 live probe' -Encoding utf8
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $payload).Hash.ToLowerInvariant()

        $script:manifestPath = Join-Path $script:probeRoot "$($script:appName).json"
        [ordered]@{
            version   = '1.00.000'
            url       = ([uri]$payload).AbsoluteUri
            hash      = "sha256:$hash"
            installer = [ordered]@{
                script = @(
                    "Import-Module '$($script:psd1 -replace "'", "''")' -Force",
                    "Write-Host '$($script:appName): bucket module re-imported with -Force'"
                )
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:manifestPath -Encoding utf8

        Import-Module $script:psd1 -Force
    }

    AfterAll {
        $mod = Get-Module MarkMichaelis.ScoopBucket
        if ($mod -and $script:appName) {
            try { $null = $mod.Invoke({ param($n) Invoke-ScoopCommand uninstall $n *>&1 }, $script:appName) } catch { }
        }
        if ($script:probeRoot) {
            Remove-Item -LiteralPath $script:probeRoot -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'installs an app whose manifest installer.script re-imports the module with -Force' {
        $pkg = [pscustomobject]@{
            Name      = $script:appName
            Installer = 'scoop'
            Id        = $script:manifestPath
            Scope     = 'user'
        }
        $mod = Get-Module MarkMichaelis.ScoopBucket
        $result = $mod.Invoke({ param($p) Install-ScoopPackage -Package $p }, $pkg)

        $result.State | Should -Be 'Installed' -Because "real scoop's install_app must still reach ensure_install_dir_not_in_path after the manifest script re-imports this module (#451)"
    }
}

Describe 'the exported scoop wrapper routes mutating subcommands out of process' -Tag 'Light', 'Module' {
    # `scoop` is in FunctionsToExport, so this wrapper SHADOWS the real scoop
    # command in every session that imports the module -- an interactive
    # `scoop install <bundle>` lands here, not in Install-Package. In-process
    # dispatch there reproduces #451 in full.
    BeforeAll { Import-Module $script:psd1 -Force }

    BeforeEach {
        $script:seen = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-ScoopCommand {
            $script:seen.Add(@($ArgumentList))
            $global:LASTEXITCODE = 0
        }
    }

    It 'sends <Subcommand> to the child process' -ForEach @(
        @{ Subcommand = 'install' }
        @{ Subcommand = 'uninstall' }
        @{ Subcommand = 'update' }
        @{ Subcommand = 'import' }
    ) {
        # A deliberately non-existent app: if this ever regresses to in-process
        # dispatch the call reaches the REAL scoop, and it must then be unable to
        # touch anything on the machine. (Naming a real app here once cost a
        # live install + uninstall of ripgrep.)
        $mod = Get-Module MarkMichaelis.ScoopBucket
        $mod.Invoke({ param($c) scoop $c 'sb451/no-such-app-451' }, $Subcommand)

        $script:seen.Count | Should -Be 1 -Because "'scoop $Subcommand' executes manifest scripts and must not run inside this module's session state"
        $script:seen[0][0] | Should -Be $Subcommand
    }

    It 'keeps read-only subcommands in-process' {
        $mod = Get-Module MarkMichaelis.ScoopBucket
        $mod.Invoke({
                # A local shadow stands in for the real scoop.ps1 on PATH.
                function scoop.ps1 { 'Installed apps:' }
                $null = scoop list ripgrep
            })

        $script:seen.Count | Should -Be 0 -Because 'a child process per read-only probe would cost a sweep seconds for no benefit'
    }
}
