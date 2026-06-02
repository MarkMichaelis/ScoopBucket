#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for the MarkMichaelis.ScoopBucket module: covers the manifest, module
# import (including [Package] class projection into caller scope via
# ScriptsToProcess), exported surface, and the Package class invariants
# enforced by Validate(). All tagged Light so they run on every PR.

BeforeAll {
    $script:moduleRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket')
    $script:manifestPath = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'
    $script:classPath    = Join-Path $script:moduleRoot 'Classes\Package.ps1'

    # Remove any leftover module from a previous test run so each test
    # starts from a clean slate.
    Get-Module MarkMichaelis.ScoopBucket -All | Remove-Module -Force -ErrorAction SilentlyContinue

    # Dot-source the class so [Package] is reachable in test scope without
    # depending on `using module` (which has parse-time semantics that
    # don't compose with our describe/it layout).
    . $script:classPath
}

AfterAll {
    Get-Module MarkMichaelis.ScoopBucket -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'MarkMichaelis.ScoopBucket module manifest' -Tag 'Light', 'Module' {
    It 'has a valid manifest' {
        $manifest = Test-ModuleManifest -Path $script:manifestPath -ErrorAction Stop
        $manifest.Name      | Should -Be 'MarkMichaelis.ScoopBucket'
        $manifest.Version   | Should -BeGreaterOrEqual ([version]'0.1.0')
    }

    It 'exports the documented public functions' {
        $manifest = Test-ModuleManifest -Path $script:manifestPath
        $exported = $manifest.ExportedFunctions.Keys
        # Strong contract: every declarative-pipeline + bootstrap-helper
        # function we promise to bundle authors must be exported. The list
        # is a superset assertion (uses -Contain) so adding new helpers in
        # the future does not require touching this test.
        foreach ($fn in @(
            'Add-MachinePath',
            'Get-Package',
            'Install-Package',
            'Invoke-PackageInstall',
            'Test-IsElevated',
            'Update-PathFromRegistry',
            'Register-CliCompletion',
            'Install-LocalManifest',
            'Test-ScoopPackageInstalled',
            'Test-ChocolateyPackageInstalled',
            'Test-Command'
        )) {
            $exported | Should -Contain $fn
        }
    }

    It 'declares Classes\Package.ps1 in ScriptsToProcess' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $data.ScriptsToProcess | Should -Contain (Join-Path 'Classes' 'Package.ps1')
    }
}

