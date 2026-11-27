#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# The hierarchical package picker (#543): `Install-Package` with no arguments
# shows every installable item in the bucket as a tree, pre-checks the default
# set plus what is already installed, and installs what the owner leaves
# checked. The tree is built from the bucket each time -- no list is kept -- so
# a package or manifest added or removed shows up or disappears on its own.
#
# Fixture layout:
#   RootA.ps1  a1, a2 (optional), 'Child bundle' -> MarkMichaelis/Child (link),
#              a3 -> MarkMichaelis/Tool (a package installed by a bare
#              manifest), shared, a4 (optional, DependsOn the Child link);
#              RootA.json depends on Dep
#   RootB.ps1  b1 (DependsOn b2), b2 (optional), shared twin, shared lower
#              (the same Id in other casing);  RootB.json depends on Tool
#   RootA also links to RootB, which is top-level itself and so is not nested.
#   cat1/Child.ps1  c1, c2    cat1/Dep.ps1  d1        cat1/Tool.json (used by a3)
#   rootb/Loner.ps1 l1 (unused; its folder matches Root B)
#   misc/Tweak.json (unused; its folder matches no top-level bundle)

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psd1 = Join-Path $script:repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    Import-Module $script:psd1 -Force
    $script:M = Get-Module MarkMichaelis.ScoopBucket

    function script:New-FixtureManifest {
        param([string]$Dir, [string]$Name, [string]$Script, [string[]]$Depends)
        $manifest = [ordered]@{
            version   = '1.00.000'
            url       = @('https://example.invalid/placeholder')
            installer = @{ script = @($Script) }
        }
        if ($Depends) { $manifest['depends'] = @($Depends) }
        Set-Content -LiteralPath (Join-Path $Dir "$Name.json") -Value ($manifest | ConvertTo-Json -Depth 4) -Encoding UTF8
    }

    function script:New-FixtureBundle {
        param([string]$Dir, [string]$Bundle, [string]$PackagesText, [string[]]$Depends)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $text = @"
`$scoopBucketPsd1 = '$($script:psd1 -replace "'","''")'
if (Test-Path `$scoopBucketPsd1) { Import-Module `$scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

`$Packages = [Package[]]@(
$PackagesText
)

Invoke-PackageInstall -Packages `$Packages -Bundle '$Bundle'
"@
        Set-Content -LiteralPath (Join-Path $Dir "$Bundle.ps1") -Value $text -Encoding UTF8
        New-FixtureManifest -Dir $Dir -Name $Bundle -Script "& `"`$dir\\$Bundle.ps1`"" -Depends $Depends
    }

    function script:New-PickerFixture {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-picker-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $root | Out-Null
        New-FixtureBundle -Dir $root -Bundle 'RootA' -Depends 'Dep' -PackagesText @'
    [Package]@{ Name = 'a1';           Installer = 'winget'; Id = 'Test.A1' }
    [Package]@{ Name = 'a2';           Installer = 'winget'; Id = 'Test.A2'; Default = $false }
    [Package]@{ Name = 'Child bundle'; Installer = 'scoop';  Id = 'MarkMichaelis/Child' }
    [Package]@{ Name = 'a3';           Installer = 'scoop';  Id = 'MarkMichaelis/Tool' }
    [Package]@{ Name = 'shared';       Installer = 'winget'; Id = 'Test.Shared' }
    [Package]@{ Name = 'a4';           Installer = 'winget'; Id = 'Test.A4'; Default = $false; DependsOn = @('Child bundle') }
    [Package]@{ Name = 'Root B bundle'; Installer = 'scoop'; Id = 'MarkMichaelis/RootB' }
'@
        New-FixtureBundle -Dir $root -Bundle 'RootB' -Depends 'Tool' -PackagesText @'
    [Package]@{ Name = 'b1';           Installer = 'winget'; Id = 'Test.B1'; DependsOn = @('b2') }
    [Package]@{ Name = 'b2';           Installer = 'winget'; Id = 'Test.B2'; Default = $false }
    [Package]@{ Name = 'shared twin';  Installer = 'winget'; Id = 'Test.Shared' }
    [Package]@{ Name = 'shared lower'; Installer = 'winget'; Id = 'test.shared' }
'@
        $cat1 = Join-Path $root 'cat1'
        New-FixtureBundle -Dir $cat1 -Bundle 'Child' -PackagesText "    [Package]@{ Name = 'c1'; Installer = 'winget'; Id = 'Test.C1' }`n    [Package]@{ Name = 'c2'; Installer = 'winget'; Id = 'Test.C2' }"
        New-FixtureBundle -Dir $cat1 -Bundle 'Dep'   -PackagesText "    [Package]@{ Name = 'd1'; Installer = 'winget'; Id = 'Test.D1' }"
        New-FixtureManifest -Dir $cat1 -Name 'Tool' -Script "Write-Host 'tool'"
        # Unused, in a folder named like Root B: shown under Root B.
        New-FixtureBundle -Dir (Join-Path $root 'rootb') -Bundle 'Loner' -PackagesText "    [Package]@{ Name = 'l1'; Installer = 'winget'; Id = 'Test.L1' }"
        # Unused, in a folder no top-level bundle matches: its own group.
        $misc = Join-Path $root 'misc'
        New-Item -ItemType Directory -Path $misc | Out-Null
        New-FixtureManifest -Dir $misc -Name 'Tweak' -Script "Write-Host 'one-shot tweak'"
        $root
    }

    function script:Find-Node {
        param($Nodes, [string]$Name)
        foreach ($n in $Nodes) {
            if ($n.Name -eq $Name) { return $n }
            if ($n.Kind -eq 'Group') {
                $hit = Find-Node -Nodes $n.Children -Name $Name
                if ($hit) { return $hit }
            }
        }
    }

    function script:Key {
        param([System.ConsoleKey]$Key, [char]$Char = [char]0)
        [System.ConsoleKeyInfo]::new($Char, $Key, $false, $false, $false)
    }

    $script:bucket = New-PickerFixture
    $script:catalog = & $script:M { param($b) Get-PackageCatalog -BucketPath $b } $script:bucket
    # a2 (optional) is installed; nothing else is.
    $script:installed = @{ 'winget|Test.A2' = $true }
}

