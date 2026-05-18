#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# Tests for Publish-Evidence.ps1 -- the gh-invocation helper used by the
# evidence-capture skill. These are behavior-first tests: each one ships with
# the helper and verifies the observable outcome (the gh args passed and the
# returned object), not the internal layout of the script.

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\helpers\Publish-Evidence.ps1' |
        Resolve-Path | Select-Object -ExpandProperty Path
    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "publish-evidence-tests-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force
    }
}

Describe 'Publish-Evidence' {

    Context 'when artifact is a small markdown file' {
        It 'classifies the mode as Inline' {
            $artifact = Join-Path $script:TempDir 'evidence.md'
            Set-Content -LiteralPath $artifact -Value "# Evidence`r`n`r`nHello." -NoNewline

            $captured = @()
            $stub = { param([string[]]$GhArgs) $captured += , $GhArgs }

            $result = & $script:ScriptPath -ArtifactPath $artifact -PullRequest 42 -GhInvoker $stub

            $result.Mode | Should -Be 'Inline'
        }

        It 'posts the markdown content as the comment body' {
            $artifact = Join-Path $script:TempDir 'evidence2.md'
            $content = "# Evidence`r`n`r`nThe button now says Submit."
            Set-Content -LiteralPath $artifact -Value $content -NoNewline

            $bag = @{}
            $stub = { param([string[]]$GhArgs) $bag['args'] = $GhArgs }.GetNewClosure()

            & $script:ScriptPath -ArtifactPath $artifact -PullRequest 42 -GhInvoker $stub | Out-Null

            $bag['args'][0] | Should -Be 'pr'
            $bag['args'][1] | Should -Be 'comment'
            $bag['args'][2] | Should -Be '42'
            $bag['args'][3] | Should -Be '--body-file'
        }

        It 'returns the markdown content verbatim in the Comment property' {
            $artifact = Join-Path $script:TempDir 'evidence3.md'
            $content = "# Title`r`n`r`nSome body text with **bold**."
            Set-Content -LiteralPath $artifact -Value $content -NoNewline

            $stub = { param([string[]]$GhArgs) }

            $result = & $script:ScriptPath -ArtifactPath $artifact -PullRequest 7 -GhInvoker $stub

            $result.Comment | Should -Be $content
        }

        It 'passes --repo when Repo parameter is provided' {
            $artifact = Join-Path $script:TempDir 'evidence4.md'
            Set-Content -LiteralPath $artifact -Value '# X' -NoNewline

            $bag = @{}
            $stub = { param([string[]]$GhArgs) $bag['args'] = $GhArgs }.GetNewClosure()

            & $script:ScriptPath -ArtifactPath $artifact -PullRequest 7 `
                -Repo 'foo/bar' -GhInvoker $stub | Out-Null

            $bag['args'] | Should -Contain '--repo'
            $bag['args'] | Should -Contain 'foo/bar'
        }
    }

    Context 'when artifact is a binary file' {
        It 'classifies the mode as ArtifactReference for .png' {
            $artifact = Join-Path $script:TempDir 'screenshot.png'
            [System.IO.File]::WriteAllBytes($artifact, [byte[]](137,80,78,71,13,10,26,10))

            $stub = { param([string[]]$GhArgs) }

            $result = & $script:ScriptPath -ArtifactPath $artifact -PullRequest 9 -GhInvoker $stub

            $result.Mode | Should -Be 'ArtifactReference'
        }

        It 'produces a reference comment that names the artifact' {
            $artifact = Join-Path $script:TempDir 'recording.mp4'
            [System.IO.File]::WriteAllBytes($artifact, [byte[]](0,0,0,1))

            $stub = { param([string[]]$GhArgs) }

            $result = & $script:ScriptPath -ArtifactPath $artifact -PullRequest 9 -GhInvoker $stub

            $result.Comment | Should -Match 'recording.mp4'
            $result.Comment | Should -Match 'CI workflow artifacts'
        }

        It 'classifies the mode as ArtifactReference for HTML' {
            $artifact = Join-Path $script:TempDir 'ui.html'
            Set-Content -LiteralPath $artifact -Value '<html></html>' -NoNewline

            $stub = { param([string[]]$GhArgs) }

            $result = & $script:ScriptPath -ArtifactPath $artifact -PullRequest 9 -GhInvoker $stub

            $result.Mode | Should -Be 'ArtifactReference'
        }
    }

    Context 'when markdown exceeds the inline size limit' {
        It 'falls back to ArtifactReference mode' {
            $artifact = Join-Path $script:TempDir 'big.md'
            # Generate ~2 KB of content, with a tiny inline limit to force fallback.
            Set-Content -LiteralPath $artifact -Value ('# Big' + ("`r`nline" * 200)) -NoNewline

            $stub = { param([string[]]$GhArgs) }

            $result = & $script:ScriptPath -ArtifactPath $artifact -PullRequest 1 `
                -MaxInlineSizeBytes 100 -GhInvoker $stub

            $result.Mode | Should -Be 'ArtifactReference'
        }
    }

    Context 'when given -WhatIf' {
        It 'does not invoke gh' {
            $artifact = Join-Path $script:TempDir 'whatif.md'
            Set-Content -LiteralPath $artifact -Value '# Whatif' -NoNewline

            $bag = @{ count = 0 }
            $stub = { param([string[]]$GhArgs) $bag['count'] = $bag['count'] + 1 }.GetNewClosure()

            & $script:ScriptPath -ArtifactPath $artifact -PullRequest 5 `
                -GhInvoker $stub -WhatIf | Out-Null

            $bag['count'] | Should -Be 0
        }
    }

    Context 'when the artifact path does not exist' {
        It 'throws' {
            $stub = { param([string[]]$GhArgs) }
            $missing = Join-Path $script:TempDir 'does-not-exist.md'

            { & $script:ScriptPath -ArtifactPath $missing -PullRequest 1 -GhInvoker $stub } |
                Should -Throw
        }
    }
}
