#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavior tests for #401: "install" means "ensure LATEST", not "ensure
# present" -- plus the HoldUpgrade escape for version-coupled packages, and
# the guard that stops scoop's update path from running an uninstaller.

BeforeAll {
    $script:repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:moduleRoot = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket'

    Get-Module MarkMichaelis.ScoopBucket -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'MarkMichaelis.ScoopBucket.psd1') -Force
    . (Join-Path $script:moduleRoot 'Classes\Package.ps1')
}

AfterAll {
    Get-Module MarkMichaelis.ScoopBucket -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Install-or-upgrade routing' -Tag 'Light', 'Module' {

    It 'upgrades a package the engine reports as already installed' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Install-WingetPackage { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Update-WingetPackage  { @{ State = 'Updated'; Reason = 'upgraded' } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{ Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget' }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Update-WingetPackage -Times 1 -Exactly
            $r.Status | Should -Be 'Updated'
        }
    }

    It 'reports AlreadyInstalled when the upgrade finds nothing newer' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Install-WingetPackage { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Update-WingetPackage  { @{ State = 'AlreadyLatest'; Reason = 'no applicable upgrade' } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{ Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget' }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Update-WingetPackage -Times 1 -Exactly
            $r.Status | Should -Be 'AlreadyInstalled'
        }
    }

    It 'surfaces a failed upgrade rather than masking it as AlreadyInstalled' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Install-WingetPackage { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Update-WingetPackage  { @{ State = 'Failed'; Reason = 'winget exited 1' } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{ Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget' }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion -ErrorAction SilentlyContinue

            $r.Status | Should -Be 'Failed'
        }
    }

    It 'does not upgrade a package that was actually installed this run' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Install-WingetPackage { @{ State = 'Installed'; Reason = $null } }
            Mock Update-WingetPackage  { @{ State = 'Updated'; Reason = 'should not run' } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{ Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget' }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Update-WingetPackage -Times 0 -Exactly
            $r.Status | Should -Be 'Installed'
        }
    }

    It 'honors -NoUpgrade by keeping the legacy fast skip' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Install-WingetPackage { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Update-WingetPackage  { @{ State = 'Updated'; Reason = 'should not run' } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{ Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget' }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion -NoUpgrade

            Should -Invoke Update-WingetPackage -Times 0 -Exactly
            $r.Status | Should -Be 'AlreadyInstalled'
        }
    }

    It 'routes <Installer> to <Updater>' -ForEach @(
        @{ Installer = 'choco';      Id = 'widget';      Updater = 'Update-ChocoPackage' }
        @{ Installer = 'scoop';      Id = 'main/widget'; Updater = 'Update-ScoopPackage' }
        @{ Installer = 'npmGlobal';  Id = 'widget';      Updater = 'Update-NpmGlobalPackage' }
        @{ Installer = 'dotnetTool'; Id = 'widget';      Updater = 'Update-DotnetToolPackage' }
    ) {
        $params = @{ Installer = $Installer; Id = $Id; Updater = $Updater }
        InModuleScope MarkMichaelis.ScoopBucket -Parameters $params {
            param($Installer, $Id, $Updater)

            Mock Install-ChocoPackage      { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Install-ScoopPackage      { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Install-NpmGlobalPackage  { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Install-DotnetToolPackage { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Update-ChocoPackage       { @{ State = 'Updated'; Reason = 'up' } }
            Mock Update-ScoopPackage       { @{ State = 'Updated'; Reason = 'up' } }
            Mock Update-NpmGlobalPackage   { @{ State = 'Updated'; Reason = 'up' } }
            Mock Update-DotnetToolPackage  { @{ State = 'Updated'; Reason = 'up' } }
            Mock Test-PackageInstalled     { $true }

            $pkg = [Package]@{ Name = 'Widget'; Installer = $Installer; Id = $Id }
            $null = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke $Updater -Times 1 -Exactly
        }
    }
}

Describe 'HoldUpgrade' -Tag 'Light', 'Module' {

    It 'never upgrades a held package on install' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Install-WingetPackage { @{ State = 'AlreadyInstalled'; Reason = 'probe' } }
            Mock Update-WingetPackage  { @{ State = 'Updated'; Reason = 'should not run' } }
            Mock Test-PackageInstalled { $true }

            $pkg = [Package]@{ Name = 'Kindle'; Installer = 'winget'; Id = '9P8JQ0JJSTLL'
                               Source = 'msstore'; HoldUpgrade = 'coupled to Epubor' }
            $r = Invoke-PackageInstall -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Update-WingetPackage -Times 0 -Exactly
            $r.Status | Should -Be 'AlreadyInstalled'
            $r.Reason | Should -Match 'coupled to Epubor'
        }
    }

    It 'reports Held and skips the engine on update' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-WingetPackage { @{ State = 'Updated'; Reason = 'should not run' } }

            $pkg = [Package]@{ Name = 'Kindle'; Installer = 'winget'; Id = '9P8JQ0JJSTLL'
                               Source = 'msstore'; HoldUpgrade = 'coupled to Epubor' }
            $r = Invoke-PackageUpdate -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Update-WingetPackage -Times 0 -Exactly
            $r.Status | Should -Be 'Held'
            $r.Reason | Should -Match 'coupled to Epubor'
        }
    }

    It 'still upgrades a package with no hold declared' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Mock Update-WingetPackage { @{ State = 'Updated'; Reason = 'up' } }

            $pkg = [Package]@{ Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget' }
            $r = Invoke-PackageUpdate -Packages @($pkg) -Bundle 'T' -SkipCompletion

            Should -Invoke Update-WingetPackage -Times 1 -Exactly
            $r.Status | Should -Be 'Updated'
        }
    }

    It 'holds Kindle in the shipped ClientBasePackages bundle' {
        $bundle = Join-Path $script:repoRoot 'bucket\ClientBasePackages.ps1'
        $text = Get-Content -Raw -LiteralPath $bundle
        $text | Should -Match "Name = 'Amazon Kindle'"
        # The hold must name Epubor so the reason survives as documentation.
        $text | Should -Match "HoldUpgrade\s*=\s*'DRM-coupled to Epubor"
    }
}

Describe 'Uninstaller guard under scoop update' -Tag 'Light', 'Manifest' {

    It 'guards every script-form uninstaller in the bucket' {
        # scoop's update path runs uninstaller scripts (scoop-update.ps1 ->
        # Invoke-Installer -Uninstall -> Invoke-HookScript), so an unguarded
        # one tears down its own configuration mid-update.
        $unguarded = @()
        foreach ($f in Get-ChildItem -Path (Join-Path $script:repoRoot 'bucket') -Filter '*.json' -Recurse) {
            $json = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json
            $lines = $json.uninstaller.script
            if (-not $lines) { continue }
            if (@($lines)[0] -notmatch 'update_app') { $unguarded += $f.Name }
        }
        $unguarded | Should -BeNullOrEmpty
    }

    It 'puts the guard first in <Manifest> so nothing destructive precedes it' -ForEach @(
        @{ Manifest = 'bucket\admin\AddLocalRepoBucket.json' }
        @{ Manifest = 'bucket\admin\AddMarkMichaelisScoopBucket.json' }
        @{ Manifest = 'bucket\admin\RegisterBucketModule.json' }
        @{ Manifest = 'bucket\os\RemapShiftLockToWindowsKey.json' }
    ) {
        $json = Get-Content -Raw -LiteralPath (Join-Path $script:repoRoot $Manifest) | ConvertFrom-Json
        $first = @($json.uninstaller.script)[0]
        $first | Should -Match 'update_app'
        $first | Should -Match 'return'
    }

    It 'returns early under a scoop update call stack but runs on a real uninstall' {
        # Reproduces scoop's hook invocation exactly: lib/install.ps1's
        # Invoke-HookScript does Invoke-Command ([scriptblock]::Create(...)),
        # and scoop-update.ps1 reaches it from update_app (which has
        # $old_version in scope) while scoop-uninstall.ps1 does not.
        $manifest = Join-Path $script:repoRoot 'bucket\os\RemapShiftLockToWindowsKey.json'
        $json = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        $guard = @($json.uninstaller.script)[0]
        $probe = @($guard, '"RAN"')

        function Invoke-HookScript { param($l) Invoke-Command ([scriptblock]::Create($l -join "`r`n")) }
        function Invoke-Installer  { param($l) Invoke-HookScript $l }
        function update_app        { param($l) $old_version = '1.0'; Invoke-Installer $l }
        function Invoke-ScoopUninstall { param($l) Invoke-Installer $l }

        $underUpdate    = @(update_app $probe)
        $underUninstall = @(Invoke-ScoopUninstall $probe)

        $underUpdate    | Should -Not -Contain 'RAN'
        $underUninstall | Should -Contain 'RAN'
    }
}

Describe 'Manifest version bumps track the module tree' -Tag 'Light', 'Manifest' {

    BeforeAll {
        # Load only the pure helpers from Test-ManifestVersionBumps.ps1 --
        # dot-sourcing the whole script would run its git-driven main flow.
        $script:bumpScript = Join-Path $script:repoRoot 'Test-ManifestVersionBumps.ps1'

        function script:Get-RelatedFilesForTest {
            param([string]$ManifestPath)

            $RepoRoot     = $script:repoRoot
            $RawUrlPrefix = 'https://raw.githubusercontent.com/MarkMichaelis/ScoopBucket/main/'

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:bumpScript, [ref]$null, [ref]$null)
            $wanted = @('Get-RelatedFiles', 'Get-ModuleRelatedFiles', 'Resolve-RepoRelative')
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                if ($fn.Name -in $wanted) { . ([scriptblock]::Create($fn.Extent.Text)) }
            }
            Get-RelatedFiles -ManifestPath $ManifestPath
        }
    }

    It 'treats module files as related files of a bundle manifest' {
        # A module change alters what every bundle does at install time but
        # touches no file in the manifest's own url array. Without this,
        # engine fixes ship with no version bump, and `scoop update` -- which
        # returns early on an unchanged version -- never delivers them.
        $related = Get-RelatedFilesForTest -ManifestPath (Join-Path $script:repoRoot 'bucket\AIAgents.json')

        # The manifest and its url payload are still tracked ...
        $related | Should -Contain 'bucket\AIAgents.json'
        $related | Should -Contain 'bucket\AIAgents.ps1'
        # ... and now so is the shared engine code.
        $related | Should -Contain 'module\MarkMichaelis.ScoopBucket\Public\Invoke-PackageInstall.ps1'
        $related | Should -Contain 'module\MarkMichaelis.ScoopBucket\Private\Install-WingetPackage.ps1'
    }

    It 'excludes module tests, which do not ship in the install path' {
        $related = Get-RelatedFilesForTest -ManifestPath (Join-Path $script:repoRoot 'bucket\AIAgents.json')
        ($related | Where-Object { $_ -match '\.Tests\.ps1$' }) | Should -BeNullOrEmpty
    }

    It 'enumerates foldered manifests, not just the top-level bundles' {
        # Without -Recurse the whole bucket/ai, bucket/admin, bucket/client and
        # bucket/os tree went unchecked, so those manifests never bumped and
        # `scoop update <app>` never re-ran their installer.
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:repoRoot 'Test-ManifestVersionBumps.ps1')
        $text | Should -Match "Get-ChildItem -Path \`$BucketDir -Filter '\*\.json' -Recurse"
    }
}

