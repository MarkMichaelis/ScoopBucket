<#
.SYNOPSIS
    Light-suite Pester coverage for the private Get-PackageValidationError
    resilience helper.

.DESCRIPTION
    Get-PackageValidationError is the non-throwing validation gate the batch
    drivers (Invoke-PackageInstall / -PackageUpdate / -PackageUninstall) use so
    one malformed package becomes a Failed row instead of aborting the sweep.

    A PowerShell `class` is keyed by name within a session: once one module
    version's [Package] is loaded, Import-Module -Force on a newer version does
    NOT redefine the cached type. During dev-time hot-reload (and any session
    where an older installed module auto-loaded first) a live [Package] may be a
    STALE instance whose type name is still 'Package' but which pre-dates the
    GetValidationError() method. The helper must NOT throw an InvalidOperation
    for such instances -- it must skip the pre-check and return $null so the
    sweep continues. This file pins that contract.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    # Fabricate a "stale" [Package] WITHOUT depending on an older installed
    # module: a CLR type whose simple name is 'Package' (so it passes the
    # helper's type-name guard) but which has no GetValidationError method.
    if (-not ('Stale.Package' -as [type])) {
        Add-Type -TypeDefinition @'
namespace Stale {
    public class Package {
        public string Name;
        public string Installer;
        public string Id;
    }
}
'@
    }
}

Describe 'Get-PackageValidationError' -Tag 'Light', 'Module' {

    It 'returns $null for a valid [Package]' {
        $pkg = [Package]@{ Name = 'A'; Installer = 'winget'; Id = 'Foo.A' }
        $err = & (Get-Module MarkMichaelis.ScoopBucket) { param($p) Get-PackageValidationError -Package $p } $pkg
        $err | Should -BeNullOrEmpty
    }

    It 'returns a message (does not throw) for a structurally invalid [Package]' {
        # scoop package with an unprefixed Id violates a cross-field invariant.
        $pkg = [Package]@{ Name = 'Bad'; Installer = 'scoop'; Id = 'no-bucket-prefix' }
        $err = & (Get-Module MarkMichaelis.ScoopBucket) { param($p) Get-PackageValidationError -Package $p } $pkg
        $err | Should -Match 'bucket'
    }

    It 'returns a message for a null entry' {
        $err = & (Get-Module MarkMichaelis.ScoopBucket) { Get-PackageValidationError -Package $null }
        $err | Should -Match 'null'
    }

    It 'returns a message for a non-Package object' {
        $err = & (Get-Module MarkMichaelis.ScoopBucket) { param($p) Get-PackageValidationError -Package $p } ([pscustomobject]@{ Name = 'x' })
        $err | Should -Match 'expected a \[Package\]'
    }

    It 'does NOT throw for a stale Package-named type missing GetValidationError (returns $null)' {
        $stale = [Stale.Package]::new()
        $stale.Name = 'Stale'; $stale.Installer = 'winget'; $stale.Id = 'Foo.Stale'
        # Sanity: it really looks like a Package but lacks the method.
        $stale.GetType().Name | Should -Be 'Package'
        $stale.PSObject.Methods['GetValidationError'] | Should -BeNullOrEmpty

        $err = $null
        { $err = & (Get-Module MarkMichaelis.ScoopBucket) { param($p) Get-PackageValidationError -Package $p } $stale } |
            Should -Not -Throw
        $err | Should -BeNullOrEmpty
    }
}
