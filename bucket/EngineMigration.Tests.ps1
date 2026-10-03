#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for #464: when a package's declared Installer changes, a
# machine that already installed it under the PREVIOUS engine must not end up
# with two copies silently -- and whichever copy survives must be the one that
# wins on PATH, not whichever shim directory happens to come first.
#
# The detection is deliberately parameterised (-CommandResolver / -EngineRoot)
# so every case below runs without a real cross-engine install.

BeforeAll {
    $script:repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'

    Get-Module MarkMichaelis.ScoopBucket -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1') -Force
    . (Join-Path $script:moduleRoot 'Classes\Package.ps1')
}

AfterAll {
    Get-Module MarkMichaelis.ScoopBucket -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-PackageEngineConflict' -Tag 'Light', 'Module' {

    BeforeAll {
        $script:roots = @{
            scoop      = @('C:\ProgramData\scoop', 'C:\Users\u\scoop')
            winget     = @('C:\Program Files\WinGet', 'C:\Users\u\AppData\Local\Microsoft\WinGet')
            choco      = @('C:\ProgramData\chocolatey')
            npmGlobal  = @('C:\Users\u\AppData\Roaming\npm')
            dotnetTool = @('C:\Users\u\.dotnet\tools')
        }
    }

    It 'reports the foreign engine when the CLI on PATH belongs to another engine' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\rclone.exe' }

            $conflict | Should -Not -BeNullOrEmpty
            $conflict.Engine | Should -Be 'scoop'
            $conflict.Cli    | Should -Be 'rclone'
            $conflict.Path   | Should -Be 'C:\ProgramData\scoop\shims\rclone.exe'
            $conflict.Declared | Should -BeFalse
        }
    }

    It 'is silent when the winning CLI belongs to the declared engine' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\Program Files\WinGet\Links\rclone.exe' } |
                Should -BeNullOrEmpty
        }
    }

    It 'is silent when no engine owns the winning path' {
        # A vendor installer that adds its own PATH entry is not an engine
        # conflict -- refusing to install there would be a false positive.
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'Git'; Installer = 'winget'; Id = 'Git.Git'
                CliCommands = @('git'); Completion = 'native'
                NativeCommandScript = { git completion }
                ExpectedCompletions = @{ git = @('commit') }
            }
            Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\Program Files\Git\cmd\git.exe' } |
                Should -BeNullOrEmpty
        }
    }

    It 'is silent when the CLI resolves to nothing at all' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) $null } |
                Should -BeNullOrEmpty
        }
    }

    It 'is silent for a package that declares no CliCommands' {
        # Nothing lands on PATH, so there is no PATH outcome to make
        # deterministic and nothing to detect.
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{ Name = 'Some App'; Installer = 'winget'; Id = 'Vendor.App' }
            Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\whatever.exe' } |
                Should -BeNullOrEmpty
        }
    }

    It 'is silent for Installer=custom, which owns no engine inventory' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'Thing'; Installer = 'custom'
                CustomInstallScript = { }
                CliCommands = @('thing'); Completion = 'native'
                NativeCommandScript = { thing completion }
                ExpectedCompletions = @{ thing = @('go') }
            }
            Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\thing.exe' } |
                Should -BeNullOrEmpty
        }
    }

    It 'infers an exact scoop uninstall command from the shim path' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\rclone.exe' } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            # Global install (outside the user profile) => -g, which plain
            # `scoop uninstall` would refuse to touch.
            $conflict.UninstallCommand | Should -Be 'scoop uninstall -g rclone'
        }
    }

    It 'drops -g for a user-scope scoop install under the user profile' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\Users\u\scoop\shims\rclone.exe' } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            $conflict.UninstallCommand | Should -Be 'scoop uninstall rclone'
        }
    }

    It 'resolves the owning scoop app from the app directory, not the shim name' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            # `adb` is shimmed by the scoop app named 'adb', but `fastboot`
            # comes from the SAME app -- the app directory is authoritative.
            $pkg = [Package]@{
                Name = 'Android platform-tools'; Installer = 'winget'; Id = 'Google.PlatformTools'
                CliCommands = @('fastboot'); Completion = 'native'
                NativeCommandScript = { fastboot help }
                ExpectedCompletions = @{ fastboot = @('devices') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\apps\adb\current\fastboot.exe' } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            $conflict.UninstallCommand | Should -Be 'scoop uninstall -g adb'
        }
    }

    It 'attributes <Case> correctly' -ForEach @(
        @{ Case = 'a nested root to the most specific engine'
           Roots = @{ choco = @('C:\ProgramData'); scoop = @('C:\ProgramData\scoop') }
           Path  = 'C:\ProgramData\scoop\shims\x.exe'; Expected = 'scoop' }
        @{ Case = 'a sibling directory with a shared prefix to nobody'
           Roots = @{ scoop = @('C:\ProgramData\scoop') }
           Path  = 'C:\ProgramData\scoopy\x.exe'; Expected = $null }
        @{ Case = 'a forward-slash path against a backslash root'
           Roots = @{ scoop = @('C:\ProgramData\scoop') }
           Path  = 'C:/ProgramData/scoop/shims/x.exe'; Expected = 'scoop' }
        @{ Case = 'a root declared with a trailing separator'
           Roots = @{ scoop = @('C:\ProgramData\scoop\') }
           Path  = 'C:\ProgramData\scoop\shims\x.exe'; Expected = 'scoop' }
        @{ Case = 'a path that differs only in case'
           Roots = @{ scoop = @('C:\ProgramData\scoop') }
           Path  = 'c:\programdata\SCOOP\shims\x.exe'; Expected = 'scoop' }
        @{ Case = 'the root directory itself to nobody'
           Roots = @{ scoop = @('C:\ProgramData\scoop') }
           Path  = 'C:\ProgramData\scoop'; Expected = $null }
    ) {
        $params = @{ Roots = $Roots; Path = $Path; Expected = $Expected }
        InModuleScope MarkMichaelis.ScoopBucket -Parameters $params {
            param($Roots, $Path, $Expected)
            $owner = Resolve-PathOwningEngine -Path $Path -EngineRoot $Roots
            if ($null -eq $Expected) { $owner | Should -BeNullOrEmpty }
            else { $owner | Should -Be $Expected }
        }
    }

    It 'reads the scoop shim sidecar so the app name is right, not the shim name' {
        # Live case that caught this: scoop's '7zip' app shims 7z.exe, so the
        # inferred `scoop uninstall -g 7z` names an app that does not exist and
        # the command handed to the user fails.
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = '7-Zip'; Installer = 'winget'; Id = '7zip.7zip'
                CliCommands = @('7z'); Completion = 'native'
                NativeCommandScript = { 7z }
                ExpectedCompletions = @{ '7z' = @('a') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\7z.exe' } `
                -ShimTargetResolver { param($path) 'C:\ProgramData\scoop\apps\7zip\current\7z.exe' } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            $conflict.UninstallCommand | Should -Be 'scoop uninstall -g 7zip'
        }
    }

    It 'falls back to the command name when no shim sidecar resolves' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\rclone.exe' } `
                -ShimTargetResolver { param($path) $null } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            $conflict.UninstallCommand | Should -Be 'scoop uninstall -g rclone'
        }
    }

    It 'parses the path out of a real scoop .shim sidecar' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) "shim-$([guid]::NewGuid().ToString('n'))"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                Set-Content -LiteralPath (Join-Path $dir '7z.shim') `
                    -Value 'path = "C:\ProgramData\scoop\apps\7zip\current\7z.exe"'
                Get-ScoopShimTarget -Path (Join-Path $dir '7z.exe') |
                    Should -Be 'C:\ProgramData\scoop\apps\7zip\current\7z.exe'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns nothing when the sidecar is absent' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Get-ScoopShimTarget -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-shim-464.exe') |
                Should -BeNullOrEmpty
        }
    }

    It 'prefers the declared PreviousId over anything inferred from the path' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            $pkg = [Package]@{
                Name = 'ripgrep'; Installer = 'winget'; Id = 'BurntSushi.ripgrep.MSVC'
                PreviousInstaller = 'scoop'; PreviousId = 'main/ripgrep'
                CliCommands = @('rg'); Completion = 'native'
                NativeCommandScript = { rg --generate complete-powershell }
                ExpectedCompletions = @{ rg = @('--help') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\rg.exe' } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            $conflict.Declared         | Should -BeTrue
            $conflict.UninstallCommand | Should -Be 'scoop uninstall -g ripgrep'
        }
    }

    It 'does not treat a declared predecessor on a DIFFERENT engine as declared' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            # Declaration says the predecessor was choco, but the copy actually
            # shadowing PATH is a scoop one. Auto-uninstalling on that mismatch
            # would be guessing; it must fall back to report-and-refuse.
            $pkg = [Package]@{
                Name = 'exiftool'; Installer = 'winget'; Id = 'OliverBetz.ExifTool'
                PreviousInstaller = 'choco'; PreviousId = 'exiftool'
                CliCommands = @('exiftool'); Completion = 'native'
                NativeCommandScript = { exiftool -ver }
                ExpectedCompletions = @{ exiftool = @('-ver') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) 'C:\ProgramData\scoop\shims\exiftool.exe' } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            $conflict.Engine   | Should -Be 'scoop'
            $conflict.Declared | Should -BeFalse
        }
    }

    It 'decides scoop -g from the configured roots, not the user profile: <Case>' -ForEach @(
        # SCOOP_GLOBAL redirected INSIDE the user profile. The user-profile
        # heuristic would drop -g and the printed command would exit non-zero
        # having removed nothing.
        @{ Case     = 'global root inside the user profile still gets -g'
           Scopes   = @{ Global = @('C:\Users\u\globalscoop'); User = @('C:\Users\u\scoop') }
           Path     = 'C:\Users\u\globalscoop\shims\rclone.exe'
           Expected = 'scoop uninstall -g rclone' }
        # SCOOP (user scope) redirected OUTSIDE the user profile. The heuristic
        # would add a spurious -g.
        @{ Case     = 'user root outside the user profile does not get -g'
           Scopes   = @{ Global = @('C:\ProgramData\scoop'); User = @('D:\scoop') }
           Path     = 'D:\scoop\shims\rclone.exe'
           Expected = 'scoop uninstall rclone' }
        @{ Case     = 'global wins when both roots are the same directory'
           Scopes   = @{ Global = @('C:\ProgramData\scoop'); User = @('C:\ProgramData\scoop') }
           Path     = 'C:\ProgramData\scoop\shims\rclone.exe'
           Expected = 'scoop uninstall -g rclone' }
        @{ Case     = 'an unmatched layout falls back to the user-profile heuristic'
           Scopes   = @{ Global = @(); User = @() }
           Path     = 'C:\Users\u\elsewhere\shims\rclone.exe'
           Expected = 'scoop uninstall rclone' }
    ) {
        $params = @{ Scopes = $Scopes; Path = $Path; Expected = $Expected }
        InModuleScope MarkMichaelis.ScoopBucket -Parameters $params {
            param($Scopes, $Path, $Expected)
            Resolve-EngineUninstallCommand -Engine 'scoop' -Path $Path -Cli 'rclone' `
                -ShimTargetResolver { param($p) $null } `
                -ScoopScopeRoot $Scopes -UserProfile 'C:\Users\u' |
                Should -Be $Expected
        }
    }

    It 'uses the declared PreviousId for a choco predecessor, not the binary name' {
        # choco package ids routinely differ from the exe they ship, so the
        # hand-run fallback command must use the declared id like every other
        # engine's branch does.
        InModuleScope MarkMichaelis.ScoopBucket {
            Resolve-EngineUninstallCommand -Engine 'choco' -Path 'C:\ProgramData\chocolatey\bin\et.exe' `
                -Cli 'et' -Id 'exiftool' |
                Should -Be 'choco uninstall -y exiftool'
        }
    }

    It 'builds an engine-appropriate command for <Engine>' -ForEach @(
        @{ Engine = 'choco';      Path = 'C:\ProgramData\chocolatey\bin\tool.exe';        Expected = 'choco uninstall -y tool' }
        @{ Engine = 'npmGlobal';  Path = 'C:\Users\u\AppData\Roaming\npm\tool.cmd';       Expected = 'npm uninstall --global tool' }
        @{ Engine = 'dotnetTool'; Path = 'C:\Users\u\.dotnet\tools\tool.exe';             Expected = 'dotnet tool uninstall -g tool' }
        @{ Engine = 'winget';     Path = 'C:\Program Files\WinGet\Links\tool.exe';        Expected = 'winget uninstall --exact tool' }
    ) {
        $params = @{ Roots = $script:roots; Path = $Path; Engine = $Engine; Expected = $Expected }
        InModuleScope MarkMichaelis.ScoopBucket -Parameters $params {
            param($Roots, $Path, $Engine, $Expected)
            $pkg = [Package]@{
                Name = 'Tool'; Installer = 'scoop'; Id = 'main/tool'
                CliCommands = @('tool'); Completion = 'native'
                NativeCommandScript = { tool completion }
                ExpectedCompletions = @{ tool = @('go') }
            }
            $conflict = Get-PackageEngineConflict -Package $pkg -EngineRoot $Roots `
                -CommandResolver { param($cli) $Path } -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @('C:\Users\u\scoop') } -UserProfile 'C:\Users\u'

            $conflict.Engine           | Should -Be $Engine
            $conflict.UninstallCommand | Should -Be $Expected
        }
    }
}

Describe 'Install refuses to create a second copy under a new engine' -Tag 'Light', 'Module' {

    BeforeAll {
        $script:roots = @{
            scoop  = @('C:\ProgramData\scoop')
            winget = @('C:\Program Files\WinGet')
        }
    }

    It 'fails the package instead of installing a duplicate, and names the fix' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap     { $Roots }
            Mock Get-CommandSourcePath { 'C:\ProgramData\scoop\shims\rclone.exe' }
            Mock Install-WingetPackage { @{ State = 'Installed'; Reason = $null } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion -ErrorAction SilentlyContinue

            Should -Invoke Install-WingetPackage -Times 0 -Exactly
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'scoop uninstall -g rclone'
            $r.Reason | Should -Match ([regex]::Escape('C:\ProgramData\scoop\shims\rclone.exe'))
        }
    }

    It 'leaves a package alone when the declared engine already owns its CLI' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap     { $Roots }
            Mock Get-CommandSourcePath { 'C:\Program Files\WinGet\Links\rclone.exe' }
            Mock Install-WingetPackage { @{ State = 'Installed'; Reason = $null } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Install-WingetPackage -Times 1 -Exactly
            $r.Status | Should -Be 'Installed'
        }
    }
}

Describe 'Declared predecessor migrates instead of refusing' -Tag 'Light', 'Module' {

    BeforeAll {
        $script:roots = @{
            scoop  = @('C:\ProgramData\scoop')
            winget = @('C:\Program Files\WinGet')
        }

    }

    It 'removes the predecessor first, then installs under the declared engine' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap      { $Roots }
            Mock Get-CommandSourcePath  { 'C:\ProgramData\scoop\shims\rclone.exe' }
            Mock Uninstall-ScoopPackage { @{ State = 'Uninstalled'; Reason = $null } }
            Mock Install-WingetPackage  { @{ State = 'Installed'; Reason = $null } }
            Mock Test-PackageInstalled  { $true }
            Mock Update-PathFromRegistry { }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Uninstall-ScoopPackage -Times 1 -Exactly
            Should -Invoke Install-WingetPackage  -Times 1 -Exactly
            $r.Status | Should -Be 'Installed'
            $r.Reason | Should -Match 'Migrated from scoop'
        }
    }

    It 'hands the predecessor engine its own Id, not the new one' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap      { $Roots }
            Mock Get-CommandSourcePath  { 'C:\ProgramData\scoop\shims\rclone.exe' }
            Mock Install-WingetPackage  { @{ State = 'Installed'; Reason = $null } }
            Mock Test-PackageInstalled  { $true }
            Mock Update-PathFromRegistry { }
            Mock Uninstall-ScoopPackage { @{ State = 'Uninstalled'; Reason = $null } } `
                -ParameterFilter { $Package.Id -eq 'main/rclone' -and $Package.Installer -eq 'scoop' }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $null = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Uninstall-ScoopPackage -Times 1 -Exactly
        }
    }

    It 'fails the package rather than stacking a duplicate when the removal fails' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap      { $Roots }
            Mock Get-CommandSourcePath  { 'C:\ProgramData\scoop\shims\rclone.exe' }
            Mock Uninstall-ScoopPackage { @{ State = 'Failed'; Reason = 'scoop uninstall exited with 1' } }
            Mock Install-WingetPackage  { @{ State = 'Installed'; Reason = $null } }
            Mock Test-PackageInstalled  { $true }
            Mock Update-PathFromRegistry { }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion -ErrorAction SilentlyContinue

            Should -Invoke Install-WingetPackage -Times 0 -Exactly
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'scoop uninstall exited with 1'
        }
    }

    It 'previews the migration under -WhatIf without removing anything' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap      { $Roots }
            Mock Get-CommandSourcePath  { 'C:\ProgramData\scoop\shims\rclone.exe' }
            Mock Uninstall-ScoopPackage { @{ State = 'Uninstalled'; Reason = '(WhatIf)' } }
            Mock Install-WingetPackage  { @{ State = 'Installed'; Reason = '(WhatIf)' } }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion -DryRun

            # The predecessor driver is still reached so the preview prints the
            # real command, but it must be reached in WhatIf mode.
            Should -Invoke Uninstall-ScoopPackage -Times 1 -Exactly -ParameterFilter { $WhatIf }
            $r.Status | Should -Be 'Installed'
        }
    }
}

