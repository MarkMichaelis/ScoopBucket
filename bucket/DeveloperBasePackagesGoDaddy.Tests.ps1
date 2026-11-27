#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the 'GoDaddy CLI' (gddy) entry in
    DeveloperBasePackages (#527, supersedes the unverified entry from #526).

.DESCRIPTION
    Light tests run the harvested package's own CustomInstallScript and
    CustomUninstallScript against a fake upstream installer, with
    LOCALAPPDATA redirected to TestDrive, so nothing is downloaded and the
    real installation is never touched. They pin the decisions that #526 got
    wrong: the upstream installer must not add a PATH entry (a scoop shim
    exposes gddy instead), a re-run must not reinstall, and completion comes
    from the binary (`gddy completion powershell`), not a hand-kept list.

    Install-tagged tests run the real package on this machine (local only):
    install twice, the CLI on PATH, the DNS command surface, completion, and
    the update path.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:Declared = @(Get-Package -BucketPath $PSScriptRoot | Where-Object Name -EQ 'GoDaddy CLI')
    $script:Package = & (Get-Module MarkMichaelis.ScoopBucket) {
        param($bundle) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -EQ 'GoDaddy CLI'
    } (Join-Path $PSScriptRoot 'DeveloperBasePackages.ps1')

    # Stand-in for GoDaddy's install.ps1: same parameters, records how it was
    # called, and drops a placeholder gddy.exe where the real one would go.
    $script:FakeInstaller = @'
param([string]$Prefix, [string]$Version, [switch]$SkipPathUpdate)
New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Prefix 'gddy.exe') -Value 'placeholder'
$global:__GddyInstallerCalls += , @{ Prefix = $Prefix; SkipPathUpdate = [bool]$SkipPathUpdate }
'@
}

Describe 'DeveloperBasePackages: GoDaddy CLI declaration (#527)' -Tag 'Light', 'Bundle', 'GoDaddy' {

    It 'is declared exactly once, in DeveloperBasePackages, as a user-scope custom install of gddy' {
        $script:Declared.Count | Should -Be 1
        $script:Declared[0].Bundle | Should -Be 'DeveloperBasePackages'
        $script:Declared[0].Installer | Should -Be 'custom'
        $script:Declared[0].Scope | Should -Be 'user'
        @($script:Declared[0].CliCommands) | Should -Be @('gddy')
    }

    It 'takes completion from the binary itself (gddy completion powershell)' {
        $script:Declared[0].Completion | Should -Be 'native'
        $script:Declared[0].NativeCompletionKind | Should -Be 'native'
        $script:Package.NativeCommandScript.ToString().Trim() | Should -Be 'gddy completion powershell'
        foreach ($sub in 'auth', 'dns', 'domain', 'update') { $script:Declared[0].ExpectedCompletions['gddy'] | Should -Contain $sub }
    }

    It 'declares install, verify, update, and uninstall hooks' {
        $script:Declared[0].HasCustomInstallScript | Should -BeTrue
        $script:Declared[0].HasVerifyScript | Should -BeTrue
        $script:Declared[0].HasPostUpdateScript | Should -BeTrue
        $script:Package.CustomUninstallScript | Should -Not -BeNullOrEmpty
        $script:Package.PostUpdateScript.ToString() | Should -Match 'update apply'
    }
}

