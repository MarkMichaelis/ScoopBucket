#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior-first regression: -DryRun and -WhatIf must drive ONE preview
# mechanism (ShouldProcess / $WhatIfPreference). -DryRun is retained as a
# first-class alias that routes through the SAME code path as -WhatIf.
# Preview is opt-in: the default (no switch) performs the real install/update.
# See #299.

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'

    Import-Module $script:psd1 -Force

    # Throwaway bucket with a single winget package so Install-Package /
    # Update-Package have a declarative [Package] to dispatch.
    $script:tmpBucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-preview-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:tmpBucket | Out-Null

    $bundleText = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
    [Package]@{ Name = 'solo'; Installer = 'winget'; Id = 'Test.Solo' }
)

Invoke-PackageInstall -Packages `$Packages -Bundle 'PreviewBundle'
"@
    Set-Content -Path (Join-Path $script:tmpBucket 'PreviewBundle.ps1') -Value $bundleText -Encoding UTF8

    $bundleManifest = @{
        '$schema'  = 'https://raw.githubusercontent.com/lukesampson/scoop/master/schema.json'
        version   = '1.00.000'
        url       = @('https://example.invalid/preview-bundle')
        installer = @{ script = @('& "$dir\\PreviewBundle.ps1"') }
    }
    Set-Content -LiteralPath (Join-Path $script:tmpBucket 'PreviewBundle.json') `
        -Value ($bundleManifest | ConvertTo-Json -Depth 4) -Encoding UTF8
}

AfterAll {
    if ($script:tmpBucket -and (Test-Path $script:tmpBucket)) {
        Remove-Item -LiteralPath $script:tmpBucket -Recurse -Force -ErrorAction Ignore
    }
}

Describe 'Install-Package preview: -WhatIf / -DryRun parity' -Tag 'Light', 'Module' {
    BeforeEach {
        # The engine branches on its own -WhatIf switch: a preview run must
        # reach it with $WhatIf = $true (no real install); a real run reaches
        # it with $WhatIf = $false. Encode that in the returned Reason so a
        # parity test can assert the mechanism, not just the wording.
        Mock -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage {
            if ($WhatIf) { return @{ State = 'Installed'; Reason = '(WhatIf)' } }
            return @{ State = 'Installed'; Reason = 'REAL-INSTALL' }
        }
    }

    It '-WhatIf performs no real install but emits a planned PackageResult row' {
        $r = @(Install-Package -Name 'solo' -WhatIf -SkipCompletion -BucketPath $script:tmpBucket)

        $r.Count     | Should -Be 1
        $r.Name      | Should -Be 'solo'
        $r.Installer | Should -Be 'winget'
        $r.Id        | Should -Be 'Test.Solo'
        $r.Status    | Should -Be 'Installed'
        $r.Reason    | Should -Be '(WhatIf)'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage `
            -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
        Should -Not -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage `
            -ParameterFilter { $WhatIf -ne $true }
    }

    It '-DryRun behaves identically to -WhatIf (same no-op, same planned row)' {
        $r = @(Install-Package -Name 'solo' -DryRun -SkipCompletion -BucketPath $script:tmpBucket)

        $r.Count  | Should -Be 1
        $r.Name   | Should -Be 'solo'
        $r.Status | Should -Be 'Installed'
        $r.Reason | Should -Be '(WhatIf)'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage `
            -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
        Should -Not -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage `
            -ParameterFilter { $WhatIf -ne $true }
    }

    It 'default (no switch) performs the real install (preview is opt-in)' {
        $r = @(Install-Package -Name 'solo' -SkipCompletion -BucketPath $script:tmpBucket)

        $r.Status | Should -Be 'Installed'
        $r.Reason | Should -Be 'REAL-INSTALL'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage `
            -Times 1 -Exactly -ParameterFilter { -not $WhatIf }
    }

    It '-WhatIf:$false forces the real install' {
        $r = @(Install-Package -Name 'solo' -WhatIf:$false -SkipCompletion -BucketPath $script:tmpBucket)

        $r.Reason | Should -Be 'REAL-INSTALL'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Install-WingetPackage `
            -Times 1 -Exactly -ParameterFilter { -not $WhatIf }
    }
}

Describe 'Update-Package preview: -WhatIf / -DryRun parity' -Tag 'Light', 'Module' {
    BeforeEach {
        # Empty index => the WhatIf path plans an update without probing real
        # engines; a real run reaches Update-WingetPackage.
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex { @{} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage {
            return @{ State = 'Updated'; Reason = 'REAL-UPDATE' }
        }
    }

    It '-WhatIf plans the update without invoking the engine' {
        $r = @(Update-Package -Name 'solo' -WhatIf -SkipCompletion -BucketPath $script:tmpBucket)

        $r.Name   | Should -Be 'solo'
        $r.Status | Should -Be 'Updated'
        $r.Reason | Should -Match 'WhatIf'
        Should -Not -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage
    }

    It '-DryRun behaves identically to -WhatIf' {
        $r = @(Update-Package -Name 'solo' -DryRun -SkipCompletion -BucketPath $script:tmpBucket)

        $r.Name   | Should -Be 'solo'
        $r.Status | Should -Be 'Updated'
        $r.Reason | Should -Match 'WhatIf'
        Should -Not -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage
    }

    It 'default (no switch) invokes the real update engine (preview is opt-in)' {
        $r = @(Update-Package -Name 'solo' -SkipCompletion -SkipBucketRefresh -BucketPath $script:tmpBucket)

        $r.Reason | Should -Be 'REAL-UPDATE'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Update-WingetPackage -Times 1 -Exactly
    }
}