Describe 'MarkMichaelis.ScoopBucket module import' -Tag 'Light', 'Module' {
    BeforeAll {
        Import-Module $script:manifestPath -Force -ErrorAction Stop
    }

    AfterAll {
        Remove-Module MarkMichaelis.ScoopBucket -Force -ErrorAction SilentlyContinue
    }

    It 'imports cleanly' {
        Get-Module MarkMichaelis.ScoopBucket | Should -Not -BeNullOrEmpty
    }

    It 'exports the public functions after import' {
        $commands = Get-Command -Module MarkMichaelis.ScoopBucket | ForEach-Object Name
        foreach ($fn in @(
            'Add-MachinePath',
            'Get-Package',
            'Install-Package',
            'Invoke-PackageInstall',
            'Test-IsElevated',
            'Update-PathFromRegistry',
            'Register-CliCompletion',
            'Install-LocalManifest',
            'Test-ScoopPackageInstalled',
            'Test-ChocolateyPackageInstalled',
            'Test-Command'
        )) {
            $commands | Should -Contain $fn
        }
    }

    It 'projects the Package class into a fresh pwsh session via ScriptsToProcess' {
        # ScriptsToProcess loads into the *caller* scope, which inside a
        # Pester run is the test runspace. The cleanest way to verify the
        # contract is to spawn a fresh pwsh, Import-Module, and ask whether
        # [Package] is reachable.
        $script = @"
            `$ErrorActionPreference = 'Stop'
            Import-Module '$script:manifestPath' -Force
            [Package].FullName
"@
        $out = & pwsh -NoProfile -NonInteractive -Command $script
        $LASTEXITCODE | Should -Be 0
        ($out | Out-String).Trim() | Should -Be 'Package'
    }
}

Describe 'Package class — construction and defaults' -Tag 'Light', 'Module' {
    It 'accepts a hashtable cast and applies defaults' {
        $p = [Package]@{ Name = 'demo'; Installer = 'scoop'; Id = 'main/demo' }
        $p.Name        | Should -Be 'demo'
        $p.Installer   | Should -Be 'scoop'
        $p.Id          | Should -Be 'main/demo'
        $p.Scope       | Should -Be 'global'
        $p.Completion  | Should -Be 'none'
        $p.CliCommands | Should -Be @()
        $p.DependsOn   | Should -Be @()
    }

    It 'rejects unknown property names at cast time' {
        { [Package]@{ Name = 'demo'; Installer = 'scoop'; Id = 'main/demo'; Nope = 'bad' } } |
            Should -Throw
    }

    It 'rejects out-of-set Installer values' {
        { [Package]@{ Name = 'demo'; Installer = 'apt'; Id = 'demo' } } | Should -Throw
    }

    It 'rejects out-of-set Completion values' {
        { [Package]@{ Name = 'demo'; Installer = 'scoop'; Id = 'main/demo'; Completion = 'sometimes' } } |
            Should -Throw
    }
}

Describe 'Package.Validate() — happy paths' -Tag 'Light', 'Module' {
    It 'passes a minimal scoop entry with bucket prefix' {
        $p = [Package]@{ Name = 'ripgrep'; Installer = 'scoop'; Id = 'main/ripgrep' }
        { $p.Validate() } | Should -Not -Throw
    }

    It 'passes a winget entry with msstore source' {
        $p = [Package]@{ Name = 'Foo'; Installer = 'winget'; Id = 'Foo.Bar'; Source = 'msstore' }
        { $p.Validate() } | Should -Not -Throw
    }

    It 'passes a custom entry with CustomInstallScript and no Id' {
        $p = [Package]@{
            Name                = 'Sideload'
            Installer           = 'custom'
            CustomInstallScript = { 'ok' }
            VerifyScript        = { $true }
        }
        { $p.Validate() } | Should -Not -Throw
    }

    It 'auto-sets Installer=custom when CustomInstallScript is the only signal' {
        $p = [Package]@{
            Name                = 'Sideload'
            CustomInstallScript = { 'ok' }
        }
        $p.Validate()
        $p.Installer | Should -Be 'custom'
    }

    It 'passes a native-completion entry with NativeCommandScript' {
        $p = [Package]@{
            Name                = 'gh'
            Installer           = 'winget'
            Id                  = 'GitHub.cli'
            CliCommands         = @('gh')
            Completion          = 'native'
            NativeCommandScript = { 'gh completion -s powershell' }
            ExpectedCompletions = @{ gh = @('auth','repo','pr') }
        }
        { $p.Validate() } | Should -Not -Throw
    }

    It 'requires ExpectedCompletions when Completion != none' {
        $p = [Package]@{
            Name                = 'gh'
            Installer           = 'winget'
            Id                  = 'GitHub.cli'
            CliCommands         = @('gh')
            Completion          = 'native'
            NativeCommandScript = { 'noop' }
        }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*ExpectedCompletions*'
    }

    It 'requires an ExpectedCompletions entry for every CliCommands name' {
        $p = [Package]@{
            Name                = 'gh'
            Installer           = 'winget'
            Id                  = 'GitHub.cli'
            CliCommands         = @('gh','gh2')
            Completion          = 'native'
            NativeCommandScript = { 'noop' }
            ExpectedCompletions = @{ gh = @('auth') }
        }
        { $p.Validate() } | Should -Throw -ExpectedMessage "*missing a key for CLI 'gh2'*"
    }
}

Describe 'Package.Validate() — invariants' -Tag 'Light', 'Module' {
    It 'requires Name' {
        $p = [Package]@{ Installer = 'scoop'; Id = 'main/x' }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*Name is required*'
    }

    It 'requires Installer (or CustomInstallScript)' {
        $p = [Package]@{ Name = 'x' }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*Installer is required*'
    }

    It 'requires Id for non-custom installers' {
        $p = [Package]@{ Name = 'x'; Installer = 'winget' }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*Id is required*'
    }

    It 'requires CustomInstallScript when Installer=custom is explicit' {
        $p = [Package]@{ Name = 'x'; Installer = 'custom' }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*CustomInstallScript is required*'
    }

    It 'rejects Source=msstore on non-winget installers' {
        $p = [Package]@{ Name = 'x'; Installer = 'scoop'; Id = 'main/x'; Source = 'msstore' }
        { $p.Validate() } | Should -Throw -ExpectedMessage "*Source='msstore' is only valid*"
    }

    It 'rejects unprefixed scoop ids' {
        $p = [Package]@{ Name = 'x'; Installer = 'scoop'; Id = 'ripgrep' }
        { $p.Validate() } | Should -Throw -ExpectedMessage "*must include an explicit*"
    }

    It 'requires NativeCommandScript when Completion=native' {
        $p = [Package]@{
            Name        = 'x'
            Installer   = 'scoop'
            Id          = 'main/x'
            Completion  = 'native'
        }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*NativeCommandScript is required*'
    }

    It 'requires NativeCommandScript when Completion=auto' {
        $p = [Package]@{
            Name        = 'x'
            Installer   = 'scoop'
            Id          = 'main/x'
            Completion  = 'auto'
        }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*NativeCommandScript is required*'
    }

    It 'rejects NativeCompletionKind when no NativeCommandScript is present' {
        $p = [Package]@{
            Name        = 'x'
            Installer   = 'scoop'
            Id          = 'main/x'
            NativeCompletionKind = 'native'
        }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*NativeCompletionKind*only valid alongside a NativeCommandScript*'
    }

    It 'accepts NativeCompletionKind alongside a NativeCommandScript' {
        $p = [Package]@{
            Name        = 'x'
            Installer   = 'scoop'
            Id          = 'main/x'
            CliCommands = @('x')
            Completion  = 'native'
            NativeCompletionKind = 'native'
            NativeCommandScript  = { 'x completion powershell' }
            ExpectedCompletions  = @{ x = @('--help') }
        }
        $p.GetValidationError() | Should -BeNullOrEmpty
    }

    It 'rejects self-referential DependsOn' {
        $p = [Package]@{
            Name      = 'x'
            Installer = 'scoop'
            Id        = 'main/x'
            DependsOn = @('x')
        }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*cannot reference itself*'
    }

    It 'rejects self-referential Companions' {
        $p = [Package]@{
            Name       = 'x'
            Installer  = 'scoop'
            Id         = 'main/x'
            Companions = @('x')
        }
        { $p.Validate() } | Should -Throw -ExpectedMessage '*Companions cannot reference itself*'
    }
}

Describe 'Package.GetValidationError() — non-throwing probe (#276)' -Tag 'Light', 'Module' {
    It 'returns $null for a valid package without throwing' {
        $p = [Package]@{ Name = 'x'; Installer = 'scoop'; Id = 'main/x' }
        $err = $p.GetValidationError()   # would throw the test if it threw
        $err | Should -BeNullOrEmpty
    }

    It 'returns the first violation as a string instead of throwing' {
        $p = [Package]@{ Name = 'x'; Installer = 'custom' }   # missing CustomInstallScript
        $err = $p.GetValidationError()
        $err | Should -BeOfType ([string])
        $err | Should -Match 'CustomInstallScript is required'
    }

    It 'does not leak an ErrorRecord onto the caller error stream' {
        # The whole point of the non-throwing core: probing an invalid
        # package must not surface a spurious error (a class-method throw
        # under an advanced function double-reports even when caught).
        $p = [Package]@{ Name = 'x'; Installer = 'scoop'; Id = 'no-prefix' }
        $Error.Clear()
        $null = $p.GetValidationError()
        $Error.Count | Should -Be 0
    }

    It 'Validate() still throws the same message GetValidationError() reports' {
        $p = [Package]@{ Name = 'x'; Installer = 'scoop'; Id = 'no-prefix' }
        $probe = $p.GetValidationError()
        { $p.Validate() } | Should -Throw -ExpectedMessage "*$probe*"
    }
}

Describe 'Package.Companions field' -Tag 'Light', 'Module' {
    It 'defaults to an empty array' {
        $p = [Package]@{ Name = 'demo'; Installer = 'scoop'; Id = 'main/demo' }
        ,$p.Companions | Should -BeOfType ([string[]])
        $p.Companions.Count | Should -Be 0
    }

    It 'accepts a non-empty Companions list at cast time' {
        $p = [Package]@{ Name = 'A'; Installer = 'winget'; Id = 'X.A'; Companions = @('B') }
        $p.Companions | Should -Be @('B')
        { $p.Validate() } | Should -Not -Throw
    }
}

Describe 'Package.ToString()' -Tag 'Light', 'Module' {
    It 'formats engine + name + id' {
        $p = [Package]@{ Name = 'ripgrep'; Installer = 'scoop'; Id = 'main/ripgrep' }
        $p.ToString() | Should -Be '[scoop] ripgrep (main/ripgrep)'
    }

    It 'omits the parenthetical when Id is empty' {
        $p = [Package]@{
            Name = 'Readwise'
            Installer = 'custom'
            CustomInstallScript = { 'ok' }
        }
        $p.ToString() | Should -Be '[custom] Readwise'
    }
}
