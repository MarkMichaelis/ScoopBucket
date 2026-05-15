#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Light-suite Pester coverage for the package-name argument completer
# registered on Install-Package -Name and Get-Package -Name. Verifies
# both the underlying name-suggestion helper (regex-scan over bundles)
# and that the completer is wired into TabExpansion2.

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $scoopBucketPsd1 -Force
    $script:bucketPath = Resolve-Path (Join-Path $PSScriptRoot '.')
}

Describe 'Get-PackageNameSuggestion' -Tag 'Light' {
    It 'returns all declared package names across migrated bundles' {
        $names = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion }
        $names | Should -Not -BeNullOrEmpty
        ($names | Measure-Object).Count | Should -BeGreaterThan 10
        $names | Should -Contain 'Beyond Compare'
    }

    It 'includes packages declared via one-line [Package]@{ Name = ...; ... } literals' {
        # Regression: the prior `^\s*Name\s*=\s*` anchor only matched
        # multi-line literals (Name on its own line). One-liners like
        # `[Package]@{ Name = 'Visual Studio Code'; ... }` were silently
        # absent from completion.
        $names = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion }
        $names | Should -Contain 'Visual Studio Code'
        $names | Should -Contain 'Visual Studio'
        $names | Should -Contain 'Bitwarden'
        $names | Should -Contain '7-Zip'
        $names | Should -Contain 'Windows Terminal'
    }

    It 'includes declarative bundle names so Install-Package <BundleName> tab-completes' {
        # `Install-Package OSBasePackages` installs every package in
        # the OSBasePackages bundle. The completer must surface every
        # bundle that ships a `<bundle>.json` manifest.
        $names = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion }
        foreach ($bundle in 'OSBasePackages','DeveloperBasePackages','ClientBasePackages','MicrosoftOffice365','AIAgents') {
            $names | Should -Contain $bundle
        }
    }

    It 'includes bare-json manifest names (no [Package] / imperative .ps1) so they tab-complete' {
        # Manifests with no declarative [Package] entry — bare json
        # (Codex, dotnet, GeminiCli, ...) and imperative .ps1 bundles
        # (Chocolatey, Gemini, ClaudeExcel, ...) — must still tab-
        # complete so users can `Install-Package <name>` rather than
        # falling back to `scoop install`.
        $names = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion }
        foreach ($manifest in 'Codex','dotnet','Chocolatey','Gemini','ClaudeExcel','WSL-Ubuntu-2004') {
            $names | Should -Contain $manifest
        }
    }

    It 'narrows by case-insensitive prefix' {
        $matches = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion -WordToComplete 'beyon' }
        $matches | Should -Contain 'Beyond Compare'
        # All returned names should contain the substring 'beyon' (case-insensitive)
        foreach ($n in $matches) {
            $n.ToLowerInvariant() | Should -Match 'beyon'
        }
    }

    It 'matches mid-word (substring) when no prefix hits' {
        $matches = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion -WordToComplete 'compare' }
        $matches | Should -Contain 'Beyond Compare'
    }

    It 'returns the cached list quickly on a second call' {
        # Warm the cache.
        & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion } | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageNameSuggestion -WordToComplete 'b' } | Out-Null
        $sw.Stop()
        # Tab completion budget; warm cache should be well under 250ms.
        $sw.ElapsedMilliseconds | Should -BeLessThan 250
    }
}

Describe 'Install-Package / Get-Package -Name argument completer' -Tag 'Light' {
    It 'completes Install-Package -Name from a partial substring' {
        $line = "Install-Package -Name beyon"
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain "'Beyond Compare'"
    }

    It 'completes Get-Package -Name from a partial substring' {
        $line = "Get-Package -Name comp"
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain "'Beyond Compare'"
    }

    It 'quotes completion text for names containing whitespace' {
        $line = "Install-Package -Name "
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $whitespaceNames = $result.CompletionMatches | Where-Object { $_.ListItemText -match '\s' }
        $whitespaceNames | Should -Not -BeNullOrEmpty
        foreach ($m in $whitespaceNames) {
            $m.CompletionText | Should -Match "^'.*'$"
        }
    }

    It "doubles embedded single quotes so apostrophe names parse" {
        # The completer runs through the bucket index and we don't
        # ship any apostrophe names today, so exercise the registered
        # scriptblock directly with a synthetic suggester to prove the
        # escaping logic itself.
        $sb = (Get-Command Register-ArgumentCompleter -ErrorAction Ignore)
        $module = Get-Module MarkMichaelis.ScoopBucket
        $module | Should -Not -BeNullOrEmpty

        # Pull the registered completer's scriptblock and invoke it with
        # a synthetic name list via a temporary override of
        # Get-PackageNameSuggestion in module scope.
        $result = & $module {
            $original = Get-Item Function:\Get-PackageNameSuggestion -ErrorAction Ignore
            try {
                Set-Item Function:\Get-PackageNameSuggestion -Value { param($WordToComplete) "O'Reilly Books" }
                $line = "Install-Package -Name oreilly"
                TabExpansion2 -inputScript $line -cursorColumn $line.Length
            } finally {
                if ($original) {
                    Set-Item Function:\Get-PackageNameSuggestion -Value $original.ScriptBlock
                }
            }
        }
        $texts = $result.CompletionMatches.CompletionText
        $texts | Should -Contain "'O''Reilly Books'"
        # And the suggestion must actually parse as a single string
        # token — round-trip via Invoke-Expression.
        foreach ($t in $texts) {
            { Invoke-Expression "`$null = $t" } | Should -Not -Throw
        }
    }
}
