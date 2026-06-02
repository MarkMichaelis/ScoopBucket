#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester regression test for #291: Install-Package dispatched through the
# bare-manifest fallback (path c) must register the tab-completions that a
# declarative [Package] declares for that same manifest. The mapping key is
# [Package].Id with the owner prefix stripped (e.g. 'Owner/VsTest' -> 'VsTest'),
# matched case-insensitively against the requested manifest base name.
#
# Before the fix, `Install-Package -Name 'VsTest'` resolved a bare
# '<name>.json' manifest, ran `scoop install`, and registered NOTHING -- even
# though a bundle declared the same manifest with CliCommands/Completion. After
# the fix it registers the declared completers the same way the Package.Name
# path already does.

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    Import-Module $script:psd1 -Force

    # Throwaway bucket: one declarative bundle that declares a package whose
    # Id ('Owner/VsTest') maps to a sibling 'VsTest.json' manifest, plus a
    # truly metadata-less 'LonePkg.json' manifest with no declaring [Package].
    $script:tmpBucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-manifest-comp-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:tmpBucket | Out-Null

    $bundleText = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Visual Studio Test'
        Installer   = 'scoop'
        Id          = 'Owner/VsTest'
        CliCommands = @('devenv')
        Completion  = 'auto'
        ExpectedCompletions = @{ devenv = @('/Build','/Run') }
        NativeCommandScript = { 'Register-ArgumentCompleter -Native -CommandName devenv -ScriptBlock { }' }
    }
    [Package]@{
        Name        = 'Winget Declared'
        Installer   = 'winget'
        Id          = 'Vendor/WingetOnly'
        CliCommands = @('wgtool')
        Completion  = 'auto'
        ExpectedCompletions = @{ wgtool = @('--x') }
        NativeCommandScript = { 'Register-ArgumentCompleter -Native -CommandName wgtool -ScriptBlock { }' }
    }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'VsTestBundle'
"@
    Set-Content -Path (Join-Path $script:tmpBucket 'VsTestBundle.ps1') -Value $bundleText -Encoding UTF8

    # Sibling scoop manifest the bundle's package declares via Id. Its base
    # name 'VsTest' != the Package.Name 'Visual Studio Test', so Install-Package
    # routes it through path (c), not path (a).
    $vsManifest = @{
        '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
        version   = '1.00.000'
        url       = @('https://example.invalid/vstest')
        installer = @{ script = @('Write-Host vstest install') }
    }
    Set-Content -LiteralPath (Join-Path $script:tmpBucket 'VsTest.json') `
        -Value ($vsManifest | ConvertTo-Json -Depth 4) -Encoding UTF8

    # A truly metadata-less manifest: no [Package] declares it.
    $loneManifest = @{
        '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
        version   = '1.00.000'
        url       = @('https://example.invalid/lone')
        installer = @{ script = @('Write-Host lone install') }
    }
    Set-Content -LiteralPath (Join-Path $script:tmpBucket 'LonePkg.json') `
        -Value ($loneManifest | ConvertTo-Json -Depth 4) -Encoding UTF8

    # A manifest whose Id base name matches a declarative [Package] that is
    # NOT a scoop package (Installer='winget'). The scoop-manifest dispatch
    # must not borrow that package's completion -- the Id match would be
    # coincidental.
    $wingetManifest = @{
        '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
        version   = '1.00.000'
        url       = @('https://example.invalid/wingetonly')
        installer = @{ script = @('Write-Host wingetonly install') }
    }
    Set-Content -LiteralPath (Join-Path $script:tmpBucket 'WingetOnly.json') `
        -Value ($wingetManifest | ConvertTo-Json -Depth 4) -Encoding UTF8
}

AfterAll {
    if ($script:tmpBucket -and (Test-Path $script:tmpBucket)) {
        Remove-Item -LiteralPath $script:tmpBucket -Recurse -Force -ErrorAction Ignore
    }
}

Describe 'Install-Package bare-manifest completion (#291)' -Tag 'Light', 'Module' {

    BeforeEach {
        # Never actually shell out to scoop; the dispatch path runs
        # `& scoop install <name>` from module scope. Report success so the
        # post-install completion registration runs.
        Mock -ModuleName MarkMichaelis.ScoopBucket scoop { $global:LASTEXITCODE = 0 }
        # Capture (and suppress) the in-session + persistent registration so
        # the test asserts INVOCATION rather than depending on the CLI being
        # present or on $PROFILE.AllUsersAllHosts being writable.
        Mock -ModuleName MarkMichaelis.ScoopBucket Import-PackageCompletion { @() }
        Mock -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion { @{ Source = 'Native'; Action = 'Registered'; Reason = $null } }
    }

    It 'registers the declared devenv completer when installing by the manifest name' {
        Install-Package -Name 'VsTest' -BucketPath $script:tmpBucket | Out-Null

        # In-session import is invoked with the declaring package (devenv CLI).
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Import-PackageCompletion -Times 1 -Exactly -ParameterFilter {
            $Package -and (@($Package).CliCommands -contains 'devenv')
        }
        # Persistent sentinel-block registration is invoked for devenv too,
        # consistent with how the Package.Name path (a) registers completers.
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 1 -Exactly -ParameterFilter {
            $Cli -eq 'devenv'
        }
        # The manifest still got installed via scoop.
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -ParameterFilter {
            ($args -contains 'install') -and ($args -contains 'VsTest')
        }
    }

    It 'does NOT register completion for a metadata-less manifest, but still installs it' {
        Install-Package -Name 'LonePkg' -BucketPath $script:tmpBucket | Out-Null

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Import-PackageCompletion -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -ParameterFilter {
            ($args -contains 'install') -and ($args -contains 'LonePkg')
        }
    }

    It 'skips completion registration entirely under -SkipCompletion' {
        Install-Package -Name 'VsTest' -SkipCompletion -BucketPath $script:tmpBucket | Out-Null

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Import-PackageCompletion -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 0 -Exactly
    }

    It 'does NOT register completion when scoop install fails (non-zero exit)' {
        # A failed install must not leave behind completers for a CLI that was
        # never actually installed.
        Mock -ModuleName MarkMichaelis.ScoopBucket scoop { $global:LASTEXITCODE = 1 }

        Install-Package -Name 'VsTest' -BucketPath $script:tmpBucket | Out-Null

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Import-PackageCompletion -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 0 -Exactly
        # The install was still attempted.
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -ParameterFilter {
            ($args -contains 'install') -and ($args -contains 'VsTest')
        }
    }

    It 'does NOT borrow completion from a non-scoop ([winget]) package whose Id base coincidentally matches' {
        Install-Package -Name 'WingetOnly' -BucketPath $script:tmpBucket | Out-Null

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Import-PackageCompletion -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -ParameterFilter {
            ($args -contains 'install') -and ($args -contains 'WingetOnly')
        }
    }

    It 'honors -DryRun uniformly: neither installs the manifest nor registers completion' {
        Install-Package -Name 'VsTest' -DryRun -BucketPath $script:tmpBucket | Out-Null

        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Import-PackageCompletion -Times 0 -Exactly
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Register-PackageCompletion -Times 0 -Exactly
    }
}
