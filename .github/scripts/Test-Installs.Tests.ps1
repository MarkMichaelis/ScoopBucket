#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for the dynamic package discovery logic in Test-Installs.ps1.
.DESCRIPTION
    Dot-sources only the discovery functions (Find-HashTableBlocks,
    Get-IterationInstaller, Get-PackagesFromScript, Get-AllPackages) by
    extracting them from Test-Installs.ps1, then validates that every
    expected package pattern is correctly discovered from the real bucket
    scripts.  No packages are actually installed.
#>

BeforeAll {
    # Extract and dot-source only the function definitions from the script
    # (skip #Requires, Main Execution, and install functions that touch the system)
    $scriptPath = Join-Path $PSScriptRoot 'Test-Installs.ps1'
    $scriptContent = Get-Content $scriptPath -Raw

    # Extract function blocks we need for testing
    $functionsToLoad = @(
        'Find-HashTableBlocks'
        'Get-IterationInstaller'
        'Get-PackagesFromScript'
        'Get-AllPackages'
    )

    $functionBodies = foreach ($funcName in $functionsToLoad) {
        if ($scriptContent -match "(?ms)(function\s+$funcName\s*\{.+?)(?=\nfunction\s|\n#\s*={5,})") {
            $Matches[1]
        }
    }

    # Create a script block with the extracted functions and execute it
    $loadScript = $functionBodies -join "`n`n"
    Invoke-Expression $loadScript

    # Set repo root for bucket path
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $bucketPath = Join-Path $repoRoot 'bucket'
}

# ============================================================================
# Find-HashTableBlocks
# ============================================================================

Describe 'Find-HashTableBlocks' {
    It 'should extract a simple hashtable block' {
        $content = @'
$Packages = @{
    'Item1'=([PSCustomObject]@{ Name='One'; })
    'Item2'=([PSCustomObject]@{ Name='Two'; })
}
'@
        $blocks = Find-HashTableBlocks -Content $content
        $blocks | Should -HaveCount 1
        $blocks[0].VarName | Should -Be 'Packages'
        $blocks[0].Content | Should -Match 'Item1'
        $blocks[0].Content | Should -Match 'Item2'
    }

    It 'should extract multiple hashtable blocks' {
        $content = @'
$First = @{
    'A'='1'
}
$Second = @{
    'B'='2'
}
'@
        $blocks = Find-HashTableBlocks -Content $content
        $blocks | Should -HaveCount 2
        $blocks[0].VarName | Should -Be 'First'
        $blocks[1].VarName | Should -Be 'Second'
    }

    It 'should handle nested braces correctly' {
        $content = @'
$Pkg = @{
    'X'=([PSCustomObject]@{ Inner=@{ Deep='val' } })
}
'@
        $blocks = Find-HashTableBlocks -Content $content
        $blocks | Should -HaveCount 1
        $blocks[0].VarName | Should -Be 'Pkg'
        $blocks[0].Content | Should -Match 'Deep'
    }

    It 'should return empty for content without hashtable assignments' {
        $blocks = Find-HashTableBlocks -Content 'Write-Host "hello"'
        @($blocks).Count | Should -Be 0
    }
}

# ============================================================================
# Get-IterationInstaller
# ============================================================================

