Describe "Install AddMarkMichaelisScoopBucket" -Tag 'Light', 'Install' {
    BeforeAll {
        . "$PSScriptRoot\Utils.ps1"
        $manifest = Get-Content "$PSScriptRoot\AddMarkMichaelisScoopBucket.json" -Raw | ConvertFrom-Json
        $script:installScript = $manifest.installer.script -join "`n"
        # Most users running these tests already have the MarkMichaelis bucket
        # added (that's how they got the test files). Avoid disturbing the host:
        # if the bucket is present, skip the install assertions instead of
        # removing the working bucket.
        $script:hadBucket = [bool]((scoop bucket list) -match 'MarkMichaelis')
    }

    It 'adds the MarkMichaelis bucket' -Skip:$script:hadBucket {
        Invoke-Expression $script:installScript | Out-Null
        (scoop bucket list) | Out-String | Should -Match 'MarkMichaelis'
    }

    It 'is idempotent on re-run' {
        # scoop bucket add fails if the bucket already exists; per the
        # idempotency contract a 2nd run must not throw.
        { Invoke-Expression $script:installScript 2>&1 | Out-Null } | Should -Not -Throw
    }

    AfterAll {
        if (-not $script:hadBucket) {
            if ((scoop bucket list) -match 'MarkMichaelis') {
                scoop bucket rm MarkMichaelis
            }
        }
    }
}
