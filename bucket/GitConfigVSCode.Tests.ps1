$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

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

    It 'registers the vscode difftool when VS Code is installed' {
        . "$PSScriptRoot\GitConfigVSCode.ps1" *>$null
        $code = Resolve-VSCodeCommand
        if (-not $code) {
            Set-ItResult -Skipped -Because 'VS Code not installed on this runner'
            return
        }
        $diffCmd  = git config --global difftool.vscode.cmd
        $mergeCmd = git config --global mergetool.vscode.cmd
        $diffCmd  | Should -Match '--wait'
        $diffCmd  | Should -Match '--diff'
        $mergeCmd | Should -Match '--wait'
        $mergeCmd | Should -Match '--merge'
    }

    It 'does not override diff.tool when Beyond Compare is the default' {
        . "$PSScriptRoot\GitConfigVSCode.ps1" *>$null
        $code = Resolve-VSCodeCommand
        if (-not $code) {
            Set-ItResult -Skipped -Because 'VS Code not installed on this runner'
            return
        }
        # GitConfigVSCode registers explicit aliases (dtv / diffcode) and the
        # `vscode` tool config but must leave diff.tool / merge.tool alone --
        # Beyond Compare owns the project-wide default.
        $tool = git config --global diff.tool
        if ($tool) { $tool | Should -Not -Be 'vscode' }
    }

    It 'adds a non-blocking diffcode alias when VS Code is configured' {
        . "$PSScriptRoot\GitConfigVSCode.ps1" *>$null
        $code = Resolve-VSCodeCommand
        if (-not $code) {
            Set-ItResult -Skipped -Because 'VS Code not installed on this runner'
            return
        }
        $alias = git config --global alias.diffcode
        $alias | Should -Match 'Invoke-GitDiffCode\.ps1'
        $alias | Should -Match '^!pwsh'
    }

    It 'adds an alias.dtv blocking shortcut when VS Code is configured' {
        . "$PSScriptRoot\GitConfigVSCode.ps1" *>$null
        $code = Resolve-VSCodeCommand
        if (-not $code) {
            Set-ItResult -Skipped -Because 'VS Code not installed on this runner'
            return
        }
        $alias = git config --global alias.dtv
        $alias | Should -Match 'difftool .*--tool=vscode'
    }
}

Describe "Behaviour $name (unit)" -Tag 'Light', 'Unit' {
    It 'Resolve-VSCodeCommand returns a launcher path or $null without throwing' {
        . "$PSScriptRoot\GitConfigVSCode.ps1" *>$null
        { Resolve-VSCodeCommand } | Should -Not -Throw
        # The launcher is either a bare command name or an existing file.
        $r = Resolve-VSCodeCommand
        if ($r) {
            ($r -match '^[\w-]+$') -or (Test-Path $r) | Should -Be $true
        }
    }

    It 'ships Invoke-GitDiffCode.ps1 alongside GitConfigVSCode.ps1' {
        # The diffcode alias is wired to this exact filename at install
        # time; it must remain in the bucket so the Scoop manifest URL list
        # keeps shipping it into the app dir.
        Test-Path (Join-Path $PSScriptRoot 'Invoke-GitDiffCode.ps1') | Should -Be $true
    }

    It 'Invoke-GitDiffCode.ps1 parses without syntax errors' {
        $path = Join-Path $PSScriptRoot 'Invoke-GitDiffCode.ps1'
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}
