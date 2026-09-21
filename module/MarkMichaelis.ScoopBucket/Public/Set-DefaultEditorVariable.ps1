function Set-DefaultEditorVariable {
    <#
    .SYNOPSIS
        Point the EDITOR environment variable at VS Code, without stealing it
        from an editor the user deliberately chose.

    .DESCRIPTION
        EDITOR is the fallback every CLI tool reaches for when it needs the user
        to edit a file: git with no core.editor, npm, gh, and most POSIX-minded
        tooling. `--wait` is mandatory -- plain `code` forks and returns
        immediately, so the caller reads back a file the user has not finished
        editing yet.

        Run as the Visual Studio Code package ConfigScript (#419), so it is
        re-applied on every install AND every update, and is idempotent -- a
        re-run changes nothing.

        OWNERSHIP. The variable is only claimed when it is unset, or when it
        already points at VS Code (see Test-EditorVariableOwned):

          * unset         -> set it.
          * `code ...`    -> ours; normalized to the desired value. A bare
                             `code` with no --wait is the classic broken
                             setting, so rewriting it is a fix, not a clobber.
          * anything else -> left alone, and reported. `vim`, `nano`,
                             `code-insiders --wait` and friends are deliberate
                             choices a package install must not revert.

        This mirrors how the other desired-state hooks in this module behave
        (Import-WindowsTerminalSettings, Import-PowerToysSettings): merge with
        what the user has rather than overwrite it.

        ELEVATION. Machine scope needs admin. An unelevated run warns instead of
        throwing, so the package is not marked Failed.

        SESSION MIRROR. Whenever the variable is ours to set, $env:EDITOR is
        also set for the running session -- including when the machine-scope
        write was skipped for lack of elevation -- so the first `git commit`
        after an install opens VS Code without needing a fresh shell. When
        another editor owns the value, the session is left alone too.

    .PARAMETER Command
        The editor command line to install. Defaults to 'code --wait'.

    .PARAMETER Scope
        Which environment scope to write. 'Machine' (the default) is the
        machine-wide value that services, scheduled tasks and every account
        inherit. 'Process' writes only the current process, which is what the
        tests use so they can exercise the full decision without touching the
        host (and which therefore performs no session mirror of its own).

    .OUTPUTS
        PSCustomObject -- Scope, Previous, Value, Action. Action is one of:
          Set       -- the variable was written.
          Unchanged -- already exactly the desired value.
          Kept      -- another editor owns it; nothing was written.
          Skipped   -- a write was needed but did not happen (not elevated,
                       or -WhatIf).

    .EXAMPLE
        Set-DefaultEditorVariable -WhatIf
        Shows what would change without writing anything.

    .EXAMPLE
        Set-DefaultEditorVariable -Scope Process
        Applies the same decision to the current process only.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Command = 'code --wait',

        [ValidateSet('Machine', 'Process')]
        [string]$Scope = 'Machine'
    )

    $current = [Environment]::GetEnvironmentVariable('EDITOR', $Scope)

    if ($current -and -not (Test-EditorVariableOwned -Value $current)) {
        Write-Host "EDITOR ($Scope) is '$current'; leaving it alone. Set it to '$Command' by hand to use VS Code."
        return [pscustomobject]@{
            Scope = $Scope; Previous = $current; Value = $Command; Action = 'Kept'
        }
    }

    $action = 'Unchanged'
    if ($current -ne $Command) {
        if ($Scope -eq 'Machine' -and -not (Test-IsElevated)) {
            Write-Warning "Cannot set EDITOR to '$Command' machine-wide: this session is not elevated. Re-run Update-Package 'Visual Studio Code' from an admin shell."
            $action = 'Skipped'
        }
        elseif ($PSCmdlet.ShouldProcess("EDITOR ($Scope)", "Set to '$Command'")) {
            [Environment]::SetEnvironmentVariable('EDITOR', $Command, $Scope)
            if ($current) { Write-Host "EDITOR ($Scope): '$current' -> '$Command'." }
            else          { Write-Host "EDITOR ($Scope) set to '$Command'." }
            $action = 'Set'
        }
        else {
            $action = 'Skipped'
        }
    }

    if ($Scope -ne 'Process' -and $PSCmdlet.ShouldProcess('EDITOR (current session)', "Set to '$Command'")) {
        $env:EDITOR = $Command
    }

    return [pscustomobject]@{
        Scope = $Scope; Previous = $current; Value = $Command; Action = $action
    }
}
