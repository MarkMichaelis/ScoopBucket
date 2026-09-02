#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# Procedural completion repair (#397).
#
# gh, gk, pwsh, powershell and wsl are registered by a bare
# Register-CliCompletion call inside their install script rather than by a
# [Package], so Update-PackageCompletion's bundle walk cannot see them. They
# were therefore unreachable from any repair path, and re-running the owning
# script is not an option because those scripts also install software.
#
# CompletionCoverage.psd1 now carries the recipe needed to re-register them.
# That duplicates values which also live in the install scripts, so the drift
# guard below is load-bearing: it is the only thing keeping the catalog honest.
# ----------------------------------------------------------------------------

BeforeAll {
    $script:bucketDir = $PSScriptRoot
    $script:psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
    $script:catalog = Import-PowerShellDataFile -Path (Join-Path $script:bucketDir 'CompletionCoverage.psd1')
    $script:registered = @($script:catalog.Clis | Where-Object { $_.Status -eq 'Registered' })

    # Parse `$<name>Switches = @('-a','-b')` assignments out of a script via
    # the AST, so the guard survives reformatting of the source.
    function script:Get-SwitchArray {
        param([string]$Path, [string]$VariableName)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $assign = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $n.Left.VariablePath.UserPath -eq $VariableName
            }, $true) | Select-Object -First 1
        if (-not $assign) { return $null }
        return @($assign.Right.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true) | ForEach-Object { $_.Value })
    }
}

Describe 'Completion catalog carries a usable repair recipe' -Tag 'Light','Completion' {

    It 'every Registered entry declares exactly one of NativeCommand or Switches' {
        foreach ($e in $script:registered) {
            $hasCommand  = [bool]$e.NativeCommand
            $hasSwitches = [bool]$e.Switches
            "$($e.Cli):$hasCommand/$hasSwitches" | Should -Not -Be "$($e.Cli):False/False" -Because "$($e.Cli) cannot be repaired without a recipe"
            "$($e.Cli):$hasCommand/$hasSwitches" | Should -Not -Be "$($e.Cli):True/True"  -Because "$($e.Cli) declares two conflicting recipes"
        }
    }

    It 'covers the five known procedural CLIs' {
        @($script:registered.Cli) | Should -Contain 'gh'
        @($script:registered.Cli) | Should -Contain 'gk'
        @($script:registered.Cli) | Should -Contain 'pwsh'
        @($script:registered.Cli) | Should -Contain 'powershell'
        @($script:registered.Cli) | Should -Contain 'wsl'
    }
}

Describe 'Catalog recipe matches the owning install script (drift guard)' -Tag 'Light','Completion' {

    It '<Cli> NativeCommand still matches <Script>' -ForEach @(
        @{ Cli = 'gh'; Script = 'developer\GitConfigure.ps1' }
        @{ Cli = 'gk'; Script = 'developer\GitConfigure.ps1' }
    ) {
        $entry = $script:registered | Where-Object Cli -EQ $Cli
        $src = Get-Content -Raw -Path (Join-Path $script:bucketDir $Script)
        # The script passes the same command inside -NativeCommand { ... }.
        $src | Should -Match ([regex]::Escape($entry.NativeCommand)) -Because "catalog recipe for $Cli must be the command $Script actually runs"
    }

    It '<Cli> Switches still match <Script>' -ForEach @(
        @{ Cli = 'pwsh';       Variable = 'pwshSwitches';       Script = 'developer\PowerShell.ps1' }
        @{ Cli = 'powershell'; Variable = 'powershellSwitches'; Script = 'developer\PowerShell.ps1' }
        @{ Cli = 'wsl';        Variable = 'wslSwitches';        Script = 'developer\PowerShell.ps1' }
    ) {
        $entry = $script:registered | Where-Object Cli -EQ $Cli
        $fromScript = script:Get-SwitchArray -Path (Join-Path $script:bucketDir $Script) -VariableName $Variable
        $fromScript | Should -Not -BeNullOrEmpty -Because "could not find `$$Variable in $Script"
        # Order matters only for readability; compare as sets.
        (@($entry.Switches) | Sort-Object) -join ',' |
            Should -Be ((@($fromScript) | Sort-Object) -join ',') -Because "catalog switches for $Cli have drifted from $Script"
    }
}

