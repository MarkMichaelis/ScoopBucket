#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the owner rulings on the #465 engine audit.

.DESCRIPTION
    #465 audited every package against the README's installation engine
    preference (winget > scoop > choco) and left four entries for the owner to
    rule on rather than guessing. The rulings are now declarations, and this
    file pins them -- including the one that says "stay where you are", because
    an undefended exception is exactly how `rclone` went wrong in #462/#463:
    the next auditor sees choco, applies rule 1, and silently downgrades.

    exiftool -> winget (OliverBetz.ExifTool 13.59)
        Same software and the same version as choco's 13.59.0, with a
        machine-scope inno installer, so rule 3 (choco = last resort) no
        longer applies. The two packages come from different repackagers of
        Phil Harvey's ExifTool, which is why this needed a ruling.

    Notion -> winget (Notion.Notion 7.36.1)
        Same version as scoop's extras/notion. The owner accepted the MSIX
        packaging shape at machine scope, which is the thing that differs from
        the scoop install it replaces:

            PS> winget show --id Notion.Notion --exact --scope machine
            Installer Type: msix

    Node.js -> STAYS on choco (nodejs)
        The deliberate exception. Rule 2's "when winget lacks the package"
        extends to materially lagging it, and winget does lag:
        choco 26.10.0 against winget OpenJS.NodeJS 26.7.0 (or LTS 24.19.0) as
        observed 2026-10-03. Moving would be a downgrade, and every npx-based
        MCP server in AIAgents depends on this entry. The assertion below is
        the guard that keeps a future audit from "fixing" it.

    Tagged 'Light' -- harvests declarative [Package] entries; no install side
    effects.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)

    $script:exiftool = @($script:pkgs | Where-Object Name -EQ 'exiftool')
    $script:notion   = @($script:pkgs | Where-Object Name -EQ 'Notion')
    $script:node     = @($script:pkgs | Where-Object Name -EQ 'Node.js')
}

Describe 'Engine ruling: exiftool moves to winget' -Tag 'Light','Bundle' {

    It 'declares exactly one exiftool entry, in ClientBasePackages' {
        $script:exiftool.Count     | Should -Be 1
        $script:exiftool[0].Bundle | Should -Be 'ClientBasePackages'
    }

    It 'installs from winget as OliverBetz.ExifTool' {
        $script:exiftool[0].Installer | Should -Be 'winget'
        $script:exiftool[0].Id        | Should -Be 'OliverBetz.ExifTool'
    }

    It 'installs machine-scope (the inno installer resolves at --scope machine)' {
        "$($script:exiftool[0].Scope)" | Should -Not -Be 'user'
    }

    It 'keeps exiftool as its CliCommand with a curated completer' {
        @($script:exiftool[0].CliCommands)          | Should -Be @('exiftool')
        $script:exiftool[0].HasNativeCommandScript  | Should -BeTrue
    }

    It 'records the engine rationale in Notes' {
        $script:exiftool[0].Notes | Should -Match 'winget'
    }
}

Describe 'Engine ruling: Notion moves to winget' -Tag 'Light','Bundle' {

    It 'declares exactly one Notion entry, in ClientBasePackages' {
        $script:notion.Count     | Should -Be 1
        $script:notion[0].Bundle | Should -Be 'ClientBasePackages'
    }

    It 'installs from winget as Notion.Notion' {
        $script:notion[0].Installer | Should -Be 'winget'
        $script:notion[0].Id        | Should -Be 'Notion.Notion'
    }

    It 'installs machine-scope, which is the scope the MSIX installer requires' {
        "$($script:notion[0].Scope)" | Should -Not -Be 'user'
    }

    It 'records the MSIX packaging shape in Notes, since it differs from the scoop install it replaces' {
        $script:notion[0].Notes | Should -Not -BeNullOrEmpty
        $script:notion[0].Notes | Should -Match 'MSIX|msix'
    }
}

Describe 'Engine ruling: Node.js deliberately stays on choco' -Tag 'Light','Bundle' {

    It 'declares exactly one Node.js entry, in AIAgents' {
        # AIAgents is the authoritative node/npm/npx completion source (#222);
        # a duplicate in another bundle would make registration order-dependent.
        $script:node.Count     | Should -Be 1
        $script:node[0].Bundle | Should -Be 'AIAgents'
    }

    It 'installs from choco as nodejs -- NOT winget' {
        # Deliberate rule-2 exception: winget materially lags choco here
        # (26.7.0 / LTS 24.19.0 vs 26.10.0, observed 2026-10-03), so moving to
        # winget would be a downgrade. Do not "fix" this to winget without
        # re-checking the versions; the reason is recorded in Notes.
        $script:node[0].Installer | Should -Be 'choco'
        $script:node[0].Id        | Should -Be 'nodejs'
    }

    It 'documents the lag that justifies the exception, with versions and the observation date' {
        # An undefended exception is how rclone went wrong (#462/#463): the
        # next reader must be able to re-check the claim, not re-derive it.
        $script:node[0].Notes | Should -Match '26\.10\.0'
        $script:node[0].Notes | Should -Match '26\.7\.0'
        $script:node[0].Notes | Should -Match '2026-10-03'
    }

    It 'still owns node/npm/npx completion' {
        foreach ($cli in 'node','npm','npx') {
            @($script:node[0].CliCommands) | Should -Contain $cli
        }
        $script:node[0].HasNativeCommandScript | Should -BeTrue
    }
}
