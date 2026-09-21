# Read seam for the EDITOR environment variable (#419).
#
# Set-DefaultEditorVariable's whole job is deciding what to do about the value
# it finds, so every interesting branch depends on what the read returns. A
# direct [Environment]::GetEnvironmentVariable call would make those branches
# reachable only on a host that happens to already be in the right state --
# which is how the "another editor owns the machine-scope value" case ended up
# untestable, and silently skipped on any machine where this hook had already
# run.
#
# Routing the read through a function makes every branch deterministic under
# test (Mock it) while production behavior is unchanged.

function Get-EditorVariable {
    <#
    .SYNOPSIS
        Read the EDITOR environment variable from one scope.
    .PARAMETER Scope
        'Machine' or 'Process'.
    .OUTPUTS
        String (or $null when unset).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('Machine', 'Process')]
        [string]$Scope
    )

    return [Environment]::GetEnvironmentVariable('EDITOR', $Scope)
}
