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
            # Quote names that contain whitespace so PowerShell parses
            # them as a single argument.
            if ($name -match '\s') {
                $completionText = "'$name'"
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

    Register-ArgumentCompleter -CommandName 'Install-Package','Get-Package' -ParameterName 'Name' -ScriptBlock $scriptBlock
}
