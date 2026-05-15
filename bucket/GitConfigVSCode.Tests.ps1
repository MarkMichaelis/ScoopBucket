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

    It 'adds an alias.dtv shortcut when VS Code is configured' {
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
}