Describe 'Version-bump commit detection' -Tag 'Light', 'Manifest' {

    BeforeAll {
        # A throwaway repo is the only honest way to test git-history logic.
        $script:tmpRepo = Join-Path ([System.IO.Path]::GetTempPath()) "vbump-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Path $script:tmpRepo -Force | Out-Null

        Push-Location $script:tmpRepo
        try {
            git init -q 2>&1 | Out-Null
            git config user.email 'test@example.com'
            git config user.name  'Test'

            $manifest = Join-Path $script:tmpRepo 'app.json'

            # c1: created at 1.00.000
            '{ "version": "1.00.000", "installer": { "script": ["a"] } }' | Set-Content -LiteralPath $manifest -Encoding utf8
            git add -A 2>&1 | Out-Null; git commit -q -m 'add' 2>&1 | Out-Null
            $script:c1 = (git rev-parse HEAD).Trim()

            # c2: a REAL version bump
            '{ "version": "1.01.000", "installer": { "script": ["a"] } }' | Set-Content -LiteralPath $manifest -Encoding utf8
            git add -A 2>&1 | Out-Null; git commit -q -m 'bump' 2>&1 | Out-Null
            $script:c2 = (git rev-parse HEAD).Trim()

            # c3: edits the manifest and SHIFTS the version line, but leaves the
            # version value alone. This is the case `git log -L` mis-attributed.
            @(
                '{'
                '  "description": "added a line above the version",'
                '  "version": "1.01.000",'
                '  "installer": { "script": ["a"] }'
                '}'
            ) -join "`n" | Set-Content -LiteralPath $manifest -Encoding utf8
            git add -A 2>&1 | Out-Null; git commit -q -m 'edit without bump' 2>&1 | Out-Null
            $script:c3 = (git rev-parse HEAD).Trim()
        } finally {
            Pop-Location
        }

        function script:Get-BumpCommitForTest {
            param([string]$RepoDir, [string]$ManifestRel)

            $RepoRoot = $RepoDir
            $bumpScript = Join-Path $script:repoRoot 'Test-ManifestVersionBumps.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($bumpScript, [ref]$null, [ref]$null)
            $wanted = @('Invoke-Git', 'Get-LastVersionLineCommit', 'Get-ManifestVersionAt')
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                if ($fn.Name -in $wanted) { . ([scriptblock]::Create($fn.Extent.Text)) }
            }
            Get-LastVersionLineCommit -ManifestRel $ManifestRel
        }
    }

    AfterAll {
        if ($script:tmpRepo -and (Test-Path $script:tmpRepo)) {
            Remove-Item -LiteralPath $script:tmpRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports the commit where the version VALUE changed, not one that merely moved the line' {
        # `git log -L /"version"/,+1:<file>` tracks a moving line RANGE, so c3
        # (which shifted the version line without changing it) was reported as
        # the bump commit -- and since c3 is also the commit that changed the
        # file, the checker compared a sha against itself and passed. The bump
        # commit here must still be c2.
        $bump = Get-BumpCommitForTest -RepoDir $script:tmpRepo -ManifestRel 'app.json'
        $bump | Should -Be $script:c2
        $bump | Should -Not -Be $script:c3
    }

    It 'falls back to the commit that introduced the manifest when the version never changed' {
        Push-Location $script:tmpRepo
        try {
            '{ "version": "2.00.000", "installer": { "script": ["b"] } }' | Set-Content -LiteralPath (Join-Path $script:tmpRepo 'fresh.json') -Encoding utf8
            git add -A 2>&1 | Out-Null; git commit -q -m 'add fresh' 2>&1 | Out-Null
            $added = (git rev-parse HEAD).Trim()
        } finally {
            Pop-Location
        }

        Get-BumpCommitForTest -RepoDir $script:tmpRepo -ManifestRel 'fresh.json' | Should -Be $added
    }
}
