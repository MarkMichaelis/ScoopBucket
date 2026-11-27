<#
.SYNOPSIS
    Light coverage for the winget engine's "is it installed?" probe (#516).

.DESCRIPTION
    winget v1.29 does not find Microsoft Store ids with `winget list --id <Id>`;
    only `--exact` finds them. Without it the install path re-runs the install
    every time, the update path reports NotInstalled and never upgrades, and
    the uninstall path skips the removal.

    `--exact` is also case-sensitive (`winget list --id git.git --exact` misses
    Git.Git), so the probe must keep the old non-exact match as a fallback or a
    declaration with a differently-cased id would regress.

    The non-exact match is a substring match over every identity winget knows,
    a Store app's package family included (#553): with the ChatGPT Store app
    (family OpenAI.Codex_2p2nqsd0c76g0) installed, `winget list --id
    OpenAI.Codex` exits 0 and lists ChatGPT, although Codex CLI (winget
    OpenAI.Codex) is not installed. The fallback therefore counts only a listed
    row that carries the declared id, and upgrade and uninstall then name that
    row's id with --exact, so they cannot act on the Store app.

    The winget mocks below reproduce that observed behaviour, with the table
    winget printed on 2026-11-26 (v1.30).
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    $script:module = Get-Module MarkMichaelis.ScoopBucket
    $script:NotFound = -1978335212

    function New-WingetListTable {
        # The fixed-width table `winget list` prints when its output is redirected.
        param([string]$Name, [string]$Id, [string]$Version, [string]$Source = 'winget')
        $nameW = [Math]::Max(4, $Name.Length) + 1
        $idW = [Math]::Max(2, $Id.Length) + 1
        $verW = [Math]::Max(7, $Version.Length) + 1
        $header = 'Name'.PadRight($nameW) + 'Id'.PadRight($idW) + 'Version'.PadRight($verW) + 'Source'
        @($header, ('-' * $header.Length), ($Name.PadRight($nameW) + $Id.PadRight($idW) + $Version.PadRight($verW) + $Source))
    }
}