Describe 'DeveloperBasePackages: GoDaddy CLI install and uninstall behavior (#527)' -Tag 'Light', 'Bundle', 'GoDaddy' {

    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $script:SavedScoop = $env:SCOOP
        $script:SavedAppData = $env:APPDATA
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA = Join-Path $root 'LocalAppData'
        $env:SCOOP = Join-Path $root 'scoop'
        $env:APPDATA = Join-Path $root 'AppData'
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA, (Join-Path $env:SCOOP 'shims') -Force | Out-Null
        $script:Exe = Join-Path $env:LOCALAPPDATA 'Programs\gddy\gddy.exe'
        $script:ShimFile = Join-Path $env:SCOOP 'shims\gddy.shim'
        $global:__GddyInstallerCalls = @()
        $global:__ScoopCalls = @()
        $script:UserPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')

        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-RestMethod { $script:FakeInstaller }
        # A fake scoop that keeps real .shim files, so tests see the end state.
        Mock -ModuleName MarkMichaelis.ScoopBucket scoop {
            $global:__ScoopCalls += , ($args -join ' ')
            $shim = Join-Path $env:SCOOP "shims\$($args[2]).shim"
            if ($args[1] -eq 'add') { Set-Content -LiteralPath $shim -Value "path = `"$($args[3])`"" }
            if ($args[1] -eq 'rm') { Remove-Item -LiteralPath $shim -ErrorAction SilentlyContinue }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command -ParameterFilter { $Name -eq 'gddy' } { [pscustomobject]@{ Source = 'shim\gddy.exe' } }
    }

    BeforeAll {
        # Pester can only Mock a command that exists. CI machines have no gddy,
        # so give the ConfigScript tests a placeholder to mock there.
        $script:DefinedGddyStub = -not (Get-Command gddy -ErrorAction SilentlyContinue)
        if ($script:DefinedGddyStub) { function global:gddy { } }
    }

    AfterAll {
        if ($script:DefinedGddyStub) { Remove-Item -Path Function:\gddy -ErrorAction SilentlyContinue }
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:SCOOP = $script:SavedScoop
        $env:APPDATA = $script:SavedAppData
        Remove-Variable -Name __GddyInstallerCalls, __ScoopCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'runs GoDaddy''s official installer into %LOCALAPPDATA%\Programs\gddy with -SkipPathUpdate' {
        & $script:Package.CustomInstallScript $script:Package
        Should -Invoke Invoke-RestMethod -ModuleName MarkMichaelis.ScoopBucket -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/godaddy/cli/releases/latest/download/install.ps1'
        }
        $global:__GddyInstallerCalls.Count | Should -Be 1
        $global:__GddyInstallerCalls[0].SkipPathUpdate | Should -BeTrue -Because 'the bucket exposes gddy through a shim, not a PATH entry'
        $global:__GddyInstallerCalls[0].Prefix | Should -Be (Split-Path $script:Exe)
        $script:Exe | Should -Exist
        [Environment]::GetEnvironmentVariable('Path', 'User') | Should -Be $script:UserPathBefore
    }

    It 'exposes gddy through a scoop shim pointing at the installed binary' {
        & $script:Package.CustomInstallScript $script:Package
        $global:__ScoopCalls | Should -Be @("shim add gddy $script:Exe")
        Get-Content -LiteralPath $script:ShimFile -Raw | Should -Match ([regex]::Escape($script:Exe))
    }

    It 'changes nothing on a re-run: no download, no reinstall, no shim churn' {
        & $script:Package.CustomInstallScript $script:Package
        & $script:Package.CustomInstallScript $script:Package
        Should -Invoke Invoke-RestMethod -ModuleName MarkMichaelis.ScoopBucket -Times 1 -Exactly
        $global:__GddyInstallerCalls.Count | Should -Be 1
        $global:__ScoopCalls | Should -Be @("shim add gddy $script:Exe") -Because 'the second run finds the shim already pointing at gddy.exe'
    }

    It 'repoints a shim that targets some other gddy.exe' {
        Set-Content -LiteralPath $script:ShimFile -Value 'path = "C:\old\gddy.exe"'
        & $script:Package.CustomInstallScript $script:Package
        $global:__ScoopCalls | Should -Be @('shim rm gddy', "shim add gddy $script:Exe")
    }

    It 'fails loudly when the installer does not produce gddy.exe' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-RestMethod { 'param($Prefix, [switch]$SkipPathUpdate) # does nothing' }
        { & $script:Package.CustomInstallScript $script:Package } | Should -Throw '*did not create*'
    }

    It 'points gddy at its file credential store when the setting is the default and holds no sign-in' {
        $global:__GddyCalls = @()
        Mock -ModuleName MarkMichaelis.ScoopBucket gddy {
            $global:__GddyCalls += , ($args -join ' ')
            if ($args[0] -eq 'config' -and $args[1] -eq 'get') { '{"data":{"key":"credentials.store","value":"auto","source":"default"}}' }
            if ($args[0] -eq 'auth' -and $args[1] -eq 'status') { '{"data":[{"env":"prod","expired":true,"refreshable":false}]}' }
            $global:LASTEXITCODE = 0
        }
        try {
            & $script:Package.ConfigScript $script:Package 6>$null
            $global:__GddyCalls | Should -Contain 'config set credentials.store file --output json'
        }
        finally { Remove-Variable -Name __GddyCalls -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'keeps the default store when it already holds a working sign-in (never strands it)' {
        $global:__GddyCalls = @()
        Mock -ModuleName MarkMichaelis.ScoopBucket gddy {
            $global:__GddyCalls += , ($args -join ' ')
            if ($args[0] -eq 'config' -and $args[1] -eq 'get') { '{"data":{"key":"credentials.store","value":"auto","source":"default"}}' }
            if ($args[0] -eq 'auth' -and $args[1] -eq 'status') { '{"data":[{"env":"prod","expired":false,"refreshable":true}]}' }
            $global:LASTEXITCODE = 0
        }
        try {
            & $script:Package.ConfigScript $script:Package 6>$null
            @($global:__GddyCalls | Where-Object { $_ -like 'config set*' }) | Should -BeNullOrEmpty
        }
        finally { Remove-Variable -Name __GddyCalls -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'leaves a credential store the user chose alone, and is a no-op when gddy is absent' {
        $global:__GddyCalls = @()
        Mock -ModuleName MarkMichaelis.ScoopBucket gddy {
            $global:__GddyCalls += , ($args -join ' ')
            if ($args[0] -eq 'config' -and $args[1] -eq 'get') { '{"data":{"key":"credentials.store","value":"keyring","source":"file"}}' }
            $global:LASTEXITCODE = 0
        }
        try {
            & $script:Package.ConfigScript $script:Package 6>$null
            @($global:__GddyCalls | Where-Object { $_ -like 'config set*' }) | Should -BeNullOrEmpty
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-Command -ParameterFilter { $Name -eq 'gddy' } { $null }
            $global:__GddyCalls = @()
            & $script:Package.ConfigScript $script:Package 6>$null
            $global:__GddyCalls | Should -BeNullOrEmpty
        }
        finally { Remove-Variable -Name __GddyCalls -Scope Global -ErrorAction SilentlyContinue }
    }

    Context 'token folder permissions' {
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket gddy {
                if ($args[0] -eq 'config' -and $args[1] -eq 'get') { '{"data":{"key":"credentials.store","value":"file","source":"config"}}' }
                $global:LASTEXITCODE = 0
            }
            $script:CredDir = Join-Path $env:APPDATA 'gddy\credentials'
            $script:Me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }

        It 'restricts the token folder to the user and SYSTEM, inheritably, including an existing token file' {
            New-Item -ItemType Directory -Path $script:CredDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:CredDir 'godaddy-prod.json') -Value '{}'
            & $script:Package.ConfigScript $script:Package 6>$null
            $acl = Get-Acl -LiteralPath $script:CredDir
            $acl.AreAccessRulesProtected | Should -BeTrue -Because 'the folder must not inherit the profile''s ACL'
            $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value }) | Sort-Object
            $sids | Should -Be (@($script:Me, 'S-1-5-18') | Sort-Object)
            $fileSids = @((Get-Acl -LiteralPath (Join-Path $script:CredDir 'godaddy-prod.json')).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value }) | Sort-Object -Unique
            $fileSids | Should -Be (@($script:Me, 'S-1-5-18') | Sort-Object) -Because 'the existing token file must pick up the folder''s restriction'
        }

        It 'creates the folder locked down before any sign-in exists' {
            & $script:Package.ConfigScript $script:Package 6>$null
            (Get-Acl -LiteralPath $script:CredDir).AreAccessRulesProtected | Should -BeTrue
        }

        It 'changes nothing on a re-run once the folder is private' {
            & $script:Package.ConfigScript $script:Package 6>$null
            Mock -ModuleName MarkMichaelis.ScoopBucket Set-Acl { }
            & $script:Package.ConfigScript $script:Package 6>$null
            Should -Invoke Set-Acl -ModuleName MarkMichaelis.ScoopBucket -Times 0 -Exactly
        }
    }

    It 'removes only the gddy folder from the user PATH, keeping %VARS% and REG_EXPAND_SZ' {
        $gddyDir = Split-Path $script:Exe
        $global:__RawPath = "%USERPROFILE%\bin;$gddyDir;C:\Tools"
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Item -ParameterFilter { $LiteralPath -eq 'HKCU:\Environment' } {
            $o = [pscustomobject]@{}
            $o | Add-Member -MemberType ScriptMethod -Name GetValue -Value { param($n, $d, $opt) $global:__RawPath }
            $o | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value { param($n) [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $o
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Set-ItemProperty { }
        try {
            & $script:Package.CustomUninstallScript $script:Package
            Should -Invoke Set-ItemProperty -ModuleName MarkMichaelis.ScoopBucket -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq 'HKCU:\Environment' -and $Name -eq 'Path' -and $Value -eq '%USERPROFILE%\bin;C:\Tools' -and
                $Type -eq [Microsoft.Win32.RegistryValueKind]::ExpandString
            }
        }
        finally { Remove-Variable -Name __RawPath -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'leaves the user PATH alone when it has no gddy entry' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Item -ParameterFilter { $LiteralPath -eq 'HKCU:\Environment' } {
            $o = [pscustomobject]@{}
            $o | Add-Member -MemberType ScriptMethod -Name GetValue -Value { param($n, $d, $opt) '%USERPROFILE%\bin;C:\Tools' }
            $o | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value { param($n) [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $o
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Set-ItemProperty { }
        & $script:Package.CustomUninstallScript $script:Package
        Should -Invoke Set-ItemProperty -ModuleName MarkMichaelis.ScoopBucket -Times 0 -Exactly
    }

    It 'removes the binary folder and the shim on uninstall, and is safe to repeat' {
        & $script:Package.CustomInstallScript $script:Package
        & $script:Package.CustomUninstallScript $script:Package
        Split-Path $script:Exe | Should -Not -Exist
        $global:__ScoopCalls | Should -Contain 'shim rm gddy'
        { & $script:Package.CustomUninstallScript $script:Package } | Should -Not -Throw
        [Environment]::GetEnvironmentVariable('Path', 'User') | Should -Be $script:UserPathBefore
    }
}

Describe 'DeveloperBasePackages: GoDaddy CLI on this machine (#527)' -Tag 'Install', 'GoDaddy' {
    # Real installs and a real update check; never signs in and never touches
    # DNS. Run locally: .\bucket\Invoke-Tests.ps1 -Pattern GoDaddy -Tag Install

    BeforeAll {
        $script:GddyExe = Join-Path $env:LOCALAPPDATA 'Programs\gddy\gddy.exe'
    }

    It 'installs, and a second install of the same package succeeds without reinstalling' {
        $first = @(Install-Package -Name 'GoDaddy CLI' -BucketPath $PSScriptRoot -SkipCompletion 6>$null)
        $hashAfterFirst = (Get-FileHash $script:GddyExe).Hash
        $second = @(Install-Package -Name 'GoDaddy CLI' -BucketPath $PSScriptRoot -SkipCompletion 6>$null)
        @($first + $second | Where-Object { $_.State -eq 'Failed' }) | Should -BeNullOrEmpty
        (Get-FileHash $script:GddyExe).Hash | Should -Be $hashAfterFirst
        @(& $script:Package.VerifyScript) | Should -Be $true
    }

    It 'puts gddy on PATH as a shim and reports a version' {
        $cmd = Get-Command gddy -CommandType Application -ErrorAction Stop
        $cmd.Source | Should -Not -Be $script:GddyExe -Because 'gddy is reached through a scoop shim, not a PATH entry'
        "$(& gddy --version)" | Should -Match '^gddy version \d+\.\d+\.\d+'
        & gddy --help | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'supports the DNS commands the MCP server relies on' {
        $tree = (& gddy tree --output json | Out-String | ConvertFrom-Json -Depth 50)
        $json = $tree | ConvertTo-Json -Depth 50 -Compress
        foreach ($verb in 'list', 'add', 'set', 'delete') { $json | Should -Match "`"$verb`"" }
        & gddy dns list --help | Out-String | Should -Match '--fields'
        & gddy api search dns --output json | Out-String | Should -Match 'deleteDNSRecord'
    }

    It 'emits a PowerShell completer from the binary' {
        $completer = & gddy completion powershell | Out-String
        $completer | Should -Match "Register-ArgumentCompleter -Native -CommandName 'gddy'"
        foreach ($sub in 'auth', 'dns', 'domain', 'update') { $completer | Should -Match "'$sub'" }
    }

    It 'can check for updates with the same command the update hook uses' {
        $check = & gddy update check --output json | Out-String | ConvertFrom-Json
        $check.data.currentVersion | Should -Match '^\d+\.\d+\.\d+'
        $null -ne $check.data.updateAvailable | Should -BeTrue
    }
}
