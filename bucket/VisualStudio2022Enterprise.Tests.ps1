. "$PSScriptRoot\Utils.ps1"

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Manual','Heavy','Install' {
    BeforeAll {
        if (Test-ScoopPackageInstalled $name) {
            # Don't auto-uninstall heavyweight packages — uninstalling Visual
            # Studio is destructive. If already installed, skip the install
            # path; the idempotency check below still validates re-run.
            $script:preInstalled = $true
        } else {
            $script:preInstalled = $false
        }
    }

    It 'installs from the local manifest' -Skip:$script:preInstalled {
        Install-LocalManifest "$PSScriptRoot\$name.json"
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is registered as Visual Studio 2022' {
        $vswhere = Get-Command vswhere -ErrorAction Ignore
        if ($vswhere) {
            $installations = & vswhere.exe -products '*' -property installationPath 2>$null
            $vs2022 = $installations | Where-Object { $_ -match '2022' }
            $vs2022 | Should -Not -BeNullOrEmpty
        } else {
            Get-Program -Filter '*Visual Studio*2022*' | Should -Not -BeNullOrEmpty
        }
    }
}