Describe 'The bare-manifest dispatch path is gated too' -Tag 'Light', 'Module' {
    # Install-Package's path (c) runs `scoop install <manifest>` directly and
    # never reaches Invoke-PackageInstall, so it needs its own gate: reaching a
    # package by its MANIFEST name rather than its Package.Name would otherwise
    # walk straight past the driver's gate.

    BeforeAll {
        $script:bucketDir = Join-Path ([System.IO.Path]::GetTempPath()) "em464-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Path $script:bucketDir -Force | Out-Null

        # A bucket-owned manifest, plus a bundle whose [Package] links to it by
        # Id -- the exact shape of 'Claude Code CLI' -> ai/ClaudeCode.json.
        '{ "version": "1.00.000", "installer": { "script": ["$null"] } }' |
            Set-Content -LiteralPath (Join-Path $script:bucketDir 'WidgetCli.json') -Encoding utf8
        '{ "version": "1.00.000", "installer": { "script": ["$null"] } }' |
            Set-Content -LiteralPath (Join-Path $script:bucketDir 'OldWidget.json') -Encoding utf8
    }

    AfterAll {
        if ($script:bucketDir -and (Test-Path $script:bucketDir)) {
            Remove-Item -LiteralPath $script:bucketDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a manifest whose declaring package is shadowed by another engine' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ BucketDir = $script:bucketDir } {
            param($BucketDir)
            Mock Get-EngineRootMap     { @{ scoop = @('C:\ProgramData\scoop'); winget = @('C:\Program Files\WinGet') } }
            Mock Get-CommandSourcePath { 'C:\Program Files\WinGet\Links\widget.exe' }
            Mock Invoke-ScoopCommand   { $global:LASTEXITCODE = 0 }
            Mock Get-BundlePackages {
                @([pscustomobject]@{
                        Bundle     = 'T'
                        BundlePath = (Join-Path $BucketDir 'T.ps1')
                        Packages   = @([pscustomobject]@{
                                Name = 'Widget CLI'; Installer = 'scoop'; Id = 'MarkMichaelis/WidgetCli'
                                CliCommands = @('widget'); Completion = 'native'
                                PreviousInstaller = ''; PreviousId = ''
                            })
                    })
            }

            $r = Install-Package -Name 'WidgetCli' -BucketPath $BucketDir -SkipCompletion -ErrorAction SilentlyContinue

            Should -Invoke Invoke-ScoopCommand -Times 0 -Exactly
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'Widget CLI'
            $r.Reason | Should -Match ([regex]::Escape('C:\Program Files\WinGet\Links\widget.exe'))
        }
    }

    It 'refuses a manifest that a declaration marks as the superseded install' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ BucketDir = $script:bucketDir } {
            param($BucketDir)
            # Nothing on PATH at all, so only the PreviousId link can catch
            # this -- and it must, because installing the manifest is what
            # re-creates the copy the migration removed.
            Mock Get-EngineRootMap     { @{ scoop = @('C:\ProgramData\scoop'); winget = @('C:\Program Files\WinGet') } }
            Mock Get-CommandSourcePath { $null }
            Mock Invoke-ScoopCommand   { $global:LASTEXITCODE = 0 }
            Mock Get-BundlePackages {
                @([pscustomobject]@{
                        Bundle     = 'T'
                        BundlePath = (Join-Path $BucketDir 'T.ps1')
                        Packages   = @([pscustomobject]@{
                                Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget'
                                CliCommands = @('widget'); Completion = 'native'
                                PreviousInstaller = 'scoop'; PreviousId = 'MarkMichaelis/OldWidget'
                            })
                    })
            }

            $r = Install-Package -Name 'OldWidget' -BucketPath $BucketDir -SkipCompletion -ErrorAction SilentlyContinue

            Should -Invoke Invoke-ScoopCommand -Times 0 -Exactly
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'superseded'
            $r.Reason | Should -Match "Install-Package -Name 'Widget'"
        }
    }

    It 'still installs a manifest no declaration links to' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ BucketDir = $script:bucketDir } {
            param($BucketDir)
            Mock Get-EngineRootMap     { @{ scoop = @('C:\ProgramData\scoop') } }
            Mock Get-CommandSourcePath { 'C:\ProgramData\scoop\shims\widget.exe' }
            Mock Invoke-ScoopCommand   { $global:LASTEXITCODE = 0 }
            Mock Get-BundlePackages    { @() }

            $null = Install-Package -Name 'WidgetCli' -BucketPath $BucketDir -SkipCompletion -ErrorAction SilentlyContinue

            Should -Invoke Invoke-ScoopCommand -Times 1 -Exactly
        }
    }
}

