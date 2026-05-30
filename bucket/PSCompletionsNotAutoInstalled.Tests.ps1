#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Issue #241: assert the bucket no longer auto-installs PSCompletions.
#>

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
}

Describe 'PSCompletions hard dependency removed' -Tag 'Light','Module' {

    It 'module no longer exports Install-PSCompletionsModule' {
        $cmd = Get-Command -Module MarkMichaelis.ScoopBucket -Name Install-PSCompletionsModule -ErrorAction SilentlyContinue
        $cmd | Should -BeNullOrEmpty -Because "Issue #241 removed the PSCompletions hard dependency; the install helper must not be exported"
    }

    It 'no production bucket file declares Completion=pscompletions' {
        $bucketDir = Join-Path $script:repoRoot 'bucket'
        $offenders = Get-ChildItem -Path $bucketDir -Filter '*.ps1' |
            Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
            Where-Object {
                $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName
                $raw -match "Completion\s*=\s*'pscompletions'"
            } |
            Select-Object -ExpandProperty Name
        $offenders | Should -BeNullOrEmpty -Because "Phase 2 migrated every CLI to Completion='auto' with a NativeCommandScript or Completion='native'. New pscompletions entries belong on a feature branch with their own resolver re-introduction; current bucket must stay clean."
    }

    It 'module no longer ships Invoke-PscCatalogUpdate' {
        $mod = Get-Module MarkMichaelis.ScoopBucket
        $hasFn = & $mod { [bool](Get-Command Invoke-PscCatalogUpdate -CommandType Function -ErrorAction SilentlyContinue) }
        $hasFn | Should -BeFalse -Because "Issue #241 removed Invoke-PscCatalogUpdate; the helper is dead code now that no production bundle uses Completion='pscompletions'"
    }

    It 'Update-PackageCompletion -Force does not import PSCompletions when run against the current bucket' {
        $profilePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-241-profile-$([guid]::NewGuid().ToString('N')).ps1")
        try {
            $preLoaded = [bool](Get-Module -Name PSCompletions)
            $null = Update-PackageCompletion -Force -ProfilePath $profilePath -ErrorAction Stop -WarningAction SilentlyContinue
            $postLoaded = [bool](Get-Module -Name PSCompletions)
            if (-not $preLoaded) {
                $postLoaded | Should -BeFalse -Because "Issue #241: Update-PackageCompletion against the current bucket must not Import-Module PSCompletions"
            }
        } finally {
            if (Test-Path $profilePath) { Remove-Item -LiteralPath $profilePath -Force -ErrorAction Ignore }
            $sidecar = Join-Path (Split-Path -Parent $profilePath) 'completions'
            if (Test-Path $sidecar) { Remove-Item -LiteralPath $sidecar -Recurse -Force -ErrorAction Ignore }
        }
    }
}