AfterAll {
    if ($script:bucket -and (Test-Path $script:bucket)) { Remove-Item -LiteralPath $script:bucket -Recurse -Force -ErrorAction Ignore }
}

Describe 'The picker''s tree is built from the bucket (#543)' -Tag 'Light', 'Module' {
    It 'puts the bundles at the bucket root on top, then folders no bundle matches' {
        $script:catalog.Roots.Name | Should -Be @('Root A', 'Root B', 'Misc')
    }

    It 'never nests a top-level bundle under another one' {
        $rootA = $script:catalog.Roots | Where-Object Name -eq 'Root A'
        $rootA.Children.Name | Should -Not -Contain 'Root B'
        Find-Node -Nodes $rootA.Children -Name 'b1' | Should -BeNullOrEmpty
    }

    It 'nests a bundle that another bundle links to' {
        $rootA = $script:catalog.Roots | Where-Object Name -eq 'Root A'
        $child = $rootA.Children | Where-Object Name -eq 'Child'
        $child.Kind | Should -Be 'Group'
        $child.Children.Name | Should -Be @('c1', 'c2')
    }

    It 'shows a pulled-in bundle with a single package as that package' {
        $rootA = $script:catalog.Roots | Where-Object Name -eq 'Root A'
        $d1 = $rootA.Children | Where-Object Name -eq 'd1'
        $d1.Kind | Should -Be 'Package'
        $rootA.Children.Name | Should -Not -Contain 'Dep'
    }

    It 'names groups for people: <Raw> -> <Shown>' -ForEach @(
        @{ Raw = 'OSBasePackages';     Shown = 'OS Base Packages' }
        @{ Raw = 'AIAgents';           Shown = 'AI Agents' }
        @{ Raw = 'MicrosoftOffice365'; Shown = 'Microsoft Office 365' }
        @{ Raw = 'ChatGPT';            Shown = 'ChatGPT' }
        @{ Raw = 'RootA';              Shown = 'Root A' }
    ) {
        & $script:M { param($r) ConvertTo-PickerDisplayName $r } $Raw | Should -Be $Shown
    }

    It 'nests what another bundle''s manifest depends on' {
        $rootA = $script:catalog.Roots | Where-Object Name -eq 'Root A'
        $rootA.Children.Name | Should -Contain 'd1'
    }

    It 'shows a package installed through a bare manifest as a package, not a standalone manifest' {
        (Find-Node -Nodes $script:catalog.Roots -Name 'a3').Kind | Should -Be 'Package'
        $misc = $script:catalog.Roots | Where-Object Name -eq 'Misc'
        Find-Node -Nodes $misc.Children -Name 'Tool' | Should -BeNullOrEmpty
    }

    It 'puts what no bundle installs under the top-level group its folder is named after' {
        $rootB = $script:catalog.Roots | Where-Object Name -eq 'Root B'
        $extra = $rootB.Children | Where-Object Name -eq 'Also available'
        $extra.Kind | Should -Be 'Group'
        $extra.Children.Name | Should -Be @('l1')
    }

    It 'gives a folder no top-level group matches a group of its own' {
        $tweak = ($script:catalog.Roots | Where-Object Name -eq 'Misc').Children
        $tweak.Name | Should -Be @('Tweak')
        $tweak.Kind | Should -Be 'Manifest'
    }

    It 'reflects packages and bundles added or removed, with no list to edit' {
        $bucket = New-PickerFixture
        try {
            $rootB = Join-Path $bucket 'RootB.ps1'
            (Get-Content -Raw $rootB) -replace "(?m)^.*'b1'.*\r?\n", '' -replace "DependsOn = @\('b2'\)", '' | Set-Content $rootB
            New-FixtureBundle -Dir $bucket -Bundle 'RootC' -PackagesText "    [Package]@{ Name = 'z1'; Installer = 'winget'; Id = 'Test.Z1' }"

            $catalog = & $script:M { param($b) Get-PackageCatalog -BucketPath $b } $bucket

            $catalog.Roots.Name | Should -Contain 'Root C'
            ($catalog.Roots | Where-Object Name -eq 'Root B').Children.Name | Should -Not -Contain 'b1'
        } finally {
            Remove-Item -LiteralPath $bucket -Recurse -Force -ErrorAction Ignore
        }
    }
}

