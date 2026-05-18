# ----------------------------------------------------------------------------
# Issue #180: Register-AllCliCompletions must default to bucket-declared CLIs
# (the union of CliCommands across packages whose Completion != 'none'),
# NOT every executable on PATH. Power users opt into the legacy PATH sweep
# via -IncludeAllPath.
# ----------------------------------------------------------------------------

Describe 'Register-AllCliCompletions default scope' -Tag 'Light','BucketScope' {

    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force }
        else { Import-Module MarkMichaelis.ScoopBucket -Force }

        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("RACLI-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:profilePath = Join-Path $script:sandbox 'Profile.ps1'

        # Fake bucket inventory: two registrable CLIs, one explicitly opted out.
        $script:fakePackages = @(
            [pscustomobject]@{ Name = 'tool-a'; CliCommands = @('aaa','aab'); Completion = 'auto' }
            [pscustomobject]@{ Name = 'tool-b'; CliCommands = @('bbb');       Completion = 'native' }
            [pscustomobject]@{ Name = 'tool-c'; CliCommands = @('ccc');       Completion = 'none' }
        )
    }

    AfterAll {
        if (Test-Path $script:sandbox) {
            Remove-Item -Path $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'defaults to the union of bucket CliCommands and skips Completion=none' {
        $registered = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Package { $script:fakePackages }
        Mock -ModuleName MarkMichaelis.ScoopBucket Register-CliCompletion {
            param($Cli)
            $registered.Add($Cli)
            [pscustomobject]@{ Cli = $Cli; Source = 'Test'; Action = 'Added'; ProfilePath = $ProfilePath; Reason = $null }
        }

        Register-AllCliCompletions -ProfilePath $script:profilePath -Confirm:$false | Out-Null

        ($registered | Sort-Object) -join ',' | Should -Be 'aaa,aab,bbb'
    }

    It '-IncludeAllPath bypasses the bucket discovery (registers >0 PATH binaries)' {
        $script:invokeCount = 0
        $script:getPackageCalled = $false
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Package {
            $script:getPackageCalled = $true
            @()
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Register-CliCompletion {
            $script:invokeCount++
            [pscustomobject]@{ Cli = $Cli; Source = 'Test'; Action = 'Added'; ProfilePath = $ProfilePath; Reason = $null }
        }

        Register-AllCliCompletions -IncludeAllPath -ProfilePath $script:profilePath -Confirm:$false | Out-Null

        $script:invokeCount | Should -BeGreaterThan 0
        $script:getPackageCalled | Should -Be $false
    }

    It '-Names overrides scope and skips both bucket discovery and PATH sweep' {
        $registered = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Package {
            throw 'Get-Package must not be called when -Names is supplied'
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Register-CliCompletion {
            param($Cli)
            $registered.Add($Cli)
            [pscustomobject]@{ Cli = $Cli; Source = 'Test'; Action = 'Added'; ProfilePath = $ProfilePath; Reason = $null }
        }

        Register-AllCliCompletions -Names 'foo','bar' -ProfilePath $script:profilePath -Confirm:$false | Out-Null

        ($registered | Sort-Object) -join ',' | Should -Be 'bar,foo'
    }

    It 'warns and returns empty when bucket discovery yields no CLIs' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-Package { @() }
        Mock -ModuleName MarkMichaelis.ScoopBucket Register-CliCompletion {
            throw 'Register-CliCompletion should not be invoked when scope is empty'
        }

        $warnings = @()
        $result = Register-AllCliCompletions -ProfilePath $script:profilePath -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue
        @($result).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'no bucket-declared CLIs'
    }
}
