$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\ScoopBucket\ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install' {
    BeforeAll {
        if (Test-ScoopPackageInstalled $name) {
            scoop uninstall $name
        }
    }

    It 'installs from the local manifest' {
        Install-LocalManifest "$PSScriptRoot\$name.json"
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'configures the visual-studio mergetool when VS is installed' {
        $vsRoots = @(
            "${env:ProgramFiles}\Microsoft Visual Studio",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
        ) | Where-Object { $_ -and (Test-Path $_) }

        $vsExe = $null
        foreach ($root in $vsRoots) {
            $vsExe = Get-ChildItem -Path $root -Filter 'devenv.exe' -Recurse -ErrorAction Ignore |
                Select-Object -First 1
            if ($vsExe) { break }
        }

        if (-not $vsExe) {
            Set-ItResult -Skipped -Because 'Visual Studio not installed'
            return
        }
        git config --global mergetool.visual-studio.path | Should -Not -BeNullOrEmpty
    }
}