Describe 'What the picker checks (#543)' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:state = & $script:M { param($c, $i) New-PickerState -Catalog $c -Installed $i } $script:catalog $script:installed
        $script:box = { param($name) & $script:M { param($s, $n) Get-PickerBox -State $s -Node $n } $script:state (Find-Node -Nodes $script:catalog.Roots -Name $name) }
    }

    It 'starts with the default set plus what is installed' {
        & $script:box 'a1' | Should -Be '[x]'
        & $script:box 'c1' | Should -Be '[x]'
        & $script:box 'l1' | Should -Be '[x]'
        & $script:box 'a2' | Should -Be '[*]'
        & $script:box 'Tweak' | Should -Be '[ ]'
    }

    It 'treats a package that installs through a bare manifest as an ordinary default package' {
        & $script:box 'a3' | Should -Be '[x]'
        $plan = & $script:M { param($s) Get-PickerPlan -State $s } $script:state
        ($plan.ByBundle.Values | Where-Object Bundle -eq 'RootA').Names | Should -Contain 'a3'
    }

    It 'draws an installed item with a different box from a new install' {
        & $script:box 'a2' | Should -Not -Be (& $script:box 'a1')
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state (Find-Node -Nodes $script:catalog.Roots -Name 'a2')
        & $script:box 'a2' | Should -Be '[=]'
    }

    It 'locks on what a checked package needs' {
        & $script:box 'b2' | Should -Be '[!]'
    }

    It 'cycles a group: add what is not installed, then everything, then only what is installed, then back' {
        $state = & $script:M { param($c) New-PickerState -Catalog $c -Installed @{ 'winget|Test.A2' = $true; 'winget|Test.Shared' = $true } } $script:catalog
        $boxOf = { param($name) & $script:M { param($s, $n) Get-PickerBox -State $s -Node $n } $state (Find-Node -Nodes $script:catalog.Roots -Name $name) }
        $toggle = { param($node) & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $state $node }
        $rootB = $script:catalog.Roots | Where-Object Name -eq 'Root B'
        # How it was: b1 (new) unchecked, the installed shared package left as it is.
        & $toggle (Find-Node -Nodes $rootB.Children -Name 'b1')
        & $toggle (Find-Node -Nodes $rootB.Children -Name 'shared twin')
        & $boxOf 'shared twin' | Should -Be '[=]'

        & $toggle $rootB                                              # 1: add everything not installed
        & $boxOf 'b1' | Should -Be '[x]'
        & $boxOf 'b2' | Should -Be '[x]'
        & $boxOf 'shared twin' | Should -Be '[=]' -Because 'installed items keep their checkbox in this step'
        & $toggle $rootB                                              # 2: everything, upgrades too
        & $boxOf 'shared twin' | Should -Be '[*]'
        & $toggle $rootB                                              # 3: only what is installed
        & $boxOf 'shared twin' | Should -Be '[*]'
        & $boxOf 'b1' | Should -Be '[ ]'
        & $boxOf 'l1' | Should -Be '[ ]'
        & $toggle $rootB                                              # 4: back to how it was
        & $boxOf 'b1' | Should -Be '[ ]'
        & $boxOf 'shared twin' | Should -Be '[=]'
        & $boxOf 'l1' | Should -Be '[x]'
    }

    It 'skips a step that would change nothing' {
        # Everything in Child is checked and nothing is installed, so steps 1
        # and 2 would change nothing: the first Space goes straight to 3.
        $child = Find-Node -Nodes $script:catalog.Roots -Name 'Child'
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state $child
        & $script:box 'c1' | Should -Be '[ ]'
    }

    It 'starts the group cycle over when the filter changes' {
        $rootB = $script:catalog.Roots | Where-Object Name -eq 'Root B'
        # Under 'b1' the first Space unchecks b1 (steps 1 and 2 change
        # nothing), leaving nothing checked among what the filter shows.
        $script:state.Filter = 'b1'
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state $rootB
        # Under 'b2' nothing shown is checked either; only the filter tells the
        # two apart, and a new filter is a new cycle.
        $script:state.Filter = 'b2'
        & $script:M { param($s, $n) Get-PickerGroupStep -State $s -Node $n } $script:state $rootB | Should -Be 1
    }

    It 'starts the group cycle over after an item in the group changes' {
        $rootB = $script:catalog.Roots | Where-Object Name -eq 'Root B'
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state $rootB             # 1: everything
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state (Find-Node -Nodes $rootB.Children -Name 'b1')
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state $rootB             # a new cycle: everything again
        & $script:box 'b1' | Should -Be '[x]'
    }

    It 'shows a partly checked group' {
        $rootA = $script:catalog.Roots | Where-Object Name -eq 'Root A'
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state (Find-Node -Nodes $script:catalog.Roots -Name 'a1')
        & $script:M { param($s, $n) Get-PickerBox -State $s -Node $n } $script:state $rootA | Should -Be '[~]'
    }

    It 'keeps one package declared by two bundles in step' {
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state (Find-Node -Nodes $script:catalog.Roots -Name 'shared twin')
        & $script:box 'shared' | Should -Be '[ ]'
    }

    It 'clears everything with n and restores the defaults with d' {
        $press = { param($k) & $script:M { param($s, $key) Invoke-PickerKey -State $s -Key $key } $script:state $k }
        $null = & $press (Key -Key N -Char 'n')
        & $script:box 'a1' | Should -Be '[ ]'
        & $script:box 'a2' | Should -Be '[=]'
        $null = & $press (Key -Key D -Char 'd')
        & $script:box 'a1' | Should -Be '[x]'
        & $script:box 'a2' | Should -Be '[*]'
    }
}