Describe 'Get-IterationInstaller' {
    It 'should detect winget with --scope machine' {
        $content = @'
$WingetPackages = @{
    'Foo'=([PSCustomObject]@{ WingetName='Foo'; WinGetID='Vendor.Foo'; })
}
$WingetPackages.Values |
    ForEach-Object {
        winget install --scope machine --id $_.WinGetID
    }
'@
        $result = Get-IterationInstaller -VarName 'WingetPackages' -Content $content
        $result.InstallerType | Should -Be 'winget'
        $result.Scope | Should -Be 'machine'
    }

    It 'should detect winget-store for msstore source' {
        $content = @'
$MSStore = @{
    'App'=([PSCustomObject]@{ WingetName='App'; WinGetID='9NXXX'; })
}
$MSStore.Values |
    ForEach-Object {
        winget install --source msstore --id $_.WinGetID
    }
'@
        $result = Get-IterationInstaller -VarName 'MSStore' -Content $content
        $result.InstallerType | Should -Be 'winget-store'
    }

    It 'should detect choco installer' {
        $content = @'
$Choco = @{ 'A'='1' }
$Choco.Values | ForEach-Object { choco install $_ }
'@
        $result = Get-IterationInstaller -VarName 'Choco' -Content $content
        $result.InstallerType | Should -Be 'choco'
    }

    It 'should detect scoop installer' {
        $content = @'
$Scoop = @{ 'A'='1' }
$Scoop.Values | ForEach-Object { scoop install -g $_ }
'@
        $result = Get-IterationInstaller -VarName 'Scoop' -Content $content
        $result.InstallerType | Should -Be 'scoop'
    }

    It 'should return unknown when variable is not iterated' {
        $content = @'
$Orphan = @{ 'A'='1' }
Write-Host "done"
'@
        $result = Get-IterationInstaller -VarName 'Orphan' -Content $content
        $result.InstallerType | Should -Be 'unknown'
    }
}

# ============================================================================
# Get-PackagesFromScript — unit tests with temp scripts
# ============================================================================

