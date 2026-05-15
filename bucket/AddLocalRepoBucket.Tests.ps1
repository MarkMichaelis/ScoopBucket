Describe "Install AddLocalRepoBucket" -Tag 'Light', 'Install' {
    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\ScoopBucket\ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module ScoopBucket -Force }
        $manifest = Get-Content "$PSScriptRoot\AddLocalRepoBucket.json" -Raw | ConvertFrom-Json
        $script:installScript = $manifest.installer.script -join "`n"
        $script:uninstallScript = $manifest.uninstaller.script -join "`n"
        if ((scoop bucket list) -match 'LocalRepo') {
            Invoke-Expression $script:uninstallScript | Out-Null
        }
        # scoop refuses to add two buckets that share the same git URL. If any
        # already-registered bucket points at the canonical URL this manifest
        # would add, `scoop bucket add LocalRepo <same-url>` becomes a no-op.
        # Detect via `scoop bucket list`'s Source column so we work for both
        # per-user (USERPROFILE\scoop) and global (ProgramData\scoop) installs.
        $script:duplicateOfExisting = $false
        $targetUrl = ($script:installScript -split '\s+')[-1].TrimEnd('.git')
        $existingUrls = @(scoop bucket list | ForEach-Object {
            if ($_.PSObject.Properties['Source']) { $_.Source } else { $null }
        } | Where-Object { $_ } | ForEach-Object { $_.ToString().Trim().TrimEnd('.git') })
        if ($existingUrls -contains $targetUrl) { $script:duplicateOfExisting = $true }
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
