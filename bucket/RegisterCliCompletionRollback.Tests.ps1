# ----------------------------------------------------------------------------
# Issue #179: Register-CliCompletion must validate a freshly-added
# PSCompletions handler in a child runspace. If validation fails (e.g. the
# PSCompletions catalog entry registers a buggy PSReadLine key handler whose
# scriptblock references a non-existent property and therefore breaks Tab
# completion globally), Register-CliCompletion must:
#   - call `psc remove <cli>` to undo the catalog change
#   - return Action='Failed' with the reason
#   - NOT write the sentinel block into the profile
# ----------------------------------------------------------------------------

Describe 'Register-CliCompletion PSCompletions validation + rollback' -Tag 'Light','PSCompletionsRollback' {

    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force }
        else { Import-Module MarkMichaelis.ScoopBucket -Force }

        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("RCC-rb-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:sandbox) {
            Remove-Item -Path $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rolls back via psc remove and reports Action=Failed when validation fails' {
        $profile = Join-Path $script:sandbox 'profile-fail.ps1'
        $script:pscRemoveCalled = $false
        $script:pscRemoveCli = $null

        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-CliCompletionSource {
            @{ Source = 'PSCompletions'; Code = '# stub'; PSCompletionsName = $Cli }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Import-Module { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PscAdd { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PscRemove {
            param($Cli)
            $script:pscRemoveCalled = $true
            $script:pscRemoveCli = $Cli
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PSCompletionsHandler {
            [pscustomobject]@{ Ok = $false; Reason = "The property 'buffer' cannot be found on this object." }
        }

        $result = Register-CliCompletion -Cli 'borkcli' -ProfilePath $profile -Confirm:$false -WarningAction SilentlyContinue
        $result.Action      | Should -Be 'Failed'
        $result.Source      | Should -Be 'PSCompletions'
        $result.Reason      | Should -Match 'buffer'
        $script:pscRemoveCalled | Should -Be $true
        $script:pscRemoveCli    | Should -Be 'borkcli'
        (Test-Path $profile)    | Should -Be $false
    }

    It 'writes the sentinel block when validation passes' {
        $profile = Join-Path $script:sandbox 'profile-ok.ps1'

        Mock -ModuleName MarkMichaelis.ScoopBucket Resolve-CliCompletionSource {
            @{ Source = 'PSCompletions'; Code = '# stub OK'; PSCompletionsName = $Cli }
        }
        Mock -ModuleName MarkMichaelis.ScoopBucket Import-Module { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PscAdd { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PscRemove { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PSCompletionsHandler {
            [pscustomobject]@{ Ok = $true; Reason = $null }
        }

        $result = Register-CliCompletion -Cli 'goodcli' -ProfilePath $profile -Confirm:$false
        $result.Action | Should -Be 'Added'
        (Test-Path $profile) | Should -Be $true
        (Get-Content $profile -Raw) | Should -Match 'ScoopBucket:CliCompletion:goodcli:BEGIN'
    }
}