Describe 'Update refuses to upgrade the copy that is not running' -Tag 'Light', 'Module' {

    BeforeAll {
        $script:roots = @{
            scoop  = @('C:\ProgramData\scoop')
            winget = @('C:\Program Files\WinGet')
        }
    }

    It 'does not report a shadowed package as current' {
        # The worst symptom in #464: the engine upgrade moves the winget copy
        # while the scoop copy keeps answering on PATH, so the machine reads as
        # up to date while running a stale binary.
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap     { $Roots }
            Mock Get-CommandSourcePath { 'C:\ProgramData\scoop\shims\rclone.exe' }
            Mock Update-WingetPackage  { @{ State = 'AlreadyLatest'; Reason = 'no applicable upgrade' } }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageUpdate -Packages @($pkg) -Bundle 'T' -SkipCompletion -ErrorAction SilentlyContinue

            Should -Invoke Update-WingetPackage -Times 0 -Exactly
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'scoop uninstall -g rclone'
        }
    }

    It 'points a declared migration at Install-Package, which can complete it' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap     { $Roots }
            Mock Get-CommandSourcePath { 'C:\ProgramData\scoop\shims\rclone.exe' }
            Mock Update-WingetPackage  { @{ State = 'AlreadyLatest'; Reason = 'no applicable upgrade' } }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageUpdate -Packages @($pkg) -Bundle 'T' -SkipCompletion -ErrorAction SilentlyContinue

            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'Install-Package'
        }
    }

    It 'upgrades normally when the declared engine owns the CLI' {
        InModuleScope MarkMichaelis.ScoopBucket -Parameters @{ Roots = $script:roots } {
            param($Roots)
            Mock Get-EngineRootMap     { $Roots }
            Mock Get-CommandSourcePath { 'C:\Program Files\WinGet\Links\rclone.exe' }
            Mock Update-WingetPackage  { @{ State = 'Updated'; Reason = $null } }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                CliCommands = @('rclone'); Completion = 'native'
                NativeCommandScript = { rclone completion powershell }
                ExpectedCompletions = @{ rclone = @('config') }
            }
            $r = Invoke-PackageUpdate -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Update-WingetPackage -Times 1 -Exactly
            $r.Status | Should -Be 'Updated'
        }
    }
}