Describe 'Get-PackagesFromScript' {
    BeforeAll {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "TestInstallsTests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    AfterAll {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Winget hashtable blocks' {
        It 'should discover winget packages from hashtable with WinGetID' {
            $script = Join-Path $tempDir 'WingetTest.ps1'
            @'
$Packages = @{
    'Foo'=([PSCustomObject]@{ WingetName='Foo App'; WinGetID='Vendor.Foo'; })
    'Bar'=([PSCustomObject]@{ WingetName='Bar App'; WinGetID='Vendor.Bar'; })
}
$Packages.Values | ForEach-Object {
    winget install --scope machine --id $_.WinGetID
}
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 2
            $pkgs[0].InstallerType | Should -Be 'winget'
            $pkgs[0].Scope | Should -Be 'machine'
            ($pkgs | Where-Object PackageId -eq 'Vendor.Foo') | Should -Not -BeNullOrEmpty
            ($pkgs | Where-Object PackageId -eq 'Vendor.Bar') | Should -Not -BeNullOrEmpty
        }

        It 'should skip commented-out entries in hashtable blocks' {
            $script = Join-Path $tempDir 'CommentedTest.ps1'
            @'
$Packages = @{
    'Active'=([PSCustomObject]@{ WingetName='Active'; WinGetID='Vendor.Active'; })
#    'Commented'=([PSCustomObject]@{ WingetName='Commented'; WinGetID='Vendor.Commented'; })
}
$Packages.Values | ForEach-Object {
    winget install --scope machine --id $_.WinGetID
}
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 1
            $pkgs[0].PackageId | Should -Be 'Vendor.Active'
        }

        It 'should detect msstore installer type' {
            $script = Join-Path $tempDir 'MSStoreTest.ps1'
            @'
$StoreApps = @{
    'App1'=([PSCustomObject]@{ WingetName='Store App'; WinGetID='9NXXX123'; })
}
$StoreApps.Values | ForEach-Object {
    winget install --source msstore --id $_.WinGetID --accept-package-agreements
}
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 1
            $pkgs[0].InstallerType | Should -Be 'winget-store'
        }
    }

    Context 'Piped arrays' {
        It 'should discover choco packages from piped array' {
            $script = Join-Path $tempDir 'PipedChoco.ps1'
            @'
'pkg1','pkg2','pkg3' | ForEach-Object {
    choco install -y $_
}
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 3
            $pkgs | ForEach-Object { $_.InstallerType | Should -Be 'choco' }
            ($pkgs | Where-Object Name -eq 'pkg1') | Should -Not -BeNullOrEmpty
            ($pkgs | Where-Object Name -eq 'pkg3') | Should -Not -BeNullOrEmpty
        }

        It 'should discover scoop packages from piped array' {
            $script = Join-Path $tempDir 'PipedScoop.ps1'
            @'
'tool1', 'tool2' | ForEach-Object {
    scoop install -g $_
}
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 2
            $pkgs | ForEach-Object { $_.InstallerType | Should -Be 'scoop' }
        }
    }

    Context 'Standalone choco install' {
        It 'should discover standalone choco install commands' {
            $script = Join-Path $tempDir 'StandaloneChoco.ps1'
            @'
choco install Office365ProPlus -y
choco install Microsoft-Teams -y
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 2
            ($pkgs | Where-Object Name -eq 'Office365ProPlus') | Should -Not -BeNullOrEmpty
            ($pkgs | Where-Object Name -eq 'Microsoft-Teams') | Should -Not -BeNullOrEmpty
        }

        It 'should not duplicate choco packages already found via piped array' {
            $script = Join-Path $tempDir 'ChocoDedupe.ps1'
            @'
'myPackage' | ForEach-Object {
    choco install -y $_
}
choco install myPackage -y
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 1
        }
    }

    Context 'Standalone winget install' {
        It 'should discover standalone winget install with dotted package ID' {
            $script = Join-Path $tempDir 'StandaloneWinget.ps1'
            @'
winget install --scope machine GitKraken.cli
winget install --scope machine GitHub.cli
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 2
            $pkgs | ForEach-Object { $_.InstallerType | Should -Be 'winget' }
            $pkgs | ForEach-Object { $_.Scope | Should -Be 'machine' }
        }

        It 'should not pick up $_ winget references from ForEach-Object bodies' {
            $script = Join-Path $tempDir 'WingetPipeIgnore.ps1'
            @'
$Packages = @{
    'Foo'=([PSCustomObject]@{ WingetName='Foo'; WinGetID='Vendor.Foo'; })
}
$Packages.Values | ForEach-Object {
    winget install --scope machine --id $_.WinGetID
}
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            # Should find 1 from hashtable, none from standalone (because $_ is present)
            $wingetStandalone = $pkgs | Where-Object { $_.InstallerType -eq 'winget' -and $_.Name -eq 'Vendor.Foo' }
            $wingetStandalone | Should -BeNullOrEmpty  # hashtable entry Name is 'Foo', not 'Vendor.Foo'
        }
    }

    Context 'Install-Module commands' {
        It 'should discover Install-Module commands' {
            $script = Join-Path $tempDir 'PSModules.ps1'
            @'
Install-Module PowershellGet -Repository PSGallery -Scope AllUsers
Install-Module Pscx -AllowClobber -AllowPrerelease -Scope AllUsers
Install-Module ZLocation -Repository PSGallery -Scope AllUsers
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 3
            $pkgs | ForEach-Object { $_.InstallerType | Should -Be 'ps-module' }

            $pscx = $pkgs | Where-Object Name -eq 'Pscx'
            $pscx.AdditionalArgs | Should -Match 'AllowPrerelease'

            $psGet = $pkgs | Where-Object Name -eq 'PowershellGet'
            $psGet.AdditionalArgs | Should -Match 'PSGallery'
        }

        It 'should skip commented-out Install-Module lines' {
            $script = Join-Path $tempDir 'PSModuleComment.ps1'
            @'
Install-Module ActiveModule -Scope AllUsers
# Install-Module CommentedModule -Scope AllUsers
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $pkgs | Should -HaveCount 1
            $pkgs[0].Name | Should -Be 'ActiveModule'
        }
    }

    Context 'Sideload (Add-AppxPackage)' {
        It 'should discover sideloaded MSIX apps' {
            $script = Join-Path $tempDir 'Sideload.ps1'
            @'
Write-Host "Installing Readwise Reader..."
Invoke-WebRequest -Uri 'https://readwise.io/read/download_latest/desktop/windows' -OutFile "$env:TEMP\Reader.msix"
Add-AppxPackage -Path "$env:TEMP\Reader.msix"
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            $sideload = $pkgs | Where-Object InstallerType -eq 'sideload'
            $sideload | Should -HaveCount 1
            $sideload[0].Name | Should -Match 'Readwise Reader'
            $sideload[0].PackageId | Should -Match 'readwise.io'
        }
    }

    Context 'Empty and no-package scripts' {
        It 'should return empty array for scripts with no packages' {
            $script = Join-Path $tempDir 'Empty.ps1'
            @'
Write-Host "Nothing to install"
$x = 42
'@ | Set-Content $script

            $pkgs = Get-PackagesFromScript -FilePath $script
            @($pkgs).Count | Should -Be 0
        }
    }
}

