Describe "Install AddLocalRepoBucket" -Tag 'Light', 'Install' {
    BeforeAll {
        . "$PSScriptRoot\Utils.ps1"
        $manifest = Get-Content "$PSScriptRoot\AddLocalRepoBucket.json" -Raw | ConvertFrom-Json
        $script:installScript = $manifest.installer.script -join "`n"
        $script:uninstallScript = $manifest.uninstaller.script -join "`n"
        if ((scoop bucket list) -match 'LocalRepo') {
            Invoke-Expression $script:uninstallScript | Out-Null
        }
        # scoop refuses to add two buckets that share the same git URL. If
        # MarkMichaelis is already pointing at the canonical scoop bucket URL,
        # this manifest's `scoop bucket add LocalRepo <same-url>` becomes a
        # no-op. Detect that case and skip the install assertion.
        $script:duplicateOfExisting = $false
        $mmDir = Join-Path $env:USERPROFILE 'scoop\buckets\MarkMichaelis'
        if (Test-Path $mmDir) {
            $null = git config --global --add safe.directory ($mmDir -replace '\\','/') 2>&1
            $mmUrl = (git -C $mmDir config --get remote.origin.url 2>$null)
            if ($mmUrl) {
                $mmUrl = $mmUrl.Trim().TrimEnd('.git')
                $targetUrl = ($script:installScript -split '\s+')[-1].TrimEnd('.git')
                if ($mmUrl -eq $targetUrl) { $script:duplicateOfExisting = $true }
            }
        }
    }

    It 'adds the LocalRepo bucket' {
        if ($script:duplicateOfExisting) {
            Set-ItResult -Skipped -Because 'MarkMichaelis bucket already covers this URL; scoop dedup-rejects the second add'
            return
        }
        Invoke-Expression $script:installScript | Out-Null
        (scoop bucket list) | Out-String | Should -Match 'LocalRepo'
    }

    It 'is idempotent on re-run' {
        # scoop bucket add fails if the bucket already exists; per the
        # idempotency contract a 2nd run must not throw.
        { Invoke-Expression $script:installScript 2>&1 | Out-Null } | Should -Not -Throw
    }

    AfterAll {
        if ((scoop bucket list) -match 'LocalRepo') {
            Invoke-Expression $script:uninstallScript | Out-Null
        }
    }
}