Describe 'The picker''s screen and keys (#543)' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:state = & $script:M { param($c, $i) New-PickerState -Catalog $c -Installed $i } $script:catalog $script:installed
        $script:press = { param($k) & $script:M { param($s, $key) Invoke-PickerKey -State $s -Key $key } $script:state $k }
        $script:screen = { (& $script:M { param($s) Format-PickerScreen -State $s -Width 100 -Height 30 } $script:state).Text }
    }

    It 'starts collapsed, one row per top-level group, with the cursor on the first' {
        $lines = & $script:screen
        ($lines | Where-Object { $_ -match 'Root A' }) | Should -Match '^>'
        $lines | Where-Object { $_ -match '\ba1\b' } | Should -BeNullOrEmpty
    }

    It 'expands a group with Right and shows its items with their boxes' {
        $null = & $script:press (Key -Key RightArrow)
        $lines = & $script:screen
        $lines | Where-Object { $_ -match '\[x\] a1\b' } | Should -Not -BeNullOrEmpty
        $lines | Where-Object { $_ -match '\[\*\] a2\b.*installed' } | Should -Not -BeNullOrEmpty
    }

    It 'filters to matching items as you type after /' {
        $null = & $script:press (Key -Key Oem2 -Char '/')
        foreach ($c in 'c1'.ToCharArray()) { $null = & $script:press (Key -Key A -Char $c) }
        $lines = & $script:screen
        $lines | Where-Object { $_ -match '\bc1\b' } | Should -Not -BeNullOrEmpty
        $lines | Where-Object { $_ -match '\ba1\b' } | Should -BeNullOrEmpty
    }

    It 'explains every box in a legend' {
        $legend = (& $script:screen) -join "`n"
        foreach ($box in '\[x\]', '\[\*\]', '\[=\]', '\[!\]', '\[~\]', '\[ \]') { $legend | Should -Match "$box [a-z]" }
    }

    It 'colors each legend entry like the rows it explains' {
        $lines = & $script:M { param($s) Format-PickerScreen -State $s -Width 100 -Height 30 } $script:state
        $legend = @($lines | Where-Object { $_.Text -match '\[=\] ' -and $_.Segments })[0]
        $legend | Should -Not -BeNullOrEmpty
        foreach ($box in '[x]', '[*]', '[=]', '[!]', '[~]', '[ ]') {
            $segment = @($legend.Segments | Where-Object { $_.Text.StartsWith($box) })[0]
            $segment.Color | Should -Be (& $script:M { param($b) Get-PickerBoxColor -Box $b } $box) -Because "$box in the legend"
        }
        @('[x]', '[*]', '[=]', '[!]' | ForEach-Object { & $script:M { param($b) Get-PickerBoxColor -Box $b } $_ } | Sort-Object -Unique).Count | Should -Be 4
    }

    It 'fits the keys and the legend in an 80-column console' {
        $lines = (& $script:M { param($s) Format-PickerScreen -State $s -Width 80 -Height 30 } $script:state).Text
        $lines[0] | Should -Not -Match '~\s*$' -Because 'a cut line ends in ~'
        $lines[1] | Should -Match '\[ \] skip'
    }

    It 'marks an item that also sits in another top-level group' {
        $null = & $script:press (Key -Key DownArrow)
        $null = & $script:press (Key -Key RightArrow)
        (& $script:screen) | Where-Object { $_ -match 'shared twin' } | Should -Match '\(also in Root A\)'
    }

    It 'dims the "also in" note on a row the cursor is not on' {
        $null = & $script:press (Key -Key DownArrow)
        $null = & $script:press (Key -Key RightArrow)
        $all =& $script:M { param($s) Format-PickerScreen -State $s -Width 100 -Height 30 } $script:state
        $line = @($all | ForEach-Object { $_ } | Where-Object { $_.Text -match 'shared twin' })[0]
        $line | Should -Not -BeNullOrEmpty
        $line.Highlight | Should -BeFalse
        $line.Segments[-1].Text | Should -Match '^\s*\(also in Root A\)\s*$'
        $line.Segments[-1].Color | Should -Be 'DarkGray'
        (-join @($line.Segments | ForEach-Object Text)).TrimEnd() | Should -Be $line.Text.TrimEnd()
    }

    It 'keeps the truncation marker when a narrow window cuts a row with an "also in" note' {
        $null = & $script:press (Key -Key DownArrow)
        $null = & $script:press (Key -Key RightArrow)
        $all = & $script:M { param($s) Format-PickerScreen -State $s -Width 24 -Height 30 } $script:state
        $line = @($all | ForEach-Object { $_ } | Where-Object { $_.Text -match 'shared twin' })[0]
        $line.Text | Should -Match '~$'
        if ($line.PSObject.Properties['Segments'] -and $line.Segments) {
            -join @($line.Segments | ForEach-Object Text) | Should -Be $line.Text
        }
    }

    It 'says what Space will do to the group under the cursor' {
        (& $script:screen) -join "`n" | Should -Match 'Space: add everything not installed'
    }

    It 'cancels with Esc' {
        & $script:press (Key -Key Escape) | Should -Be 'Cancel'
    }

    It 'reviews with Enter and installs with y, sending each package to the bundle that declares it' {
        $null = & $script:press (Key -Key N -Char 'n')                 # clear everything
        $null = & $script:press (Key -Key DownArrow)                   # Root B
        $null = & $script:press (Key -Key Spacebar)                    # check all of Root B
        & $script:press (Key -Key Enter) | Should -Be 'Continue'
        (& $script:screen) -join "`n" | Should -Match 'b1'
        & $script:press (Key -Key Y -Char 'y') | Should -Be 'Confirm'

        $plan = & $script:M { param($s) Get-PickerPlan -State $s } $script:state
        $rootB = $plan.ByBundle.Values | Where-Object Bundle -eq 'RootB'
        @($rootB.Names) | Should -Contain 'b1'
        @($rootB.Names) | Should -Contain 'b2'
        # The twin is owned by the first bundle that declares it, and the Tool
        # manifest Root B depends on is the package a3 of Root A.
        ($plan.ByBundle.Values | Where-Object Bundle -eq 'RootA').Names | Should -Be @('a3', 'shared')
        @($plan.Manifests).Count | Should -Be 0
    }

    It 'installs a checked standalone manifest by its manifest name' {
        $null = & $script:press (Key -Key N -Char 'n')
        $tweak = Find-Node -Nodes $script:catalog.Roots -Name 'Tweak'
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state $tweak
        (& $script:M { param($s) Get-PickerPlan -State $s } $script:state).Manifests | Should -Be @('Tweak')
    }

    It 'never plans an installed item the owner unchecked' {
        $null = & $script:press (Key -Key N -Char 'n')
        $plan = & $script:M { param($s) Get-PickerPlan -State $s } $script:state
        @($plan.ByBundle.Keys).Count | Should -Be 0
    }
}

