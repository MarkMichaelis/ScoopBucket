#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Install-Package is a resilient sweep: one bundle's failure must not abort
    the rest of the run (#451, second defect; same contract Update-Package got
    in #272).

.DESCRIPTION
    `-ErrorAction Continue -ErrorVariable +pkgErrors` on the
    Invoke-PackageInstall calls only tames the driver's *non-terminating*
    PackageInstallFailed records. In #451 the driver itself died: a bundle's
    installer script re-imported the module with `-Force`, disposing the
    session state mid-sweep, so the driver's own `Write-UpdateStatus`
    teardown threw. That terminating error propagated past -ErrorAction,
    skipped the driver's [PackageResult] emission, and took Install-Package
    with it -- a machine converged only partway (adb / gemini / aspire /
    lazygit never installed) with nothing in $pkgErrors to say why.

    These tests pin the contract independently of the root cause: whatever
    makes one bundle's dispatch throw, the sweep still reports that bundle as
    Failed and still dispatches the others.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psd1 = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force

    # Two single-package bundles so the sweep has something to carry on with
    # after the first one explodes.
    $script:tmpBucket = Join-Path ([System.IO.Path]::GetTempPath()) "ScoopBucket-sweep-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:tmpBucket | Out-Null

    $escapedPsd1 = $script:psd1 -replace "'", "''"
    foreach ($spec in @(
            @{ Bundle = 'BoomBundle'; Package = 'boom' }
            @{ Bundle = 'CalmBundle'; Package = 'calm' }
        )) {
        Set-Content -LiteralPath (Join-Path $script:tmpBucket "$($spec.Bundle).ps1") -Encoding UTF8 -Value @"
Import-Module '$escapedPsd1' -Force

`$Packages = [Package[]]@(
    [Package]@{ Name = '$($spec.Package)'; Installer = 'winget'; Id = 'Test.$($spec.Package)' }
)

Invoke-PackageInstall -Packages `$Packages -Bundle '$($spec.Bundle)'
"@
    }
}

AfterAll {
    if ($script:tmpBucket -and (Test-Path $script:tmpBucket)) {
        Remove-Item -LiteralPath $script:tmpBucket -Recurse -Force -ErrorAction Ignore
    }
}

Describe 'Install-Package sweep resilience' -Tag 'Light', 'Module' {

    BeforeEach {
        # Make one bundle's dispatch raise a TERMINATING error, shaped like the
        # #451 cascade (the module's own helper vanished mid-run).
        Mock -ModuleName MarkMichaelis.ScoopBucket -CommandName Invoke-PackageInstall -MockWith {
            if ($Bundle -eq 'BoomBundle') {
                throw "The term 'Write-UpdateStatus' is not recognized as a name of a cmdlet, function, script file, or executable program."
            }
            [PackageResult]@{
                Operation = 'Install'; Status = 'Installed'
                Name = @($Name)[0]; Installer = 'winget'; Bundle = $Bundle
            }
        }
    }

    It 'still dispatches the remaining bundles after one throws' {
        $result = @(Install-Package -Name 'boom', 'calm' -DryRun -SkipCompletion `
                -BucketPath $script:tmpBucket -IncludeUnchanged -ErrorAction SilentlyContinue)

        @($result | Where-Object { $_.Status -eq 'Installed' -and $_.Name -eq 'calm' }).Count |
            Should -Be 1 -Because 'a failure in one bundle must not cancel the others'
    }

    It 'reports the exploded bundle as a Failed row carrying the reason' {
        $result = @(Install-Package -Name 'boom', 'calm' -DryRun -SkipCompletion `
                -BucketPath $script:tmpBucket -IncludeUnchanged -ErrorAction SilentlyContinue)

        $failed = @($result | Where-Object Status -eq 'Failed')
        $failed.Count | Should -Be 1
        $failed[0].Name | Should -Be 'BoomBundle'
        $failed[0].Reason | Should -Match 'Write-UpdateStatus'
        $failed[0].Error | Should -Not -BeNullOrEmpty
    }

    It 'writes the failure to the error stream so -ErrorVariable captures it' {
        $null = Install-Package -Name 'boom', 'calm' -DryRun -SkipCompletion `
            -BucketPath $script:tmpBucket -IncludeUnchanged `
            -ErrorAction SilentlyContinue -ErrorVariable sweepErrors

        @($sweepErrors | Where-Object { $_.FullyQualifiedErrorId -like 'PackageInstallFailed*' }).Count |
            Should -BeGreaterThan 0 -Because '#451 left $pkgErrors empty because the error was terminating, never written'
    }
}