# ============================================================================
# Integration tests — real bucket scripts
# ============================================================================

Describe 'Get-PackagesFromScript — real bucket scripts' {
    BeforeAll {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $bucketPath = Join-Path $repoRoot 'bucket'
    }

    Context 'OSBasePackages.ps1' {
        BeforeAll {
            $pkgs = Get-PackagesFromScript -FilePath (Join-Path $bucketPath 'OSBasePackages.ps1')
        }

        It 'should discover winget packages' {
            $pkgs.Count | Should -BeGreaterOrEqual 10
            $pkgs | ForEach-Object { $_.InstallerType | Should -Be 'winget' }
        }

        It 'should find 7-Zip' {
            ($pkgs | Where-Object PackageId -eq '7Zip.7Zip') | Should -Not -BeNullOrEmpty
        }

        It 'should find Google Chrome' {
            ($pkgs | Where-Object PackageId -eq 'Google.Chrome') | Should -Not -BeNullOrEmpty
        }

        It 'should find FFmpeg' {
            ($pkgs | Where-Object PackageId -eq 'Gyan.FFmpeg') | Should -Not -BeNullOrEmpty
        }

        It 'should have machine scope' {
            $pkgs | ForEach-Object { $_.Scope | Should -Be 'machine' }
        }

        It 'should not include commented-out entries' {
            ($pkgs | Where-Object PackageId -match 'Notepad2') | Should -BeNullOrEmpty
        }
    }

    Context 'ClientBasePackages.ps1' {
        BeforeAll {
            $pkgs = Get-PackagesFromScript -FilePath (Join-Path $bucketPath 'ClientBasePackages.ps1')
        }

        It 'should discover choco packages from piped array' {
            $chocoPackages = $pkgs | Where-Object InstallerType -eq 'choco'
            $chocoPackages.Count | Should -BeGreaterOrEqual 4
            ($chocoPackages | Where-Object Name -eq 'foxitreader') | Should -Not -BeNullOrEmpty
            ($chocoPackages | Where-Object Name -eq 'geosetter') | Should -Not -BeNullOrEmpty
        }

        It 'should discover winget packages from hashtable' {
            $wingetPackages = $pkgs | Where-Object InstallerType -eq 'winget'
            $wingetPackages.Count | Should -BeGreaterOrEqual 10
            ($wingetPackages | Where-Object PackageId -eq 'Anthropic.Claude') | Should -Not -BeNullOrEmpty
            ($wingetPackages | Where-Object PackageId -eq 'Spotify.Spotify') | Should -Not -BeNullOrEmpty
        }

        It 'should discover Microsoft Store packages as winget-store' {
            $storePackages = $pkgs | Where-Object InstallerType -eq 'winget-store'
            $storePackages.Count | Should -BeGreaterOrEqual 3
            ($storePackages | Where-Object Name -eq 'ChatGPT') | Should -Not -BeNullOrEmpty
        }

        It 'should discover sideloaded app' {
            $sideload = $pkgs | Where-Object InstallerType -eq 'sideload'
            $sideload | Should -HaveCount 1
            $sideload[0].Name | Should -Match 'Readwise Reader'
        }

        It 'should not include commented-out winget entries' {
            ($pkgs | Where-Object PackageId -match 'Perplexity') | Should -BeNullOrEmpty
            ($pkgs | Where-Object PackageId -match 'PowerAutomateDesktop') | Should -BeNullOrEmpty
        }
    }

    Context 'DeveloperBasePackages.ps1' {
        BeforeAll {
            $pkgs = Get-PackagesFromScript -FilePath (Join-Path $bucketPath 'DeveloperBasePackages.ps1')
        }

        It 'should discover choco packages' {
            ($pkgs | Where-Object { $_.InstallerType -eq 'choco' -and $_.Name -eq 'nodejs' }) | Should -Not -BeNullOrEmpty
        }

        It 'should discover scoop packages' {
            $scoopPackages = $pkgs | Where-Object InstallerType -eq 'scoop'
            $scoopPackages.Count | Should -BeGreaterOrEqual 2
            ($scoopPackages | Where-Object Name -eq 'dotnet') | Should -Not -BeNullOrEmpty
            ($scoopPackages | Where-Object Name -eq 'VisualStudio2026Enterprise') | Should -Not -BeNullOrEmpty
        }

        It 'should discover winget packages from hashtable' {
            $wingetPackages = $pkgs | Where-Object InstallerType -eq 'winget'
            ($wingetPackages | Where-Object PackageId -eq 'Microsoft.VisualStudioCode') | Should -Not -BeNullOrEmpty
            ($wingetPackages | Where-Object PackageId -eq 'ScooterSoftware.BeyondCompare.4') | Should -Not -BeNullOrEmpty
        }

        It 'should not include commented-out entries' {
            ($pkgs | Where-Object PackageId -match 'Anysphere') | Should -BeNullOrEmpty
            ($pkgs | Where-Object PackageId -match 'Miniforge') | Should -BeNullOrEmpty
        }
    }

    Context 'GitConfigure.ps1' {
        BeforeAll {
            $pkgs = Get-PackagesFromScript -FilePath (Join-Path $bucketPath 'GitConfigure.ps1')
        }

        It 'should discover standalone choco install commands' {
            $chocoPackages = $pkgs | Where-Object InstallerType -eq 'choco'
            ($chocoPackages | Where-Object Name -eq 'git') | Should -Not -BeNullOrEmpty
            ($chocoPackages | Where-Object Name -match 'git-credential') | Should -Not -BeNullOrEmpty
            ($chocoPackages | Where-Object Name -eq 'gitextensions') | Should -Not -BeNullOrEmpty
            ($chocoPackages | Where-Object Name -eq 'gitkraken') | Should -Not -BeNullOrEmpty
        }

        It 'should discover standalone winget install commands' {
            $wingetPackages = $pkgs | Where-Object InstallerType -eq 'winget'
            ($wingetPackages | Where-Object PackageId -eq 'GitKraken.cli') | Should -Not -BeNullOrEmpty
            ($wingetPackages | Where-Object PackageId -eq 'GitHub.cli') | Should -Not -BeNullOrEmpty
        }

        It 'should discover Install-Module posh-git' {
            $psModules = $pkgs | Where-Object InstallerType -eq 'ps-module'
            ($psModules | Where-Object Name -match 'posh-git') | Should -Not -BeNullOrEmpty
        }
    }

    Context 'MicrosoftOffice365.ps1' {
        BeforeAll {
            $pkgs = Get-PackagesFromScript -FilePath (Join-Path $bucketPath 'MicrosoftOffice365.ps1')
        }

        It 'should discover Office365ProPlus' {
            ($pkgs | Where-Object { $_.InstallerType -eq 'choco' -and $_.Name -eq 'Office365ProPlus' }) | Should -Not -BeNullOrEmpty
        }

        It 'should discover Microsoft-Teams' {
            ($pkgs | Where-Object { $_.InstallerType -eq 'choco' -and $_.Name -eq 'Microsoft-Teams' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Chocolatey.ps1' {
        BeforeAll {
            $pkgs = Get-PackagesFromScript -FilePath (Join-Path $bucketPath 'Chocolatey.ps1')
        }

        It 'should discover chocolatey-core.extension' {
            ($pkgs | Where-Object { $_.InstallerType -eq 'choco' -and $_.Name -eq 'chocolatey-core.extension' }) | Should -Not -BeNullOrEmpty
        }

        It 'should discover au' {
            ($pkgs | Where-Object { $_.InstallerType -eq 'choco' -and $_.Name -eq 'au' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'PowerShell.ps1' {
        BeforeAll {
            $pkgs = Get-PackagesFromScript -FilePath (Join-Path $bucketPath 'PowerShell.ps1')
        }

        It 'should discover PS modules' {
            $psModules = $pkgs | Where-Object InstallerType -eq 'ps-module'
            $psModules.Count | Should -BeGreaterOrEqual 4
            ($psModules | Where-Object Name -eq 'PowershellGet') | Should -Not -BeNullOrEmpty
            ($psModules | Where-Object Name -eq 'Pscx') | Should -Not -BeNullOrEmpty
            ($psModules | Where-Object Name -eq 'ZLocation') | Should -Not -BeNullOrEmpty
            ($psModules | Where-Object Name -eq 'PSReadLine') | Should -Not -BeNullOrEmpty
            ($psModules | Where-Object Name -eq 'Microsoft.PowerShell.SecretManagement') | Should -Not -BeNullOrEmpty
        }

        It 'should preserve -AllowPrerelease for Pscx' {
            $pscx = $pkgs | Where-Object Name -eq 'Pscx'
            $pscx.AdditionalArgs | Should -Match 'AllowPrerelease'
        }

        It 'should preserve -Repository PSGallery for PowershellGet' {
            $psGet = $pkgs | Where-Object Name -eq 'PowershellGet'
            $psGet.AdditionalArgs | Should -Match 'PSGallery'
        }

        It 'should discover Pester via choco' {
            ($pkgs | Where-Object { $_.InstallerType -eq 'choco' -and $_.Name -eq 'Pester' }) | Should -Not -BeNullOrEmpty
        }
    }
}

# ============================================================================
# Get-AllPackages — integration test
# ============================================================================

Describe 'Get-AllPackages' {
    BeforeAll {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $bucketPath = Join-Path $repoRoot 'bucket'
        $allPkgs = Get-AllPackages -BucketPath $bucketPath
    }

    It 'should discover packages from multiple scripts' {
        $sourceScripts = $allPkgs | Select-Object -ExpandProperty SourceScript -Unique
        $sourceScripts.Count | Should -BeGreaterOrEqual 5
    }

    It 'should discover at least 40 total packages' {
        $allPkgs.Count | Should -BeGreaterOrEqual 40
    }

    It 'should include all installer types' {
        $types = $allPkgs | Select-Object -ExpandProperty InstallerType -Unique
        $types | Should -Contain 'winget'
        $types | Should -Contain 'choco'
        $types | Should -Contain 'scoop'
        $types | Should -Contain 'ps-module'
        $types | Should -Contain 'winget-store'
        $types | Should -Contain 'sideload'
    }

    It 'should not include Utils.ps1 as a source' {
        ($allPkgs | Where-Object SourceScript -eq 'Utils.ps1') | Should -BeNullOrEmpty
    }

    It 'should not include test files as a source' {
        ($allPkgs | Where-Object { $_.SourceScript -match '\.Tests\.ps1$' }) | Should -BeNullOrEmpty
    }

    It 'should have no empty package names' {
        $allPkgs | ForEach-Object { $_.Name | Should -Not -BeNullOrEmpty }
    }

    It 'should have no empty package IDs' {
        $allPkgs | ForEach-Object { $_.PackageId | Should -Not -BeNullOrEmpty }
    }
}
