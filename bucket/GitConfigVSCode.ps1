
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
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
    # via `git difftool --tool=vscode`, regardless of which tool is default.
    git config --global difftool.vscode.cmd          $diffCmd
    git config --global difftool.vscode.trustExitCode true
    git config --global mergetool.vscode.cmd         $mergeCmd
    git config --global mergetool.vscode.trustExitCode true
    git config --global mergetool.vscode.keepBackup  false

    # First-writer-wins for the global default so install order doesn't
    # silently flip a deliberately-chosen tool. To switch defaults manually:
    #   git config --global diff.tool vscode
    #   git config --global merge.tool vscode
    if (-not (git config --global --get diff.tool))  { git config --global diff.tool  vscode }
    if (-not (git config --global --get merge.tool)) { git config --global merge.tool vscode }

    # Aliases — `dt` honors the current default; `dtv` always uses VS Code
    # explicitly so the user can invoke either without changing the default.
    if (-not (git config --global --get alias.dt))   { git config --global alias.dt 'difftool' }
    git config --global alias.dtv 'difftool --tool=vscode'

    Write-Host "VS Code configured for git diff/merge: $code"
}
Invoke-GitConfigVSCode
