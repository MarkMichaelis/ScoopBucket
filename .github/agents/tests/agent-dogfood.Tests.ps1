<#
.SYNOPSIS
    Structural Pester tests for the api-wrapper-scaffold dogfood (issue #58 / epic #34).

.DESCRIPTION
    These tests DO NOT run the dogfood -- the dogfood is a manual / out-of-band
    invocation that writes outside the repo (see scripts/run-dogfood.ps1 and
    docs/dogfood/tripit-dry-run-report.md). What we assert here is that the
    committable scaffolding around the dogfood remains intact:

      * The canonical report file exists and has every required section.
      * The reproducer script exists, is syntactically valid PowerShell, and
        exposes the documented parameter contract.
      * The report's verdict is explicit (the word "Verdict" appears).
      * The report's endpoint coverage table has at least one row.
      * The report does not embed real user data (no @real-domain emails, no
        bearer-token-shaped strings).
#>

BeforeAll {
    $repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $script:ReportPath = Join-Path $repoRoot 'docs/dogfood/tripit-dry-run-report.md'
    $script:ScriptPath = Join-Path $repoRoot 'scripts/run-dogfood.ps1'
}

Describe 'agent-dogfood: canonical report' {
    It 'docs/dogfood/tripit-dry-run-report.md exists' {
        Test-Path $script:ReportPath | Should -BeTrue
    }

    Context 'when the report exists' {
        BeforeAll {
            $script:ReportText = Get-Content $script:ReportPath -Raw
        }

        It 'has an Executive Summary section' {
            $script:ReportText | Should -Match '(?m)^##\s+Executive Summary'
        }
        It 'has a Run Conditions section' {
            $script:ReportText | Should -Match '(?m)^##\s+Run Conditions'
        }
        It 'has a Pipeline Stage Outputs section' {
            $script:ReportText | Should -Match '(?m)^##\s+Pipeline Stage Outputs'
        }
        It 'has an Endpoint Coverage section' {
            $script:ReportText | Should -Match '(?m)^##\s+Endpoint Coverage'
        }
        It 'has a Build / Test Results section' {
            $script:ReportText | Should -Match '(?m)^##\s+Build / Test Results'
        }
        It 'has a Verdict section with an explicit verdict' {
            $script:ReportText | Should -Match '(?m)^##\s+Verdict:'
        }
        It 'has a Follow-up Issues section' {
            $script:ReportText | Should -Match '(?m)^##\s+Follow-up Issues'
        }
        It 'has a Data Hygiene appendix' {
            $script:ReportText | Should -Match '(?m)^##\s+Appendix A: Data Hygiene'
        }
        It 'has an Epic #34 Completion appendix referencing all prior PRs' {
            $script:ReportText | Should -Match '(?m)^##\s+Appendix C: Epic #34 Completion'
            foreach ($pr in @('#35','#37','#39','#41','#43','#45','#47','#49','#51','#53','#55','#57')) {
                $script:ReportText | Should -Match ([regex]::Escape($pr))
            }
        }
        It 'has at least one row in the endpoint coverage table' {
            # A data row in the coverage table contains a literal /api/ path segment.
            $script:ReportText | Should -Match '\|\s*`?/api/'
        }
        It 'does not embed real-looking TripIt user emails' {
            # Allow only example.invalid / @example. domains.
            $script:ReportText | Should -Not -Match '@(tripit|gmail|outlook|hotmail|yahoo)\.com'
        }
        It 'does not embed bearer-JWT-shaped strings' {
            $script:ReportText | Should -Not -Match 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
        }
    }
}

Describe 'agent-dogfood: run-dogfood.ps1 reproducer' {
    It 'scripts/run-dogfood.ps1 exists' {
        Test-Path $script:ScriptPath | Should -BeTrue
    }

    It 'parses as valid PowerShell' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    Context 'parameter contract' {
        BeforeAll {
            $tokens = $null; $errors = $null
            $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$tokens, [ref]$errors)
            $script:ParamBlock = $script:Ast.ParamBlock
            $script:ParamNames = @($script:ParamBlock.Parameters | ForEach-Object {
                $_.Name.VariablePath.UserPath })
        }

        It 'declares -StorageState' { $script:ParamNames | Should -Contain 'StorageState' }
        It 'declares -Reference'    { $script:ParamNames | Should -Contain 'Reference' }
        It 'declares -Out'          { $script:ParamNames | Should -Contain 'Out' }
        It 'declares -Mode'         { $script:ParamNames | Should -Contain 'Mode' }
        It 'declares -ReportPath'   { $script:ParamNames | Should -Contain 'ReportPath' }

        It 'makes -Reference mandatory' {
            $refParam = $script:ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'Reference' }
            $paramAttr = $refParam.Attributes |
                Where-Object { $_.TypeName.Name -eq 'Parameter' }
            $mandatoryArg = $paramAttr.NamedArguments |
                Where-Object { $_.ArgumentName -eq 'Mandatory' }
            $mandatoryArg | Should -Not -BeNullOrEmpty
            # Argument may be a VariableExpression ($true) or a ConstantExpression -- both have .Extent.Text.
            $mandatoryArg.Argument.Extent.Text | Should -Match '\$true'
        }

        It '-Mode is constrained to auto/live/synthetic' {
            $modeParam = $script:ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
            $validateSet = $modeParam.Attributes |
                Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
            $values = $validateSet.PositionalArguments | ForEach-Object { $_.Value }
            $values | Should -Contain 'auto'
            $values | Should -Contain 'live'
            $values | Should -Contain 'synthetic'
        }
    }

    It 'writes outputs OUTSIDE the repo by default ($env:TEMP)' {
        # The default -Out value must reference $env:TEMP, not anything under the repo.
        $text = Get-Content $script:ScriptPath -Raw
        $text | Should -Match '\$env:TEMP'
        # And the default Out must not point inside the repo.
        $text | Should -Not -Match '-Out\s+\$repoRoot'
    }

    It 'passes --no-sdlc to run-agent (non-interactive contract from PR #57)' {
        (Get-Content $script:ScriptPath -Raw) | Should -Match '--no-sdlc'
    }
}

Describe 'agent-dogfood: .gitignore hygiene' {
    BeforeAll {
        $script:GitignorePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path '.gitignore'
        $script:Gitignore = Get-Content $script:GitignorePath -Raw
    }

    It 'ignores Samples/HAR-Original/ (real-cookie-bearing captures)' {
        $script:Gitignore | Should -Match '(?m)^Samples/HAR-Original/'
    }

    It 'ignores .dogfood-output/ (convenience default for run-dogfood.ps1)' {
        $script:Gitignore | Should -Match '(?m)^\.dogfood-output/'
    }
}