Describe 'Uninstall removes the declared predecessor too' -Tag 'Light', 'Module' {

    It 'does not orphan the previous engine''s copy' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Uninstall-WingetPackage { @{ State = 'Uninstalled'; Reason = $null } }
            Mock Uninstall-ScoopPackage  { @{ State = 'Uninstalled'; Reason = $null } }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
            }
            $r = Invoke-PackageUninstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Uninstall-WingetPackage -Times 1 -Exactly
            Should -Invoke Uninstall-ScoopPackage  -Times 1 -Exactly
            $r.Status | Should -Be 'Uninstalled'
        }
    }

    It 'does not let a successful predecessor removal mask a failed primary' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Uninstall-WingetPackage { @{ State = 'Failed'; Reason = 'winget uninstall exited with 1' } }
            Mock Uninstall-ScoopPackage  { @{ State = 'Uninstalled'; Reason = $null } }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
            }
            $r = Invoke-PackageUninstall -Packages @($pkg) -Bundle 'T' -SkipCompletion -ErrorAction SilentlyContinue

            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'winget uninstall exited with 1'
        }
    }

    It 'still reports Uninstalled when only the predecessor was present' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Uninstall-WingetPackage { @{ State = 'NotInstalled'; Reason = 'winget list returned 1.' } }
            Mock Uninstall-ScoopPackage  { @{ State = 'Uninstalled'; Reason = $null } }

            $pkg = [Package]@{
                Name = 'rclone'; Installer = 'winget'; Id = 'Rclone.Rclone'
                PreviousInstaller = 'scoop'; PreviousId = 'main/rclone'
            }
            $r = Invoke-PackageUninstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            $r.Status | Should -Be 'Uninstalled'
            $r.Reason | Should -Match 'predecessor'
        }
    }
}

