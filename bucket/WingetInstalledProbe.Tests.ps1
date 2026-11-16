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

    The winget mocks below reproduce that observed behaviour.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force

    $script:module = Get-Module MarkMichaelis.ScoopBucket
    $script:NotFound = -1978335212
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
                    $global:LASTEXITCODE = if ($args -contains '--exact') { 0 } else { $script:NotFound }
                    return 'row'
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
    }

    Context 'an id whose declared case differs from winget''s, so only the non-exact list finds it' {
        BeforeEach {
            Mock -ModuleName MarkMichaelis.ScoopBucket winget {
                $script:calls.Add(($args -join ' '))
                if ($args[0] -eq 'list') {
                    $global:LASTEXITCODE = if ($args -contains '--exact') { $script:NotFound } else { 0 }
                    return 'row'
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
