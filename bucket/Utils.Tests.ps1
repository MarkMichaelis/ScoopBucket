
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path).Replace('.Tests', '')
. "$PSScriptRoot\$sut"

Describe 'Test-ChocolateyPackageInstalled' {
    $mockInstalledPackageName = 'MyMockPackage'
    Mock choco.exe {
        Write-Output "Chocolatey v0.10.15"
        $installArgs = Get-InstallArgs @args
        if($installArgs.Arg1 -eq $mockInstalledPackageName) {
            Write-Output @"
chocolatey 0.10.15
$mockInstalledPackageName 1.1.2.20161210
"@
        }
        Write-Output "2 packages installed."
    } -ParameterFilter { 
        $installArgs = Get-InstallArgs @args
        return (($installArgs.Action -eq 'list'))
    }
    
    It "$mockInstalledPackageName IS installedd" {
        Test-ChocolateyPackageInstalled $mockInstalledPackageName | Should Be $true
    }
    It "$mockInstalledPackageName is NOT installedd" {
        Test-ChocolateyPackageInstalled 'NotInstalledMockPackageNAme' | Should Be $false
    }
}

Describe 'choco install' {
    $previouslyInstalledPackage = 'MyMockPackage'
    Mock choco.exe {
        $installArgs = Get-InstallArgs @args
        switch($installArgs.Action) 
        {
            'install' {
                Write-Output "Installing $($installArgs.Arg1)"
            }
            'list' {
                Write-Output "Chocolatey v0.10.15"
                if($installArgs.Arg1 -eq $previouslyInstalledPackage) {
                    Write-Output @"
chocolatey 0.10.15
$previouslyInstalledPackage 1.1.2.20161210
"@
                }
                Write-Output "2 packages installed."
            }
            Default {
                throw 'Invalid operation: Parameter filter should prevent getting here.'
            }
        }
    } -ParameterFilter { 
        $installArgs = Get-InstallArgs @args
        return (($installArgs.Action -in 'install','list'))
    }
    
    It "choco install $previouslyInstalledPackage" {
        choco install  $previouslyInstalledPackage 3>&1 | Should Be "$previouslyInstalledPackage is already installed."
    }
    It "choco install NewSamplePackage" {
        choco install NewSamplePackage | Should Be 'Installing NewSamplePackage'
    }
}

Describe "Test-ScoopPackageInstalled" {
    $mockExistingAppName = 'MyMockApp'
    $mockMissingAppName = 'MyMockMissingApp'

    Mock scoop.ps1 { 
        Write-Output @"
Installed apps matching '$mockExistingAppName':

  $mockExistingAppName 1.00.001 [...\Temp\MyMockApp.json]
  $mockExistingAppName 1.00.001 *global* [...\Temp\MyMockApp.json]
"@ } -ParameterFilter { 
        $scoopArgs = Get-InstallArgs @args
        return (($scoopArgs.Action -eq 'export'))
    }

    it "$mockExistingAppName is installed " {
        Test-ScoopPackageInstalled $mockExistingAppName | Should Be $true
    }
    it "$mockMissingAppName is NOT installed " {
        Test-ScoopPackageInstalled $mockMissingAppName | Should Be $false
    }
}

Describe 'Get-InstallArgs' {
    It 'install stuff' {
        $scoopArgs = Get-InstallArgs install stuff
        $scoopArgs.Action | Should Be 'install'
        $scoopArgs.Arg1 | Should Be 'stuff'
    }
}


Describe 'scoop search wrapper' {
    [bool]$script:firstBucket=$true
    $mockAppName = 'MyMockApp'
    Mock apps_in_bucket {
        $script:firstBucket = $false
        Write-Output $mockAppName,'Application1','Application2' 
    } -ParameterFilter { $firstBucket }
    Mock latest_version {
        '42.42.001'
    }
    #Mock Find-BucketDirectory { }
    
    It 'scoop search has -PSCustomObject option' {
        $results = scoop search $mockAppName -PSCustomObject 
        $results | Should Not Be $null
        $results.count | Should Not Be 1
        $results.GetType() | Should Be 'System.Management.Automation.PSCustomObject'
        $results.Name | Should Be $mockAppName
        $results.Bucket | Should Be (Get-LocalBucket | Select-Object -First 1)
    }
}


Describe 'Get-LocalBucket' {
    It 'Get-LocalBucket' {
        $localBuckets = Get-LocalBucket
        $localBuckets -contains 'main' | Should Be $true
        if($UserBucket) {
            $localBuckets[0] | Should Be 'MarkMichaelis'
        }
    }
}


