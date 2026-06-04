
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }


Function Resolve-VSCodeCommand {
    # Returns the command line git should use to launch VS Code as a diff /
    # merge tool, or $null when VS Code isn't reachable. Probe order:
    #   1. `code` on PATH (winget / chocolatey / Scoop System install)
    #   2. `code-insiders` on PATH (insiders build only)
    #   3. Default winget/Chocolatey install dirs under
    #      %ProgramFiles%\Microsoft VS Code and
    #      %LOCALAPPDATA%\Programs\Microsoft VS Code
    # The returned value is the launcher to be quoted into a git `*.cmd`
    # config string — typically just `code` so PATH resolution wins on every
    # subsequent shell, but falls back to an absolute path when needed.
    [CmdletBinding()]
    param()
    foreach ($name in 'code', 'code-insiders') {
        $cmd = Get-Command $name -ErrorAction Ignore
        if ($cmd) { return $name }
    }
    $candidates = @(
        (Join-Path $env:ProgramFiles            'Microsoft VS Code\bin\code.cmd'),
        (Join-Path ${env:ProgramFiles(x86)}     'Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:LOCALAPPDATA            'Programs\Microsoft VS Code\bin\code.cmd')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

Function Invoke-GitConfigVSCode {
    if (-not (Get-Command git -ErrorAction Ignore)) {
        Write-Warning "git not found. Skipping VS Code git configuration."
        return
    }
    $code = Resolve-VSCodeCommand
    if (-not $code) {
        Write-Warning "VS Code (code / code-insiders) not found. Skipping git configuration."
        return
    }

    # Quote the launcher so paths with spaces survive git's shell expansion.
    # --wait is essential: git polls the caller's exit code, but `code` is a
    # shim that returns immediately without --wait, breaking the workflow.
    $launcher = if ($code -match '\s') { "`"$code`"" } else { $code }
    $diffCmd  = "$launcher --wait --new-window --diff `"`$LOCAL`" `"`$REMOTE`""
    $mergeCmd = "$launcher --wait --merge `"`$REMOTE`" `"`$LOCAL`" `"`$BASE`" `"`$MERGED`""

    # Always register the `vscode` tool config so it's available on demand
    # via `git difftool --tool=vscode` -- this is the BLOCKING flavour
    # (uses --wait so git waits for the VS Code tab to close before cleaning
    # up its temp files). It's the right choice for scripted/CI workflows.
    git config --global difftool.vscode.cmd          $diffCmd
    git config --global difftool.vscode.trustExitCode true
    git config --global mergetool.vscode.cmd         $mergeCmd
    git config --global mergetool.vscode.trustExitCode true
    git config --global mergetool.vscode.keepBackup  false

    # `git dtv` -- explicit blocking VS Code difftool invocation; doesn't
    # require touching the global diff.tool default (Beyond Compare).
    git config --global alias.dtv 'difftool --tool=vscode'

    # `git diffcode` -- NON-BLOCKING VS Code diff against HEAD (or --staged).
    # Bypasses git's tempfile lifecycle by dumping HEAD/index blobs to
    # %TEMP%\diffcode\ ourselves and launching `code --diff` without --wait,
    # so the shell returns immediately while VS Code stays open. The helper
    # script lives in the same Scoop app dir as this configurator; we hard-
    # code its absolute path into the alias at install time so PATH state
    # never breaks the alias.
    $helper = Join-Path $PSScriptRoot 'Invoke-GitDiffCode.ps1'
    if (Test-Path $helper) {
        # Forward-slashes survive git-config's quoting on Windows better than
        # backslashes; pwsh accepts either.
        $helperPosix = $helper -replace '\\', '/'
        git config --global alias.diffcode ("!pwsh -NoProfile -File '" + $helperPosix + "' --")
    } else {
        Write-Warning "Invoke-GitDiffCode.ps1 not found alongside GitConfigVSCode.ps1; skipping diffcode alias."
    }

    Write-Host "VS Code configured for git diff/merge: $code"
}
Invoke-GitConfigVSCode
