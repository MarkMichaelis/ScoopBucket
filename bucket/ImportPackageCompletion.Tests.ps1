#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Light-suite tests for Import-PackageCompletion — the helper that
    activates a package's tab-completion in the current pwsh session
    by re-resolving the completion source from its declarative
    [Package] data and invoking Register-ArgumentCompleter in-process.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
}

Describe 'Import-PackageCompletion' -Tag 'Light','Module' {

    BeforeEach {
        # A throw-away CLI name + NativeCommandScript per test so
        # Register-ArgumentCompleter -Native registrations from prior
        # tests can't pollute subsequent assertions.
        $script:cli = "ipctest$([int][math]::Abs([guid]::NewGuid().GetHashCode()))"
        $script:pkg = [Package]@{
            Name        = "Probe-$($script:cli)"
            Installer   = 'winget'
            Id          = "Test.$($script:cli)"
            CliCommands = @($script:cli)
            Completion  = 'native'
            ExpectedCompletions = @{ $script:cli = @('one','two','three') }
            NativeCommandScript = [scriptblock]::Create(@"
@'
Register-ArgumentCompleter -Native -CommandName $($script:cli) -ScriptBlock {
    param(`$w, `$a, `$c)
    @('one','two','three') | Where-Object { `$_ -like "`$w*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
'@
"@)
        }
    }

    It 'returns Registered action when given a Package directly' {
        $r = Import-PackageCompletion -Package $script:pkg
        $r.Count        | Should -Be 1
        $r[0].Cli       | Should -Be $script:cli
        $r[0].Action    | Should -Be 'Registered'
        $r[0].Source    | Should -Be 'Native'
    }

    It 'accepts Package objects from the pipeline' {
        $r = @($script:pkg) | Import-PackageCompletion
        $r[0].Action | Should -Be 'Registered'
    }

    It 'reports NotFound for a CLI no bundle exposes' {
        $r = Import-PackageCompletion -Cli 'definitely-not-a-real-cli-zz9'
        $r.Count     | Should -Be 1
        $r[0].Action | Should -Be 'NotFound'
    }

    It 'reports Skipped when no completion source resolves' {
        # Package.Validate() forbids Completion='native' without a
        # NativeCommandScript, so we construct a "native" package whose
        # script emits nothing. Resolve-PackageCompletionSource then
        # falls back to PSCompletions; with no catalog entry for our
        # random CLI name, the result is Skipped.
        $empty = [Package]@{
            Name        = "Empty-$($script:cli)"
            Installer   = 'winget'
            Id          = "Test.Empty.$($script:cli)"
            CliCommands = @($script:cli)
            Completion  = 'native'
            ExpectedCompletions = @{ $script:cli = @('one','two','three') }
            NativeCommandScript = { '' }
        }
        $r = Import-PackageCompletion -Package $empty
        $r[0].Action | Should -Be 'Skipped'
    }

    It 'actually registers a completer visible to TabExpansion2 in the current session' {
        # Resolve-PackageCompletionSource guards its output with
        # `if (Get-Command $Cli) {...}`, so the CLI must be on PATH for
        # the registration to actually run. Drop a stub script and
        # prepend its directory to PATH for the duration of the test.
        $stubDir = Join-Path $TestDrive ("stub-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $stubDir | Out-Null
        $stub = Join-Path $stubDir "$($script:cli).ps1"
        Set-Content -Path $stub -Value '# stub' -Encoding UTF8
        # Add as a real command on PATH (.ps1 isn't a native exe, but
        # Get-Command finds it as ExternalScript, which is enough for
        # the guard to evaluate truthy).
        $savedPath = $env:PATH
        $env:PATH = "$stubDir;$savedPath"
        try {
            $null = Import-PackageCompletion -Package $script:pkg
            $line = "$($script:cli) "
            $cc = [System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null)
            $texts = @($cc.CompletionMatches | ForEach-Object { $_.CompletionText })
            $texts | Should -Contain 'one'
            $texts | Should -Contain 'two'
            $texts | Should -Contain 'three'
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'is idempotent (re-registers without error)' {
        $r1 = Import-PackageCompletion -Package $script:pkg
        $r2 = Import-PackageCompletion -Package $script:pkg
        $r1[0].Action | Should -Be 'Registered'
        $r2[0].Action | Should -Be 'Registered'
    }
}
