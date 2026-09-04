$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install' {
    BeforeAll {
        # Re-derive rather than closing over the discovery-phase $name: at run
        # phase Pester evaluates BeforeAll in a fresh scope where $PSCommandPath
        # (and therefore the file-scoped $name) is empty.
        $script:name = 'GitConfigGitHubCli'

        if (Test-ScoopPackageInstalled $script:name) {
            scoop uninstall $script:name
        }

        # `gh iv` reads the issue from whichever repo the working directory
        # resolves to, so every alias invocation below runs from the bucket
        # checkout. Pester's working directory is not guaranteed otherwise.
        $script:ghAvailable = [bool](Get-Command gh -ErrorAction Ignore)
        $script:ghAuthed = $false
        $script:probeIssue = $null
        if ($script:ghAvailable) {
            Push-Location $PSScriptRoot
            try {
                gh auth status *>$null
                $script:ghAuthed = ($LASTEXITCODE -eq 0)
                if ($script:ghAuthed) {
                    # Any issue will do; --state all so a fully triaged repo
                    # still yields a probe target.
                    $script:probeIssue = (gh issue list --state all --limit 1 --json number --jq '.[0].number' 2>$null)
                }
            }
            finally { Pop-Location }
        }
    }

    It 'installs from the local manifest' {
        Install-LocalManifest "$PSScriptRoot\$($script:name).json"
        Test-ScoopPackageInstalled $script:name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$($script:name).json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $script:name | Should -Be $true
    }

    It 'ships gh-aliases.yml alongside the configurator' {
        . "$PSScriptRoot\GitConfigGitHubCli.ps1" *>$null
        Resolve-GhAliasFile | Should -Not -BeNullOrEmpty
    }

    It 'imports gh-aliases.yml into an isolated gh config without error' {
        if (-not $script:ghAvailable) {
            Set-ItResult -Skipped -Because 'gh not installed'
            return
        }
        # GH_CONFIG_DIR sandboxes the import so the assertion never mutates the
        # developer's real %APPDATA%\GitHub CLI\config.yml.
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("gh-alias-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        $prior = $env:GH_CONFIG_DIR
        try {
            $env:GH_CONFIG_DIR = $sandbox
            gh alias import "$PSScriptRoot\gh-aliases.yml" --clobber *>$null
            $LASTEXITCODE | Should -Be 0
            (gh alias list) -join "`n" | Should -Match '(?m)^iv:'
        }
        finally {
            $env:GH_CONFIG_DIR = $prior
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Ignore
        }
    }

    It 'executes gh iv with an issue number and emits the compact title line' {
        if (-not $script:ghAuthed) {
            Set-ItResult -Skipped -Because 'gh not installed or not authenticated'
            return
        }
        if (-not $script:probeIssue) {
            Set-ItResult -Skipped -Because 'no issues in this repo to probe'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $out = gh iv $script:probeIssue
            $LASTEXITCODE | Should -Be 0
            ($out -join "`n") | Should -Match "^#$($script:probeIssue) \S"
        }
        finally { Pop-Location }
    }

    It 'accepts a leading # on the issue number' {
        if (-not $script:ghAuthed -or -not $script:probeIssue) {
            Set-ItResult -Skipped -Because 'gh not authenticated or no issues to probe'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $out = gh iv "#$($script:probeIssue)"
            $LASTEXITCODE | Should -Be 0
            ($out -join "`n") | Should -Match "^#$($script:probeIssue) \S"
        }
        finally { Pop-Location }
    }

    It 'executes gh iv -s and adds a body summary line' {
        if (-not $script:ghAuthed -or -not $script:probeIssue) {
            Set-ItResult -Skipped -Because 'gh not authenticated or no issues to probe'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $out = @(gh iv $script:probeIssue -s)
            $LASTEXITCODE | Should -Be 0
            # Title line plus at least one summary line -- the summary branch
            # emits "(no body)" rather than nothing when the issue has no body.
            $out.Count | Should -BeGreaterOrEqual 2
            $out[0] | Should -Match "^#$($script:probeIssue) \S"
            $out[1] | Should -Not -BeNullOrEmpty
        }
        finally { Pop-Location }
    }

    It 'exits 2 with a usage message when no issue number is given' {
        if (-not $script:ghAvailable) {
            Set-ItResult -Skipped -Because 'gh not installed'
            return
        }
        Push-Location $PSScriptRoot
        try {
            $err = (gh iv 2>&1) -join "`n"
            $LASTEXITCODE | Should -Be 2
            $err | Should -Match 'usage: gh iv'
        }
        finally { Pop-Location }
    }
}
