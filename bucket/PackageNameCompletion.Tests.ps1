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
}