Describe 'Uninstall-ScoopPackage honors install scope' -Tag 'Light', 'Module' {

    It 'passes -g for a global install, which plain uninstall cannot remove' {
        # scoop keeps global and user installs in separate roots: `scoop
        # uninstall <app>` against a -g install reports "isn't installed" and
        # exits non-zero, so the migration above would leave BOTH copies.
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Invoke-ScoopCommand { $global:LASTEXITCODE = 0 }
            Mock scoop { 'rclone 1.0 main' }

            $pkg = [Package]@{ Name = 'rclone'; Installer = 'scoop'; Id = 'main/rclone'; Scope = 'global' }
            $null = Uninstall-ScoopPackage -Package $pkg

            Should -Invoke Invoke-ScoopCommand -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '-g' -and $ArgumentList -contains 'rclone'
            }
        }
    }

    It 'omits -g for a user-scope install' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Invoke-ScoopCommand { $global:LASTEXITCODE = 0 }
            Mock scoop { 'rclone 1.0 main' }

            $pkg = [Package]@{ Name = 'rclone'; Installer = 'scoop'; Id = 'main/rclone'; Scope = 'user' }
            $null = Uninstall-ScoopPackage -Package $pkg

            Should -Invoke Invoke-ScoopCommand -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -notcontains '-g'
            }
        }
    }
}

