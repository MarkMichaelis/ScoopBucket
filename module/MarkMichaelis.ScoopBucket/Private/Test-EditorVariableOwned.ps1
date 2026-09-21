# Ownership test for the EDITOR environment variable (#419).
#
# Set-DefaultEditorVariable only claims EDITOR when nobody else has. This
# decides "nobody else": the value is ours when the command it invokes is
# `code` -- bare, with a .cmd/.exe suffix, or as a full path.
#
# Deliberately does NOT match `code-insiders`: that is a different editor
# someone chose on purpose, and a package install must not revert it.

function Test-EditorVariableOwned {
    <#
    .SYNOPSIS
        Is this EDITOR value one that VS Code owns?
    .PARAMETER Value
        The EDITOR value to classify.
    .OUTPUTS
        Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Value)

    if (-not $Value) { return $false }
    $trimmed = $Value.Trim()

    # An EDITOR value can spell the command three ways, and the middle one is
    # why a single split is not enough: an UNQUOTED install path contains
    # spaces, so the first whitespace token is 'C:\Program', not the command.
    #   "C:\...\code.cmd" --wait   -> the quoted first token
    #   C:\Program Files\...\code.cmd --wait -> everything before the first switch
    #   code --wait                -> the first whitespace token
    # Any candidate naming `code` means the value is ours.
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($trimmed -match '^"([^"]+)"') { $candidates.Add($Matches[1]) }
    $switchAt = $trimmed.IndexOf(' -')
    if ($switchAt -gt 0) { $candidates.Add($trimmed.Substring(0, $switchAt).Trim()) }
    $candidates.Add(($trimmed -split '\s+', 2)[0])

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ([IO.Path]::GetFileNameWithoutExtension($candidate.Trim('"')) -ieq 'code') { return $true }
    }
    return $false
}
