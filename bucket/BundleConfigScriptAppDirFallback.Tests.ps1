#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pins the scoop app-dir fallback for the bundle ConfigScript hooks that apply
    a committed .jsonc snapshot (#431).

.DESCRIPTION
    OSBasePackages (Windows Terminal) and ClientBasePackages (PowerToys) both
    reapply a committed configuration snapshot from their ConfigScript. Each
    bundle manifest lists ONLY its .ps1 in `url[]`, so under `scoop install` the
    app directory (`<scoopRoot>\apps\<bundle>\<version>\`) contains the bundle
    script and nothing else -- no `os\` sibling. $PSScriptRoot IS set there (to
    the app dir), so a hook that branches on $PSScriptRoot alone hands the
    import cmdlet a path that was never downloaded, the cmdlet throws, and
    Invoke-PackageInstall aborts the whole bundle (#431 aborted OSBasePackages
    on package 1 of 16).

    The contract these tests pin: each ConfigScript must test for the FILE, not
    for $PSScriptRoot -- passing the explicit path only when it exists, and
    otherwise falling back to the import cmdlet's module-relative default, which
    resolves out of scoop's bucket checkout where the snapshot does exist.

    Both layouts are staged from the REAL production bundle text (the
    declarative `$Packages = ...` assignment, extracted via the AST so the
    bundle's imperative install body never runs), written to a real .ps1 in a
    staged app dir. A real file is what makes the package scriptblocks resolve
    $PSScriptRoot to that directory, exactly as under `scoop install`;
    Get-BundlePackageObjects cannot be used here because its ::Create'd
    scriptblocks carry no File and so see an EMPTY $PSScriptRoot.
#>

Describe 'Bundle ConfigScript snapshot hooks under the scoop app-dir layout' -Tag 'Light', 'Bundle' {

    BeforeAll {
        $script:moduleRoot = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket'
        $scoopBucketPsd1 = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) {
            Import-Module $scoopBucketPsd1 -Force
        } else {
            Import-Module MarkMichaelis.ScoopBucket -Force
        }
        # Make [Package] reachable for the staged bundle's cast without relying
        # on where ScriptsToProcess landed it (same approach as Package.Tests.ps1).
        . (Join-Path $script:moduleRoot 'Classes\Package.ps1')

        # Stage a fake scoop app dir containing only the bundle's declarative
        # $Packages assignment, lifted verbatim from the shipped bundle. With
        # -WithSnapshot the `os\<name>` sibling is created too (the bucket
        # checkout layout); without it, the app-dir layout scoop actually
        # produces. Returns the staged .ps1 path for the caller to dot-source.
        function New-StagedBundleScript {
            param(
                [Parameter(Mandatory)][string]$BundleName,
                [string]$WithSnapshot
            )
            $source = Join-Path $PSScriptRoot "$BundleName.ps1"
            $tokens = $null; $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
            $assignment = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq 'Packages'
                }, $true)
            if (-not $assignment) { throw "$BundleName does not declare a `$Packages assignment." }

            $appDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $appDir | Out-Null
            if ($WithSnapshot) {
                $snapshot = Join-Path $appDir "os\$WithSnapshot"
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $snapshot) | Out-Null
                Set-Content -LiteralPath $snapshot -Value '{}' -Encoding utf8
            }
            $staged = Join-Path $appDir "$BundleName.ps1"
            Set-Content -LiteralPath $staged -Value $assignment.Extent.Text -Encoding utf8
            return $staged
        }
    }

    Context 'OSBasePackages: Windows Terminal' {

        It 'falls back to the module default when the app dir has no sibling os\*.jsonc' {
            $staged = New-StagedBundleScript -BundleName 'OSBasePackages'
            . $staged
            $package = $Packages | Where-Object Name -eq 'Windows Terminal'

            # Plain stub rather than Mock: it shadows the module's exported
            # function in this scope (which is where the staged bundle's
            # scriptblocks were bound), and $PSBoundParameters lets the
            # assertion distinguish "no -ConfigPath" from "-ConfigPath ''".
            $script:call = $null
            function Import-WindowsTerminalSettings {
                [CmdletBinding()] param([string]$ConfigPath)
                $script:call = @{ ConfigPath = $ConfigPath; Bound = $PSBoundParameters.ContainsKey('ConfigPath') }
            }

            { & $package.ConfigScript $package } | Should -Not -Throw
            $script:call | Should -Not -BeNullOrEmpty -Because 'the configuration must still be applied'
            $script:call.Bound | Should -BeFalse `
                -Because 'with no snapshot beside the bundle the hook must let Import-WindowsTerminalSettings resolve its module-relative default (the bucket checkout)'
        }

        It 'passes the local snapshot when it does sit beside the bundle (bucket checkout)' {
            $staged = New-StagedBundleScript -BundleName 'OSBasePackages' -WithSnapshot 'MarkMichaelisWindowsTerminalSettings.jsonc'
            . $staged
            $package = $Packages | Where-Object Name -eq 'Windows Terminal'

            $script:call = $null
            function Import-WindowsTerminalSettings {
                [CmdletBinding()] param([string]$ConfigPath)
                $script:call = @{ ConfigPath = $ConfigPath; Bound = $PSBoundParameters.ContainsKey('ConfigPath') }
            }

            { & $package.ConfigScript $package } | Should -Not -Throw
            $script:call.Bound | Should -BeTrue
            $script:call.ConfigPath | Should -Be (Join-Path (Split-Path -Parent $staged) 'os\MarkMichaelisWindowsTerminalSettings.jsonc')
        }
    }

    Context 'ClientBasePackages: PowerToys' {

        It 'falls back to the module default when the app dir has no sibling os\*.jsonc' {
            $staged = New-StagedBundleScript -BundleName 'ClientBasePackages'
            . $staged
            $package = $Packages | Where-Object Name -eq 'PowerToys'

            $script:call = $null
            function Import-PowerToysSettings {
                [CmdletBinding()] param([string]$SnapshotPath, [switch]$NoRestart)
                $script:call = @{ SnapshotPath = $SnapshotPath; Bound = $PSBoundParameters.ContainsKey('SnapshotPath'); NoRestart = [bool]$NoRestart }
            }

            { & $package.ConfigScript $package } | Should -Not -Throw
            $script:call | Should -Not -BeNullOrEmpty -Because 'the snapshot must still be restored'
            $script:call.NoRestart | Should -BeTrue -Because '-NoRestart must survive the fallback'
            $script:call.Bound | Should -BeFalse `
                -Because 'with no snapshot beside the bundle the hook must let Import-PowerToysSettings resolve its module-relative default (the bucket checkout)'
        }

        It 'passes the local snapshot when it does sit beside the bundle (bucket checkout)' {
            $staged = New-StagedBundleScript -BundleName 'ClientBasePackages' -WithSnapshot 'MarkMichaelisPowerToysSettings.jsonc'
            . $staged
            $package = $Packages | Where-Object Name -eq 'PowerToys'

            $script:call = $null
            function Import-PowerToysSettings {
                [CmdletBinding()] param([string]$SnapshotPath, [switch]$NoRestart)
                $script:call = @{ SnapshotPath = $SnapshotPath; Bound = $PSBoundParameters.ContainsKey('SnapshotPath'); NoRestart = [bool]$NoRestart }
            }

            { & $package.ConfigScript $package } | Should -Not -Throw
            $script:call.Bound | Should -BeTrue
            $script:call.NoRestart | Should -BeTrue
            $script:call.SnapshotPath | Should -Be (Join-Path (Split-Path -Parent $staged) 'os\MarkMichaelisPowerToysSettings.jsonc')
        }
    }
}
