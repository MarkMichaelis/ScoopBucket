<#
.SYNOPSIS
    Light-suite Pester coverage for the private ConfigScript live-output capture
    helpers (#352).

.DESCRIPTION
    Pins the behavior that the AIAgents MCP noise problem depends on:

      * Invoke-ConfigScriptCaptured collects a ConfigScript's Write-Host + native
        stdout into the caller's buffer WITHOUT leaking onto the success (object)
        pipeline -- so a clean run shows only the result table.
      * Genuine warnings are re-emitted (persist past the transient pane).
      * A throwing ConfigScript leaves the lines captured before the throw in the
        buffer (so the failure flush + log have something to show) and the throw
        propagates to the caller.
      * The per-run failure-log file name follows the agreed sortable format.
      * Get-FailureLogPath falls back to $env:TEMP when the preferred directory is
        not writable, and never throws.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path $PSScriptRoot '..\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
}

Describe 'Invoke-ConfigScriptCaptured' {
    It 'captures Write-Host and native-style stdout into the buffer without polluting the success pipeline' {
        $buf = New-Object System.Collections.Generic.List[string]
        $sb = { param($p) Write-Host 'npm: added 3 packages'; Write-Output 'tool-stdout-line' }

        $emitted = & $script:mod {
            param($sb, $buf)
            Invoke-ConfigScriptCaptured -ConfigScript $sb -Package ([pscustomobject]@{ Name = 'X' }) -Buffer $buf -Activity 'Update-Package'
        } $sb $buf 3>$null

        # Nothing reaches the cmdlet's object pipeline.
        @($emitted) | Should -BeNullOrEmpty
        # Both lines were captured into the buffer.
        $buf | Should -Contain 'npm: added 3 packages'
        $buf | Should -Contain 'tool-stdout-line'
    }

    It 're-emits genuine warnings so they persist past the transient pane' {
        $buf = New-Object System.Collections.Generic.List[string]
        $sb = { param($p) Write-Warning 'deprecated package' }

        $warnings = & $script:mod {
            param($sb, $buf)
            Invoke-ConfigScriptCaptured -ConfigScript $sb -Package ([pscustomobject]@{ Name = 'X' }) -Buffer $buf -Activity 'Update-Package'
        } $sb $buf 3>&1 2>$null

        @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) |
            Should -Not -BeNullOrEmpty
        $buf | Should -Contain 'deprecated package'
    }

    It 'leaves pre-throw lines in the buffer and lets the throw propagate' {
        $buf = New-Object System.Collections.Generic.List[string]
        $sb = { param($p) Write-Host 'before the boom'; throw 'kaboom' }

        {
            & $script:mod {
                param($sb, $buf)
                Invoke-ConfigScriptCaptured -ConfigScript $sb -Package ([pscustomobject]@{ Name = 'X' }) -Buffer $buf -Activity 'Update-Package'
            } $sb $buf 3>$null
        } | Should -Throw

        $buf | Should -Contain 'before the boom'
    }
}

Describe 'ConvertTo-CapturedLine' {
    It 'renders a warning record as its message text' {
        $rec = [System.Management.Automation.WarningRecord]::new('hello warn')
        $line = & $script:mod { param($r) ConvertTo-CapturedLine $r } $rec
        $line | Should -Be 'hello warn'
    }

    It 'returns $null for whitespace-only input' {
        $line = & $script:mod { ConvertTo-CapturedLine '   ' }
        $line | Should -BeNullOrEmpty
    }
}

Describe 'Get-FailureLogFileName' {
    It 'produces the sortable ScoopBucket-<Verb>-Package-<timestamp>-failures.log name' {
        $ts = [datetime]'2026-01-02T03:04:05'
        $name = & $script:mod { param($t) Get-FailureLogFileName -Verb 'Update' -Timestamp $t } $ts
        $name | Should -Be 'ScoopBucket-Update-Package-20260102-030405-failures.log'
    }

    It 'reflects the Install verb' {
        $ts = [datetime]'2026-01-02T03:04:05'
        $name = & $script:mod { param($t) Get-FailureLogFileName -Verb 'Install' -Timestamp $t } $ts
        $name | Should -Match '^ScoopBucket-Install-Package-'
    }
}

Describe 'Get-FailureLogPath' {
    It 'uses the preferred directory when it is writable' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sb-pref-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $path = & $script:mod {
                param($f, $pref, $fb) Get-FailureLogPath -FileName $f -PreferredDirectory $pref -FallbackDirectory $fb
            } 'x.log' $tmp $env:TEMP
            (Split-Path $path -Parent) | Should -Be $tmp
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to the fallback directory when the preferred directory is not writable' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("sb-missing-" + [guid]::NewGuid().ToString('N'))
        $path = & $script:mod {
            param($f, $pref, $fb) Get-FailureLogPath -FileName $f -PreferredDirectory $pref -FallbackDirectory $fb
        } 'x.log' $missing $env:TEMP
        (Split-Path $path -Parent) | Should -Be $env:TEMP
    }
}

Describe 'Write-FailureLog' {
    It 'writes a UTF-8 (no BOM) log containing each failed package full output' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("sb-log-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'failures.log'
        try {
            $failures = @(
                [pscustomobject]@{ Name = 'MCP Server Configuration'; Reason = 'ConfigScript threw: boom'; Output = "line-one`nline-two" }
            )
            $written = & $script:mod {
                param($p, $fs) Write-FailureLog -Path $p -Verb 'Update' -Failures $fs
            } $path $failures

            $written | Should -Be $path
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match 'MCP Server Configuration'
            $content | Should -Match 'line-one'
            $content | Should -Match 'line-two'

            # No UTF-8 BOM (first 3 bytes must not be EF BB BF).
            $bytes = [System.IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
