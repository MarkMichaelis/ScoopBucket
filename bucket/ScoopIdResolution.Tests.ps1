#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Every declared Installer='scoop' Id must resolve to a real manifest
    (issue #466).

.DESCRIPTION
    [Package].GetValidationError() only checks that a scoop Id is a
    syntactically valid '<bucket>/<name>'. 'main/dotnet' satisfied that
    pattern for months while resolving to no manifest anywhere -- scoop's
    main bucket ships `dotnet-sdk` -- so the failure surfaced at install
    time on a developer's machine instead of at test time.

    This file closes that gap in two layers, both Light because both are
    pure filesystem reads with no install side effects:

      1. Bucket-owned ids ('MarkMichaelis/<name>') resolve against THIS
         repository's own bucket tree. Fully hermetic: no scoop, no network,
         no installed buckets -- and it catches a typo in a bucket-owned id
         before the manifest is ever pushed.

      2. Every scoop id -- foreign buckets included -- resolves against the
         locally cloned bucket of the same name under <scoop>\buckets. Only
         ids whose bucket is not cloned on this machine go unverified, and
         the test reports which those were rather than passing silently.
         CI clones main, extras and MarkMichaelis for the Light job, so all
         three are covered there. On a machine with no scoop installation at
         all this layer SKIPS rather than fails: Light is the local pre-push
         gate, and a contributor who has never bootstrapped scoop must not
         see red for something unrelated to their change.

    Deliberately NOT implemented by shelling out to `scoop cat` per id: that
    is one process launch per package and would need scoop on PATH, pushing
    the guard into the Heavy gate where it would only run after merge.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    # Every real scoop-installed package declared anywhere in the bucket.
    $script:scoopPkgs = @(
        Get-Package -BucketPath $PSScriptRoot | Where-Object { $_.Installer -eq 'scoop' }
    )
    $script:ownedPkgs = @(
        $script:scoopPkgs | Where-Object { $_.Id -like 'MarkMichaelis/*' }
    )

    # --- Layer 1 index: this repo's own manifests (foldered since #300). ---
    $script:ownManifests = @(
        Get-ChildItem -Path $PSScriptRoot -Filter '*.json' -File -Recurse |
            ForEach-Object { $_.BaseName }
    )

    # --- Layer 2 index: manifests in each locally cloned scoop bucket. ---
    $script:bucketRoots = @(
        $env:SCOOP_GLOBAL
        $env:SCOOP
        (Join-Path $env:ProgramData 'scoop')
        (Join-Path $env:USERPROFILE 'scoop')
    ) |
        Where-Object { $_ } |
        ForEach-Object { Join-Path $_ 'buckets' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -Unique

    # bucket name -> set of manifest base names. A cloned bucket keeps its
    # manifests under a 'bucket' subdirectory (this repo included); fall back
    # to the clone root for the handful of legacy flat buckets. Scanning only
    # the manifest directory keeps main's 'deprecated' folder -- manifests
    # scoop will NOT install -- out of the index.
    $script:bucketIndex = @{}
    foreach ($root in $script:bucketRoots) {
        foreach ($clone in Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue) {
            if ($script:bucketIndex.ContainsKey($clone.Name)) { continue }
            $manifestDir = Join-Path $clone.FullName 'bucket'
            if (-not (Test-Path -LiteralPath $manifestDir)) { $manifestDir = $clone.FullName }
            $script:bucketIndex[$clone.Name] = @(
                Get-ChildItem -Path $manifestDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.BaseName }
            )
        }
    }
}

Describe 'Declared scoop Ids resolve to a real manifest (issue #466)' -Tag 'Light', 'Bucket' {

    It 'finds scoop-installed packages to check (guards against a vacuous pass)' {
        $script:scoopPkgs.Count | Should -BeGreaterThan 0
    }

    It 'resolves every bucket-owned scoop Id against this repository' {
        # Guard against a vacuous pass: this is the one fully hermetic layer,
        # so it must not quietly reduce to checking nothing.
        $script:ownedPkgs.Count | Should -BeGreaterThan 0

        $offenders = foreach ($pkg in $script:ownedPkgs) {
            $null, $name = $pkg.Id -split '/', 2
            if ($script:ownManifests -notcontains $name) {
                "$($pkg.Bundle)/$($pkg.Name): Id '$($pkg.Id)' has no bucket\**\$name.json in this repo"
            }
        }
        @($offenders) -join "`n" | Should -BeNullOrEmpty `
            -Because 'a MarkMichaelis/<name> id must name a manifest this bucket actually ships'
    }

    It 'resolves every scoop Id against its locally cloned bucket' {
        if ($script:bucketIndex.Keys.Count -eq 0) {
            Set-ItResult -Skipped -Because 'no scoop installation was found on this machine, so there is no bucket to resolve against. CI always clones at least main.'
            return
        }
        $unverified = @()
        $offenders = foreach ($pkg in $script:scoopPkgs) {
            $bucket, $name = $pkg.Id -split '/', 2
            # An EMPTY index means the clone exists but its manifest directory
            # is empty or unreadable (interrupted clone, ACL, odd layout).
            # That is an unverifiable environment, not a missing manifest --
            # reporting it as an offender would turn a broken checkout into a
            # phantom regression.
            if (-not $script:bucketIndex.ContainsKey($bucket) -or $script:bucketIndex[$bucket].Count -eq 0) {
                $unverified += "$($pkg.Id) (bucket '$bucket' not cloned locally, or its manifest directory is empty)"
                continue
            }
            if ($script:bucketIndex[$bucket] -notcontains $name) {
                "$($pkg.Bundle)/$($pkg.Name): Id '$($pkg.Id)' does not resolve -- bucket '$bucket' ships no '$name' manifest"
            }
        }
        if ($unverified) {
            Write-Host "  [unverified] $($unverified -join '; ')"
        }
        @($offenders) -join "`n" | Should -BeNullOrEmpty `
            -Because 'scoop install <bucket>/<name> fails outright when the manifest is absent (#466: main/dotnet)'
    }

    It 'has the main bucket cloned, so the previous test was not vacuous' {
        # The previous test skips itself when no bucket is cloned; this one
        # records whether the broad layer actually ran. It SKIPS rather than
        # fails on a machine without scoop, because the Light tag is this
        # repo's local pre-push gate and a contributor who has never
        # bootstrapped scoop must not see a red test unrelated to their
        # change. CI's Bootstrap Scoop step guarantees main is present, so
        # this never skips there.
        if ($script:bucketIndex.Keys.Count -eq 0) {
            Set-ItResult -Skipped -Because 'no scoop installation found locally; run scoop bootstrap to get full Id-resolution coverage.'
            return
        }
        @($script:bucketIndex.Keys) | Should -Contain 'main' `
            -Because "scoop's own installer clones main, so its presence is the floor for Id resolution"
    }
}