Describe 'scoop install wrapper' {
    # [bool]$script:firstBucket=$true
    $mockAppName = 'dotnet'
    Mock scoop.ps1 { 
        Write-Output "$args" } `
-ParameterFilter { 
    $scoopArgs = Get-InstallArgs @args
    return (($scoopArgs.Action -eq 'install'))
}
    
    It 'scoop install ' {
        $results = scoop install $mockAppName
        # $fullAppName = scoop search $mockAppName -PSCustomObject | Where-Object {
        #     $_.name -match "^$mockAppName$"
        # } | ForEach-Object { 
        #     "$($_.Bucket)/$($_.name)"
        # }
        $results | Should Be "install $mockAppName"
    }
}

# ----------------------------------------------------------------------------
# Register-CliCompletion + helpers (Pester v5 style).
# ----------------------------------------------------------------------------

Describe 'Set-CompletionProfileBlock' -Tag 'Light','Completion' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Utils.ps1')
    }

    It 'appends a fresh block when none exists' {
        $r = Set-CompletionProfileBlock -Content '' -Cli 'gh' -Block 'BODY' -Force
        $r | Should -Match '# ScoopBucket:CliCompletion:gh:BEGIN v1'
        $r | Should -Match 'BODY'
        $r | Should -Match '# ScoopBucket:CliCompletion:gh:END'
    }

    It 'is idempotent under -Force' {
        $first  = Set-CompletionProfileBlock -Content ''      -Cli 'gh' -Block 'BODY' -Force
        $second = Set-CompletionProfileBlock -Content $first  -Cli 'gh' -Block 'BODY' -Force
        $second | Should -Be $first
    }

    It 'replaces an existing block when -Force is given' {
        $seeded = Set-CompletionProfileBlock -Content '' -Cli 'gh' -Block 'OLD' -Force
        $updated = Set-CompletionProfileBlock -Content $seeded -Cli 'gh' -Block 'NEW' -Force
        $updated | Should -Match 'NEW'
        $updated | Should -Not -Match 'OLD'
    }

    It 'preserves an existing block when -Force is omitted' {
        $seeded = Set-CompletionProfileBlock -Content '' -Cli 'gh' -Block 'OLD' -Force
        $kept   = Set-CompletionProfileBlock -Content $seeded -Cli 'gh' -Block 'NEW'
        $kept | Should -Be $seeded
    }

    It 'tolerates blocks containing $ and \ characters' {
        $tricky = 'if ($x -match "\d+") { Register-ArgumentCompleter -CommandName gh -ScriptBlock { $args[0] } }'
        $r = Set-CompletionProfileBlock -Content '' -Cli 'gh' -Block $tricky -Force
        $r | Should -Match ([regex]::Escape($tricky))
    }

    It 'leaves other CLIs untouched when replacing one' {
        $seeded = Set-CompletionProfileBlock -Content '' -Cli 'gh' -Block 'GH'  -Force
        $seeded = Set-CompletionProfileBlock -Content $seeded -Cli 'rg' -Block 'RG' -Force
        $updated = Set-CompletionProfileBlock -Content $seeded -Cli 'gh' -Block 'GH2' -Force
        $updated | Should -Match 'GH2'
        $updated | Should -Match 'RG'
        $updated | Should -Not -Match '(?ms)BEGIN v1\s+GH\s+#'
    }
}

Describe 'Register-CliCompletion against a sandbox profile' -Tag 'Light','Completion' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Utils.ps1')
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("Utils-CC-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:profile = Join-Path $script:sandbox 'Profile.ps1'
    }

    AfterAll {
        if (Test-Path $script:sandbox) { Remove-Item $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns Skipped for an unknown CLI with no PSCompletions definition' {
        $r = Register-CliCompletion -Cli 'definitely-not-a-real-cli-xyz' -Force -ProfilePath $script:profile
        $r.Source | Should -Be 'Skipped'
        $r.Action | Should -Be 'Skipped'
    }

    It '-WhatIf does not touch the profile' {
        if (Test-Path $script:profile) { Remove-Item $script:profile -Force }
        Register-CliCompletion -Cli 'gh' -Force -WhatIf -ProfilePath $script:profile | Out-Null
        (Test-Path $script:profile) | Should -Be $false
    }

    It 'Preserved when re-run without -Force on an existing block' {
        # Seed with a manually-written block to avoid depending on native gh.
        $body = "# ScoopBucket:CliCompletion:gh:BEGIN v1`r`nBODY`r`n# ScoopBucket:CliCompletion:gh:END`r`n"
        [System.IO.File]::WriteAllText($script:profile, $body, [System.Text.UTF8Encoding]::new($false))
        $r = Register-CliCompletion -Cli 'gh' -ProfilePath $script:profile
        $r.Action | Should -Be 'Preserved'
        (Get-Content -Raw -Path $script:profile) | Should -Match 'BODY'
    }

    It 'emits a Write-Warning when a -NativeCommand produces empty output (#73)' {
        # Regression guard: silent dead wiring must surface in install logs.
        # An unknown CLI name is used so PSCompletions has no catalog entry,
        # forcing the Skipped path. The scriptblock emits nothing, mimicking
        # `bw completion --shell powershell` / `copilot completion powershell`
        # / `gcloud --quiet --help-format=ps1` on real installs.
        if (Test-Path $script:profile) { Remove-Item $script:profile -Force }
        $warnings = @()
        $r = Register-CliCompletion `
                -Cli 'definitely-not-a-real-cli-xyz73' `
                -NativeCommand { } `
                -Force `
                -ProfilePath $script:profile `
                -WarningVariable warnings `
                -WarningAction SilentlyContinue
        $r.Action  | Should -Be 'Skipped'
        $r.Source  | Should -Be 'Skipped'
        $warnings  | Should -Not -BeNullOrEmpty
        ($warnings -join "`n") | Should -Match 'Native command produced no output'
    }

    It 'does NOT emit a Write-Warning when no -NativeCommand is supplied and source is Skipped' {
        # The warning should only fire when the caller-supplied NativeCommand
        # itself is empty. PSCompletions-only fallthrough with no catalog
        # entry is a normal best-effort outcome and should stay quiet.
        if (Test-Path $script:profile) { Remove-Item $script:profile -Force }
        $warnings = @()
        $r = Register-CliCompletion `
                -Cli 'definitely-not-a-real-cli-xyz73b' `
                -Force `
                -ProfilePath $script:profile `
                -WarningVariable warnings `
                -WarningAction SilentlyContinue
        $r.Source  | Should -Be 'Skipped'
        ($warnings | Where-Object { $_ -match 'Register-CliCompletion' }) | Should -BeNullOrEmpty
    }
}