Describe 'Get-ProceduralCompletionDefinition' -Tag 'Light','Completion' {

    It 'returns only Registered entries, never ModuleActivated ones' {
        $defs = & $script:mod { param($b) Get-ProceduralCompletionDefinition -BucketPath $b } $script:bucketDir
        @($defs.Cli) | Should -Contain 'gh'
        # git/choco/scoop get completion from an upstream module the install
        # script activates -- there is no sentinel block here to repair.
        @($defs.Cli) | Should -Not -Contain 'git'
        @($defs.Cli) | Should -Not -Contain 'choco'
        @($defs.Cli) | Should -Not -Contain 'scoop'
    }

    It 'renders a runnable completer for a Switches-based CLI' {
        $defs = & $script:mod { param($b) Get-ProceduralCompletionDefinition -BucketPath $b } $script:bucketDir
        $pwshDef = $defs | Where-Object Cli -EQ 'pwsh'
        $text = & $pwshDef.NativeCommand
        $text | Should -Match 'Register-ArgumentCompleter -Native -CommandName pwsh'
        $text | Should -Match "'-NoProfile'"
    }

    It 'returns nothing when the catalog is absent' {
        $empty = Join-Path $TestDrive 'no-catalog'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $defs = & $script:mod { param($b) Get-ProceduralCompletionDefinition -BucketPath $b } $empty
        @($defs).Count | Should -Be 0
    }
}

Describe 'Update-PackageCompletion repairs procedural CLIs' -Tag 'Light','Completion' {

    It 'skips a procedural CLI that is not installed' {
        # Principle: only register what is installed.
        $sandboxProfile = Join-Path $TestDrive 'skip-profile.ps1'
        Set-Content -Path $sandboxProfile -Value '' -NoNewline
        # NOTE: Update-PackageCompletion returns `, $arr` -- the array arrives
        # as a single object, so do NOT re-wrap it with @() before filtering.
        $out  = Update-PackageCompletion -BucketPath $script:bucketDir -ProfilePath $sandboxProfile -WarningAction SilentlyContinue 3>$null
        $rows = @($out | Where-Object { $_.Bundle -eq 'procedural' })
        $rows.Count | Should -BeGreaterThan 0 -Because 'the procedural walk must emit a row per catalogued CLI'
        foreach ($row in $rows) {
            if (-not (Get-Command $row.Cli -ErrorAction SilentlyContinue)) {
                $row.Action | Should -Be 'Skipped'
                $row.Reason | Should -Match 'not on PATH'
            }
        }
    }

    It 'never re-processes a CLI a declarative package already handled' {
        # The procedural walk runs second. Without a precedence rule it
        # overwrites the richer declarative registration (which can carry
        # pre-captured native output) with the catalog's fallback recipe.
        $sandboxProfile = Join-Path $TestDrive 'precedence-profile.ps1'
        Set-Content -Path $sandboxProfile -Value '' -NoNewline
        $out = Update-PackageCompletion -BucketPath $script:bucketDir -ProfilePath $sandboxProfile -IncludeUnchanged -WarningAction SilentlyContinue 3>$null
        $byCli = @($out) | Group-Object Cli
        foreach ($g in $byCli) {
            $bundles = @($g.Group | ForEach-Object { $_.Bundle } | Sort-Object -Unique)
            if ($bundles -contains 'procedural') {
                $bundles.Count | Should -Be 1 -Because "$($g.Name) must be claimed by either a declarative package or the procedural catalog, never both"
            }
        }
    }

    It 'preserves an existing block unless -Force' {
        $sandboxProfile = Join-Path $TestDrive 'preserve-profile.ps1'
        Set-Content -Path $sandboxProfile -Value '' -NoNewline
        Update-PackageCompletion -BucketPath $script:bucketDir -ProfilePath $sandboxProfile -WarningAction SilentlyContinue 3>$null | Out-Null
        # Preserved rows are filtered from the default output, so ask for them.
        $all = Update-PackageCompletion -BucketPath $script:bucketDir -ProfilePath $sandboxProfile -IncludeUnchanged -WarningAction SilentlyContinue 3>$null
        $row = @($all | Where-Object { $_.Bundle -eq 'procedural' -and $_.Cli -eq 'pwsh' })
        $row.Count | Should -Be 1
        $row[0].Action | Should -Be 'Preserved'
    }
}
