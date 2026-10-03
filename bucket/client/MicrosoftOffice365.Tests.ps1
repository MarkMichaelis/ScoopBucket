#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Microsoft Teams entry in MicrosoftOffice365
    (owner rulings on the #465 engine audit).

.DESCRIPTION
    Two separate contracts, both regressions that were live before #465.

    1. THE CLIENT, not just the engine. The entry declared
       `Installer = 'choco'` / `Id = 'Microsoft-Teams'`, whose version is
       1.8.0.27654 -- byte-identical to what winget publishes as
       `Microsoft.Teams.Classic` (1.8.00.27654), i.e. **Teams classic**, the
       client Microsoft has retired. So this was never only an engine
       mis-classification: the bucket was installing an end-of-support client.
       The fix targets the current client, winget `Microsoft.Teams`:

           PS> winget show --id Microsoft.Teams --exact --scope machine
           Version: 26198.304.4946.9672
           Installer Type: msix

       New Teams is MSIX-only, so machine scope means provisioning. These
       tests pin the id and, just as importantly, pin that the Classic id and
       the retired choco package are NOT what we install -- a bare
       "Installer is winget" assertion would still pass if someone retargeted
       it at `Microsoft.Teams.Classic`.

    2. DependsOn must be EMPTY. The entry declared
       `DependsOn = @('Microsoft 365 Apps for Enterprise')`. `DependsOn` is
       not an ordering hint -- `Resolve-PackageOrder` BFS-expands it
       transitively whenever `-Name` is passed, and `Install-Package` always
       passes `-Name` (#450). So `Install-Package -Name 'Microsoft Teams'`
       resolved `Office365ProPlus` into the install set: the heaviest package
       in the bucket, whose own `CISkip` records that it needs a GUI session
       and license activation (choco exit 17004). Asking for a chat client
       must not schedule all of Office. Exactly the Aspire/Visual Studio
       foot-gun #450 fixed, in a second place.

    Following DependsOnClosure.Tests.ps1, the closure assertion runs the real
    resolver over the real declarations rather than grepping the declaration
    text, so it also fails if the closure semantics themselves change.

    Tagged 'Light' -- harvests declarative [Package] entries and runs the pure
    resolver; no install side effects.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket')
    $script:psd1       = Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $script:psd1) { Import-Module $script:psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    # Resolve-PackageOrder is private; dot-source it directly (same approach
    # as DependsOnClosure.Tests.ps1). The class must be loaded first.
    . (Join-Path $script:moduleRoot 'Classes\Package.ps1')
    . (Join-Path $script:moduleRoot 'Private\Resolve-PackageOrder.ps1')

    $script:allPkgs = @(Get-Package -BucketPath (Split-Path -Parent $PSScriptRoot))
    $script:office  = @($script:allPkgs | Where-Object { $_.Bundle -eq 'MicrosoftOffice365' })
    $script:teams   = @($script:office | Where-Object Name -EQ 'Microsoft Teams')

    # Resolve exactly as `Install-Package -Name 'Microsoft Teams'` would.
    # Resolve-PackageOrder returns `,$array` to preserve array-ness, so the
    # result must be assigned before it is enumerated.
    $ordered = Resolve-PackageOrder -Packages $script:office -Name 'Microsoft Teams'
    $script:resolvedTeams = @($ordered | ForEach-Object Name)
}

Describe 'MicrosoftOffice365: Microsoft Teams client and engine' -Tag 'Light','Bundle' {

    It 'has the fixture packages these tests reason about' {
        $script:teams.Count | Should -Be 1
        @($script:office | Where-Object Name -EQ 'Microsoft 365 Apps for Enterprise').Count | Should -Be 1
        # Guard against a vacuous pass.
        $script:resolvedTeams | Should -Contain 'Microsoft Teams'
    }

    It 'installs the CURRENT Teams client from winget' {
        $script:teams[0].Installer | Should -Be 'winget'
        $script:teams[0].Id        | Should -Be 'Microsoft.Teams'
    }

    It 'does NOT install Teams classic, which Microsoft has retired' {
        # The pre-#465 declaration (choco 'Microsoft-Teams', 1.8.0.27654) was
        # the same build as winget's Microsoft.Teams.Classic. Both spellings
        # must stay out of the bucket entirely.
        @($script:allPkgs | Where-Object Id -EQ 'Microsoft.Teams.Classic').Count | Should -Be 0
        @($script:allPkgs | Where-Object Id -EQ 'Microsoft-Teams').Count         | Should -Be 0
        $script:teams[0].Id | Should -Not -Match 'Classic'
    }

    It 'installs machine-scope (new Teams is MSIX; no user-scope override)' {
        "$($script:teams[0].Scope)" | Should -Not -Be 'user'
    }

    It 'records the client change and the MSIX shape in Notes' {
        $script:teams[0].Notes | Should -Not -BeNullOrEmpty
        $script:teams[0].Notes | Should -Match 'MSIX|msix'
        $script:teams[0].Notes | Should -Match 'classic|Classic'
    }
}

Describe 'MicrosoftOffice365: Teams must not drag Office into the install set' -Tag 'Light','Bundle' {

    It 'declares no DependsOn' {
        @($script:teams[0].DependsOn) | Should -BeNullOrEmpty
    }

    It 'resolves Microsoft Teams without pulling Microsoft 365 Apps for Enterprise into the install set' {
        # The regression: Office365ProPlus is the heaviest package in the
        # bucket and needs a GUI session plus license activation. Asking for
        # the chat client must never schedule it (#450 shape).
        $script:resolvedTeams | Should -Not -Contain 'Microsoft 365 Apps for Enterprise'
    }

    It 'resolves to Teams alone' {
        $script:resolvedTeams -join ',' | Should -Be 'Microsoft Teams'
    }

    It 'never schedules Office for any package that is not Office itself or an Office add-on' {
        # Generalized guard so the same shape cannot reappear on a sibling.
        # The Office CLI shims and Claude for Excel genuinely require Office
        # (the shims wrap Office16 binaries; the add-in is hosted inside
        # Excel), so they are the legitimate exceptions.
        $office = 'Microsoft 365 Apps for Enterprise'
        $legitimate = @($office, 'Microsoft Office CLI shims', 'Claude for Excel')

        $offenders = @(foreach ($p in $script:office) {
            if ($p.Name -in $legitimate) { continue }
            $ordered = Resolve-PackageOrder -Packages $script:office -Name $p.Name
            if (@($ordered | ForEach-Object Name) -contains $office) { $p.Name }
        })
        $offenders | Should -BeNullOrEmpty -Because "these packages drag Office in via DependsOn: $($offenders -join ', ')"
    }
}
