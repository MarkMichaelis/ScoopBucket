function Register-PackageNameCompleter {
    <#
    .SYNOPSIS
        Internal: register an argument completer for the -Name parameter
        of Install-Package and Get-Package so the user can Tab-complete
        package names declared anywhere in the bucket without having to
        remember exact spelling.

    .DESCRIPTION
        Called from the module's root .psm1 at load time. Idempotent.
        Suggestions are produced by Get-PackageNameSuggestion, which
        regex-scans bucket/*.ps1 and caches results until a bundle file
        is touched.
    #>
    [CmdletBinding()]
    param()

    $scriptBlock = {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        try {
            $suggestions = Get-PackageNameSuggestion -WordToComplete $wordToComplete
        } catch {
            return
        }
        foreach ($name in $suggestions) {
            # Quote names that contain whitespace (or apostrophes) so
            # PowerShell parses them as a single argument. Inside a
            # single-quoted string, an embedded `'` must be escaped as
            # `''` per the PowerShell language spec — without that,
            # completing a name like O'Reilly produces a parse error
            # the moment the user accepts the suggestion.
            if ($name -match "[\s']") {
                $escaped = $name -replace "'", "''"
                $completionText = "'$escaped'"
            } else {
                $completionText = $name
            }
            [System.Management.Automation.CompletionResult]::new(
                $completionText,
                $name,
                'ParameterValue',
                $name
            )
        }
    }

    Register-ArgumentCompleter -CommandName 'Install-Package','Get-Package','Update-Package','Uninstall-Package' -ParameterName 'Name' -ScriptBlock $scriptBlock
}
