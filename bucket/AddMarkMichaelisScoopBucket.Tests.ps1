Describe "Install AddMarkMichaelisScoopBucket" -Tag 'Light', 'Install' {
    BeforeAll {
        # Skip the suite if scoop isn't usable in this environment (e.g. CI
        # runners that haven't bootstrapped scoop yet). Utils.ps1's `scoop`
        # wrapper shells out to `scoop.ps1`, which produces a hard
        # CommandNotFoundException when scoop isn't on PATH.
        $script:scoopAvailable = [bool](Get-Command scoop.ps1 -ErrorAction Ignore)
        if (-not $script:scoopAvailable) {
            $script:hadBucket = $false
            return
        }

        . "$PSScriptRoot\Utils.ps1"
        $manifest = Get-Content "$PSScriptRoot\AddMarkMichaelisScoopBucket.json" -Raw | ConvertFrom-Json
        $script:installScript = $manifest.installer.script -join "`n"
        # Most users running these tests already have the MarkMichaelis bucket
        # added (that's how they got the test files). Avoid disturbing the host:
        # if the bucket is present, skip the install assertions instead of
        # removing the working bucket.
        $script:hadBucket = [bool]((scoop bucket list) -match 'MarkMichaelis')
    }

    It 'adds the MarkMichaelis bucket' {
        if (-not $script:scoopAvailable) {
            Set-ItResult -Skipped -Because 'scoop.ps1 is not available on PATH'
            return
        }
        if ($script:hadBucket) {
            Set-ItResult -Skipped -Because 'MarkMichaelis bucket is already registered on this host'
            return
        }
        Invoke-Expression $script:installScript | Out-Null
        (scoop bucket list) | Out-String | Should -Match 'MarkMichaelis'
    }

    It 'is idempotent on re-run' {
        if (-not $script:scoopAvailable) {
            Set-ItResult -Skipped -Because 'scoop.ps1 is not available on PATH'
            return
        }
        # scoop bucket add fails if the bucket already exists; per the
        # idempotency contract a 2nd run must not throw.
        { Invoke-Expression $script:installScript 2>&1 | Out-Null } | Should -Not -Throw
    }

    AfterAll {
        if (-not $script:scoopAvailable) { return }
        if (-not $script:hadBucket) {
            if ((scoop bucket list) -match 'MarkMichaelis') {
                scoop bucket rm MarkMichaelis
            }
        }
    }
}