Describe 'PreviousInstaller declaration validity' -Tag 'Light', 'Module' {

    It 'rejects PreviousInstaller without PreviousId' {
        $pkg = [Package]@{ Name = 'X'; Installer = 'winget'; Id = 'V.X'; PreviousInstaller = 'scoop' }
        $pkg.GetValidationError() | Should -Match 'PreviousId'
    }

    It 'rejects PreviousId without PreviousInstaller' {
        $pkg = [Package]@{ Name = 'X'; Installer = 'winget'; Id = 'V.X'; PreviousId = 'main/x' }
        $pkg.GetValidationError() | Should -Match 'PreviousInstaller'
    }

    It 'rejects a predecessor that is the same engine as the current one' {
        $pkg = [Package]@{ Name = 'X'; Installer = 'winget'; Id = 'V.X'
                           PreviousInstaller = 'winget'; PreviousId = 'V.XOld' }
        $pkg.GetValidationError() | Should -Match 'differ'
    }

    It 'rejects a predecessor on a custom installer, which cannot act on it' {
        $pkg = [Package]@{ Name = 'X'; CustomInstallScript = { }
                           PreviousInstaller = 'scoop'; PreviousId = 'main/x' }
        $pkg.GetValidationError() | Should -Match "not supported when Installer='custom'"
    }

    It 'accepts a well-formed cross-engine predecessor' {
        $pkg = [Package]@{ Name = 'X'; Installer = 'winget'; Id = 'V.X'
                           PreviousInstaller = 'scoop'; PreviousId = 'main/x' }
        $pkg.GetValidationError() | Should -BeNullOrEmpty
    }
}

Describe 'Cross-engine migration is documented' -Tag 'Light', 'Module' {

    It 'documents it beside the engine-preference list in the README' {
        $readme = Get-Content -Raw -LiteralPath (Join-Path $script:repoRoot 'README.md')
        $readme | Should -Match 'Changing a package.s installation engine'
        $readme | Should -Match 'PreviousInstaller'
    }
}