Describe 'Picker edge cases from review (#543)' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:state = & $script:M { param($c, $i) New-PickerState -Catalog $c -Installed $i } $script:catalog $script:installed
        $script:press = { param($k) & $script:M { param($s, $key) Invoke-PickerKey -State $s -Key $key } $script:state $k }
        $script:box = { param($name) & $script:M { param($s, $n) Get-PickerBox -State $s -Node $n } $script:state (Find-Node -Nodes $script:catalog.Roots -Name $name) }
        $script:toggle = { param($name) & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state (Find-Node -Nodes $script:catalog.Roots -Name $name) }
    }

    It 'keeps the review screen inside the window and scrolls it' {
        $null = & $script:press (Key -Key A -Char 'a')
        $null = & $script:press (Key -Key Enter)
        $first = (& $script:M { param($s) Format-PickerScreen -State $s -Width 80 -Height 8 } $script:state).Text
        $first.Count | Should -Be 7
        $first[0] | Should -Match 'Review'
        ($first -join "`n") | Should -Match 'more'
        $null = & $script:press (Key -Key PageDown)
        $next = (& $script:M { param($s) Format-PickerScreen -State $s -Width 80 -Height 8 } $script:state).Text
        $next[0] | Should -Match 'Review'
        ($next -join "`n") | Should -Not -Be ($first -join "`n")
    }

    It 'toggles only the items a filter shows' {
        $null = & $script:press (Key -Key N -Char 'n')
        $null = & $script:press (Key -Key Oem2 -Char '/')
        foreach ($c in 'b1'.ToCharArray()) { $null = & $script:press (Key -Key A -Char $c) }
        $null = & $script:press (Key -Key Enter)         # keep the filter
        $null = & $script:press (Key -Key Spacebar)      # on Root B, the only group shown
        & $script:box 'b1' | Should -Be '[x]'
        & $script:box 'shared' | Should -Be '[ ]'
    }

    It 'shows and toggles everything in a group whose own name matches the filter' {
        $null = & $script:press (Key -Key N -Char 'n')
        $null = & $script:press (Key -Key Oem2 -Char '/')
        foreach ($c in 'Child'.ToCharArray()) { $null = & $script:press (Key -Key A -Char $c) }
        $null = & $script:press (Key -Key Enter)
        $lines = (& $script:M { param($s) Format-PickerScreen -State $s -Width 80 -Height 20 } $script:state).Text
        $lines | Where-Object { $_ -match '\bc2\b' } | Should -Not -BeNullOrEmpty
        $null = & $script:press (Key -Key Spacebar)      # on Root A, shown for its Child group
        & $script:box 'c1' | Should -Be '[x]'
        & $script:box 'c2' | Should -Be '[x]'
        & $script:box 'a1' | Should -Be '[ ]'
    }

    It 'clears a kept filter with Esc before Esc cancels' {
        $null = & $script:press (Key -Key Oem2 -Char '/')
        $null = & $script:press (Key -Key C -Char 'c')
        $null = & $script:press (Key -Key Enter)
        & $script:press (Key -Key Escape) | Should -Be 'Continue'
        $script:state.Filter | Should -BeNullOrEmpty
        & $script:press (Key -Key Escape) | Should -Be 'Cancel'
    }

    It 'leaves an installed manifest unchecked, as Install-Package -Name * does' {
        $state = & $script:M { param($c) New-PickerState -Catalog $c -Installed @{ 'manifest|Tweak' = $true } } $script:catalog
        & $script:M { param($s, $n) Get-PickerBox -State $s -Node $n } $state (Find-Node -Nodes $script:catalog.Roots -Name 'Tweak') | Should -Be '[=]'
    }

    It 'treats one Id in different casing as one item' {
        $null = & $script:press (Key -Key N -Char 'n')
        & $script:toggle 'shared lower'
        & $script:box 'shared' | Should -Be '[x]'
    }

    It 'shows the whole bundle a needed link will install as needed' {
        $null = & $script:press (Key -Key N -Char 'n')
        & $script:toggle 'a4'
        & $script:box 'c1' | Should -Be '[!]'
        & $script:box 'c2' | Should -Be '[!]'
        (& $script:M { param($s) Get-PickerPlan -State $s } $script:state).Required | Should -Not -Match 'MarkMichaelis/'
    }

    It 'treats a manifest reached by depends and by a package Id as one item' {
        $null = & $script:press (Key -Key N -Char 'n')
        $rootB = $script:catalog.Roots | Where-Object Name -eq 'Root B'
        $tool = $rootB.Children | Where-Object Name -eq 'Tool'
        & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:state $tool
        & $script:box 'a3' | Should -Be '[x]'
        $plan = & $script:M { param($s) Get-PickerPlan -State $s } $script:state
        @($plan.Manifests).Count | Should -Be 0
        ($plan.ByBundle.Values | Where-Object Bundle -eq 'RootA').Names | Should -Be @('a3')
    }

    It 'brings rows back into view after the tree shrinks' {
        $script:state.Top = 40
        $lines = (& $script:M { param($s) Format-PickerScreen -State $s -Width 80 -Height 20 } $script:state).Text
        ($lines | Select-Object -Skip 2 -First 1) | Should -Match 'Root A'
    }

    It 'builds a tree with a link cycle and keeps the cycle visible' {
        $bucket = Join-Path ([System.IO.Path]::GetTempPath()) ("ScoopBucket-picker-cycle-$([guid]::NewGuid().ToString('N'))")
        try {
            New-FixtureBundle -Dir $bucket -Bundle 'CycRoot' -PackagesText "    [Package]@{ Name = 'to x'; Installer = 'scoop'; Id = 'MarkMichaelis/CycX' }`n    [Package]@{ Name = 'r1'; Installer = 'winget'; Id = 'Test.R1' }"
            New-FixtureBundle -Dir (Join-Path $bucket 'cat') -Bundle 'CycX' -PackagesText "    [Package]@{ Name = 'x1'; Installer = 'winget'; Id = 'Test.X1' }`n    [Package]@{ Name = 'to y'; Installer = 'scoop'; Id = 'MarkMichaelis/CycY' }"
            New-FixtureBundle -Dir (Join-Path $bucket 'cat') -Bundle 'CycY' -PackagesText "    [Package]@{ Name = 'to x'; Installer = 'scoop'; Id = 'MarkMichaelis/CycX' }`n    [Package]@{ Name = 'y1'; Installer = 'winget'; Id = 'Test.Y1' }"
            $catalog = & $script:M { param($b) Get-PackageCatalog -BucketPath $b } $bucket
            $x = ($catalog.Roots | Where-Object Name -eq 'Cyc Root').Children | Where-Object Name -eq 'Cyc X'
            $y = $x.Children | Where-Object Name -eq 'Cyc Y'
            $y.Children.Name | Should -Contain 'Cyc X'
            $state = & $script:M { param($c) New-PickerState -Catalog $c } $catalog
            $null = & $script:M { param($s) Invoke-PickerKey -State $s -Key ([ConsoleKeyInfo]::new([char]0, 'RightArrow', $false, $false, $false)) } $state
            (& $script:M { param($s) Format-PickerScreen -State $s -Width 80 -Height 20 } $state).Count | Should -Be 19
        } finally {
            Remove-Item -LiteralPath $bucket -Recurse -Force -ErrorAction Ignore
        }
    }
}

