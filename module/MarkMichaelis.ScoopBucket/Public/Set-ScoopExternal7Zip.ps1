function Set-ScoopExternal7Zip {
    <#
    .SYNOPSIS
        Tell scoop to extract with the 7z already on PATH instead of installing
        its own main/7zip -- but only when that 7z is not scoop's.

    .DESCRIPTION
        Scoop installs main/7zip on demand whenever a manifest needs 7z
        extraction, and its 7z shim then shadows the winget 7-Zip package.
        Setting scoop's use_external_7zip stops that (#518).

        The flag is only safe when a non-scoop 7z answers on PATH: with it set
        and no 7z to find, scoop aborts every 7z extraction instead of
        installing its own helper. So when the only 7z is scoop's, or there is
        none, the flag is left unchanged and a warning says why.

        Run as the 7-Zip package ConfigScript, so it is re-applied on every
        install and update. Idempotent. It is public because scoop runs a
        bundle script outside the module, where a ConfigScript can only call
        exported functions (#524).

        Uninstalling 7-Zip leaves the flag set; `scoop config rm
        use_external_7zip` restores scoop's own 7zip.

    .OUTPUTS
        PSCustomObject -- Path (the 7z found, or $null), Owner (the engine that
        owns it, or $null), Action: Set or Skipped.

    .EXAMPLE
        Set-ScoopExternal7Zip -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param()

    $path  = Get-CommandSourcePath -Cli '7z'
    $owner = if ($path) { Resolve-PathOwningEngine -Path $path -EngineRoot (Get-EngineRootMap) }

    $action = 'Skipped'
    if (-not $path -or $owner -eq 'scoop') {
        Write-Warning "7-Zip: no non-scoop 7z on PATH (found '$path'); leaving scoop's use_external_7zip unchanged."
    }
    elseif ($PSCmdlet.ShouldProcess('scoop config use_external_7zip', 'Set to true')) {
        # scoop prints a confirmation line; keep it out of the result.
        $null = scoop config use_external_7zip true
        $action = 'Set'
    }

    [pscustomobject]@{ Path = $path; Owner = $owner; Action = $action }
}