Describe 'winget installed probe (#516)' -Tag 'Light', 'Module' {

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
    }

    Context 'a Store app that only an exact-match list finds' {
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:calls.Add(($args -join ' '))
                if ($args[0] -eq 'list') {
                    if ($args -contains '--exact') {
                        $global:LASTEXITCODE = 0
                        return New-WingetListTable -Name 'ChatGPT' -Id '9PLM9XGG6VKS' -Version '26.1120.6357.0' -Source 'msstore'
                    }
                    $global:LASTEXITCODE = $script:NotFound
                    return 'No installed package found matching input criteria.'
                }
                $global:LASTEXITCODE = 0
                return ''
            }
            $script:pkg = [Package]@{ Name = 'Store App'; Installer = 'winget'; Id = '9PLM9XGG6VKS'; Source = 'msstore' }
        }

        It 'install reports AlreadyInstalled and does not run winget install' {
            $r = & $script:module { param($p) Install-WingetPackage -Package $p } $script:pkg
            $r.State | Should -Be 'AlreadyInstalled'
            @($script:calls | Where-Object { $_ -like 'install *' }).Count | Should -Be 0
        }

        It 'update runs winget upgrade instead of reporting NotInstalled' {
            $r = & $script:module { param($p) Update-WingetPackage -Package $p -TimeoutMinutes 0 } $script:pkg
            $r.State | Should -Be 'Updated'
            @($script:calls | Where-Object { $_ -like 'upgrade *' }).Count | Should -Be 1
        }

        It 'uninstall runs winget uninstall instead of reporting NotInstalled' {
            $r = & $script:module { param($p) Uninstall-WingetPackage -Package $p } $script:pkg 6>$null
            $r.State | Should -Be 'Uninstalled'
            @($script:calls | Where-Object { $_ -like 'uninstall *' }).Count | Should -Be 1
        }

        It 'keeps --source msstore on the exact probe' {
            $null = & $script:module { param($p) Install-WingetPackage -Package $p } $script:pkg
            $probe = @($script:calls | Where-Object { $_ -like 'list *--exact*' })[0]
            $probe | Should -Match '--source msstore'
            $probe | Should -Match '--id 9PLM9XGG6VKS'
        }

        It 'upgrades and uninstalls the exact id the probe found' {
            $null = & $script:module { param($p) Update-WingetPackage -Package $p -TimeoutMinutes 0 } $script:pkg
            $null = & $script:module { param($p) Uninstall-WingetPackage -Package $p } $script:pkg 6>$null
            @($script:calls | Where-Object { $_ -like 'upgrade *' })[0] | Should -Match '--id 9PLM9XGG6VKS --exact'
            @($script:calls | Where-Object { $_ -like 'uninstall *' })[0] | Should -Match '--id 9PLM9XGG6VKS --exact'
        }
    }

    Context 'an id whose declared case differs from winget''s, so only the non-exact list finds it' {
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:calls.Add(($args -join ' '))
                if ($args[0] -eq 'list') {
                    if ($args -contains '--exact') {
                        $global:LASTEXITCODE = $script:NotFound
                        return 'No installed package found matching input criteria.'
                    }
                    $global:LASTEXITCODE = 0
                    return New-WingetListTable -Name 'Git' -Id 'Git.Git' -Version '2.56.1'
                }
                $global:LASTEXITCODE = 0
                return ''
            }
            $script:pkg = [Package]@{ Name = 'Git'; Installer = 'winget'; Id = 'git.git' }
        }

        It 'install still reports AlreadyInstalled' {
            $r = & $script:module { param($p) Install-WingetPackage -Package $p } $script:pkg
            $r.State | Should -Be 'AlreadyInstalled'
        }

        It 'update still runs winget upgrade' {
            $r = & $script:module { param($p) Update-WingetPackage -Package $p -TimeoutMinutes 0 } $script:pkg
            $r.State | Should -Be 'Updated'
        }

        It 'upgrades and uninstalls the id as winget lists it, matched exactly' {
            $null = & $script:module { param($p) Update-WingetPackage -Package $p -TimeoutMinutes 0 } $script:pkg
            $null = & $script:module { param($p) Uninstall-WingetPackage -Package $p } $script:pkg 6>$null
            @($script:calls | Where-Object { $_ -like 'upgrade *' })[0] | Should -Match '--id Git\.Git --exact'
            @($script:calls | Where-Object { $_ -like 'uninstall *' })[0] | Should -Match '--id Git\.Git --exact'
        }
    }

    Context 'a non-exact list that exits 0 with output that is not a table' {
        # Without a table there is no row to check, so the probe keeps its
        # pre-#553 behaviour and trusts the exit code.
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:calls.Add(($args -join ' '))
                if ($args[0] -eq 'list') {
                    $global:LASTEXITCODE = if ($args -contains '--exact') { $script:NotFound } else { 0 }
                    return 'an output layout the parser does not know'
                }
                $global:LASTEXITCODE = 0
                return ''
            }
            $script:pkg = [Package]@{ Name = 'Widget'; Installer = 'winget'; Id = 'Vendor.Widget' }
        }

        It 'install reports AlreadyInstalled' {
            $r = & $script:module { param($p) Install-WingetPackage -Package $p } $script:pkg
            $r.State | Should -Be 'AlreadyInstalled'
        }

        It 'update names the declared id with --exact' {
            $r = & $script:module { param($p) Update-WingetPackage -Package $p -TimeoutMinutes 0 } $script:pkg
            $r.State | Should -Be 'Updated'
            @($script:calls | Where-Object { $_ -like 'upgrade *' })[0] | Should -Match '--id Vendor\.Widget --exact'
        }
    }

    Context 'a non-exact list that finds only another package whose identity contains the id (#553)' {
        # Observed on Dakar: Codex CLI not installed, the ChatGPT Store app
        # (package family OpenAI.Codex_2p2nqsd0c76g0) installed.
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:calls.Add(($args -join ' '))
                if ($args[0] -eq 'list') {
                    if ($args -contains '--exact') {
                        $global:LASTEXITCODE = $script:NotFound
                        return 'No installed package found matching input criteria.'
                    }
                    $global:LASTEXITCODE = 0
                    return New-WingetListTable -Name 'ChatGPT' -Id '9PLM9XGG6VKS' -Version '26.1120.6357.0' -Source 'msstore'
                }
                $global:LASTEXITCODE = 0
                return ''
            }
            $script:pkg = [Package]@{ Name = 'Codex CLI'; Installer = 'winget'; Id = 'OpenAI.Codex' }
        }

        It 'install runs winget install instead of reporting AlreadyInstalled' {
            $r = & $script:module { param($p) Install-WingetPackage -Package $p } $script:pkg 6>$null
            $r.State | Should -Be 'Installed'
            @($script:calls | Where-Object { $_ -like 'install *' }).Count | Should -Be 1
        }

        It 'update reports NotInstalled, naming the package winget listed instead, and runs no upgrade' {
            $r = & $script:module { param($p) Update-WingetPackage -Package $p -TimeoutMinutes 0 } $script:pkg
            $r.State  | Should -Be 'NotInstalled'
            $r.Reason | Should -Match '9PLM9XGG6VKS'
            @($script:calls | Where-Object { $_ -like 'upgrade *' }).Count | Should -Be 0
        }

        It 'uninstall reports NotInstalled and never runs winget uninstall, which would remove the Store app' {
            $r = & $script:module { param($p) Uninstall-WingetPackage -Package $p } $script:pkg 6>$null
            $r.State | Should -Be 'NotInstalled'
            @($script:calls | Where-Object { $_ -like 'uninstall *' }).Count | Should -Be 0
        }

        It 'presence reports the package absent' {
            $r = & $script:module { param($p) Get-PackagePresence -Package $p } $script:pkg
            $r.Present | Should -BeFalse
        }
    }

    Context 'a package neither list finds' {
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:calls.Add(($args -join ' '))
                $global:LASTEXITCODE = if ($args[0] -eq 'list') { $script:NotFound } else { 0 }
                return ''
            }
            $script:pkg = [Package]@{ Name = 'Missing'; Installer = 'winget'; Id = 'Nobody.Missing' }
        }

        It 'update reports NotInstalled with the exit code' {
            $r = & $script:module { param($p) Update-WingetPackage -Package $p -TimeoutMinutes 0 } $script:pkg
            $r.State  | Should -Be 'NotInstalled'
            $r.Reason | Should -Match ([regex]::Escape("$script:NotFound"))
        }

        It 'uninstall reports NotInstalled and runs no uninstall' {
            $r = & $script:module { param($p) Uninstall-WingetPackage -Package $p } $script:pkg
            $r.State | Should -Be 'NotInstalled'
            @($script:calls | Where-Object { $_ -like 'uninstall *' }).Count | Should -Be 0
        }

        It 'install goes ahead and runs winget install' {
            $r = & $script:module { param($p) Install-WingetPackage -Package $p } $script:pkg 6>$null
            $r.State | Should -Be 'Installed'
        }
    }
}