Describe 'Get-InstalledPackageMap (#543)' -Tag 'Light', 'Module' {
    It 'answers from one bulk query per engine' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex { @{ winget = @{ 'test.a1' = @{ Installed = '1.0'; Available = '' } } } }
        Mock -ModuleName MarkMichaelis.ScoopBucket scoop { "Name    Version`n----    -------`nTool    1.0" }
        $map = & $script:M { param($c) Get-InstalledPackageMap -Catalog $c } $script:catalog
        $map['winget|Test.A1']           | Should -Be $true
        $map['winget|Test.A2']           | Should -Be $false
        $map['scoop|MarkMichaelis/Tool'] | Should -Be $true
        $map['manifest|Tweak']           | Should -Be $false
    }

    It 'reports items of an engine that is not on the machine as not installed' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-PackageUpdateIndex { @{} }
        Mock -ModuleName MarkMichaelis.ScoopBucket scoop { '' }
        $map = & $script:M { param($c) Get-InstalledPackageMap -Catalog $c } $script:catalog
        $map['winget|Test.A1'] | Should -Be $false
    }
}

Describe 'Install-Package with no arguments opens the picker (#543)' -Tag 'Light', 'Module' {
    It 'refuses without an interactive console and names the alternatives' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PickerInteractive { $false }
        { Install-Package -DryRun -SkipCompletion -BucketPath $script:bucket } |
            Should -Throw -ExpectedMessage "*install the default set: Install-Package -Name '``*'*"
    }

    It 'installs what the picker returns' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PickerInteractive { $true }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-InstalledPackageMap { @{} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Show-PackagePicker {
            # The owner clears everything, then checks b1.
            & (Get-Module MarkMichaelis.ScoopBucket) {
                param($c, $i)
                $state = New-PickerState -Catalog $c -Installed $i
                Set-PickerSelection -State $state -Mode None
                Switch-PickerNode -State $state -Node (($c.Roots | Where-Object Name -eq 'Root B').Children | Where-Object Name -eq 'b1')
                Get-PickerPlan -State $state
            } $Catalog $Installed
        }

        $rows = @(Install-Package -DryRun -SkipCompletion -IncludeUnchanged -BucketPath $script:bucket)

        $rows.Name | Should -Contain 'b1'
        $rows.Name | Should -Contain 'b2'
        $rows.Name | Should -Not -Contain 'a1'
    }

    It 'refuses before reading the bucket, so the answer is immediate' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PickerInteractive { $false }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages { @() }
        { Install-Package -SkipCompletion -BucketPath $script:bucket } | Should -Throw
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Get-BundlePackages -Times 0 -Exactly
    }

    It 'rejects an empty list of names instead of opening the picker' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Show-PackagePicker { throw 'the picker must not open' }
        { Install-Package -Name @() -DryRun -SkipCompletion -BucketPath $script:bucket } | Should -Throw '*empty*'
    }

    It 'installs nothing, and says so, when nothing is checked' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PickerInteractive { $true }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-InstalledPackageMap { @{} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Show-PackagePicker { [pscustomobject]@{ ByBundle = @{}; Manifests = @() } }
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageInstall { }

        $rows = @(Install-Package -SkipCompletion -BucketPath $script:bucket -InformationVariable info 6>$null)

        $rows.Count | Should -Be 0
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageInstall -Times 0 -Exactly
        ($info | ForEach-Object { "$_" }) -join ' ' | Should -Match 'nothing'
    }

    It 'installs nothing when the picker is cancelled' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Test-PickerInteractive { $true }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-InstalledPackageMap { @{} }
        Mock -ModuleName MarkMichaelis.ScoopBucket Show-PackagePicker { $null }
        Mock -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageInstall { }

        $rows = @(Install-Package -SkipCompletion -BucketPath $script:bucket)

        $rows.Count | Should -Be 0
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Invoke-PackageInstall -Times 0 -Exactly
    }
}
