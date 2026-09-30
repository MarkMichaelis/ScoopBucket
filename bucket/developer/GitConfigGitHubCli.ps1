#region MarkMichaelis.ScoopBucket bundle module import (scoop-portable; see README)
$scoopBucketModule = 'MarkMichaelis.ScoopBucket'
$scoopBucketPsd1 = Join-Path $PSScriptRoot "..\..\module\$scoopBucketModule\$scoopBucketModule.psd1"
if (-not (Test-Path $scoopBucketPsd1)) {
    $scoopBucketRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $PSScriptRoot '..\..\..' }
    $scoopBucketFound = Get-ChildItem -Path (Join-Path $scoopBucketRoot "buckets\*\module\$scoopBucketModule\$scoopBucketModule.psd1") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($scoopBucketFound) { $scoopBucketPsd1 = $scoopBucketFound.FullName }
}
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module $scoopBucketModule -Force }
#endregion MarkMichaelis.ScoopBucket bundle module import


Function Resolve-GhAliasFile {
    # Returns the path to the gh-aliases.yml shipped alongside this script, or
    # $null when it is missing. Scoop downloads both files into the same app
    # dir (see GitConfigGitHubCli.json), and a repo checkout has them as
    # siblings too, so $PSScriptRoot resolves it in both layouts.
    [CmdletBinding()]
    param()
    $yml = Join-Path $PSScriptRoot 'gh-aliases.yml'
    if (Test-Path -LiteralPath $yml -PathType Leaf) { return $yml }
    return $null
}

Function Test-GhAuthenticated {
    # Reports whether the local `gh` holds a usable token. `gh auth status`
    # exits 0 when at least one host is authenticated and non-zero otherwise,
    # and that exit code is the only signal gh offers. The probe is injected so
    # the callers' guard logic is unit-testable with mocked exit codes instead
    # of shelling out to gh (which would also hit the network).
    [CmdletBinding()]
    param(
        [ValidateNotNull()]
        [scriptblock] $StatusProbe = { & gh auth status 2>&1 | Out-Null; $LASTEXITCODE }
    )
    $exitCode = & $StatusProbe | Select-Object -Last 1
    return ($exitCode -eq 0)
}

Function Invoke-GhAuthSetupGit {
    # Thin seam over the one native call that mutates global git config, so the
    # guards in Set-GitCredentialHelperFromGitHubCli can be exercised under a
    # mock without ever rewriting the caller's ~/.gitconfig.
    [CmdletBinding()]
    param()
    $output = & gh auth setup-git 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
    }
}

Function Set-GitCredentialHelperFromGitHubCli {
    # Points git's credential helper at `gh` (`gh auth setup-git`) so HTTPS
    # remotes authenticate from gh's token instead of popping the Git Credential
    # Manager "pick a helper" GUI dialog -- which on a fresh machine is what an
    # empty global `credential.helper` over the system-wide `helper-selector`
    # produces, and which hangs any non-interactive git operation (issue #434).
    #
    # Unattended-safe: the irreducibly-human step is `gh auth login` (OAuth
    # device flow), NOT this one. `gh auth setup-git` only writes config: no
    # prompts, no network, and idempotent (it rewrites the same
    # credential.<host>.helper entries with --replace-all rather than appending).
    # A never-logged-in machine therefore warns and skips rather than hanging or
    # failing the bundle.
    #
    # CAVEAT: `gh auth setup-git` records an absolute path to the gh binary in
    # credential.helper. When gh came from scoop that path is
    # C:\ProgramData\scoop\apps\gh\current\bin\gh.exe, so `scoop uninstall gh`
    # leaves git auth pointing at a missing executable -- re-run this script (or
    # `gh auth setup-git`) after moving or removing gh. The path gh records is
    # its OWN location, not the shim that launched it, so a machine carrying both
    # a scoop shim and C:\Program Files\GitHub CLI\gh.exe gets whichever install
    # PATH resolved first -- the PATH entry that won is echoed below to make that
    # visible.
    [CmdletBinding()]
    param()
    $ghCommand = Get-Command gh -ErrorAction Ignore
    if (-not $ghCommand) {
        Write-Warning "gh not found. Skipping git credential helper configuration."
        return
    }

    if (-not (Test-GhAuthenticated)) {
        Write-Warning "gh is not authenticated. Run ``gh auth login`` once, then re-run. Skipping git credential helper configuration."
        return
    }

    $result = Invoke-GhAuthSetupGit
    if ($result.ExitCode -ne 0) {
        Write-Warning "gh auth setup-git failed (exit $($result.ExitCode)): $($result.Output)"
        return
    }

    Write-Host "git credential helper configured via gh auth setup-git (from $($ghCommand.Source))."
}

Function Set-GitHubCliAlias {
    # Applies this bucket's per-user `gh` aliases. gh keeps aliases in
    # %APPDATA%\GitHub CLI\config.yml -- per-user state, so this runs
    # unelevated and is deliberately NOT machine-scoped like the CLI install
    # itself (`winget install --scope machine GitHub.cli` in GitConfigure.ps1).
    if (-not (Get-Command gh -ErrorAction Ignore)) {
        Write-Warning "gh not found. Skipping GitHub CLI alias configuration."
        return
    }

    $yml = Resolve-GhAliasFile
    if (-not $yml) {
        Write-Warning "gh-aliases.yml not found alongside GitConfigGitHubCli.ps1. Skipping GitHub CLI alias configuration."
        return
    }

    # `gh alias import` over `gh alias set`: the expansions are POSIX shell
    # one-liners dense with single quotes and `$`, and handing gh a file on
    # disk sidesteps PowerShell native-argument quoting entirely. --clobber
    # makes re-runs idempotent by overwriting same-named aliases rather than
    # failing on the second install.
    $output = & gh alias import $yml --clobber 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gh alias import failed (exit $LASTEXITCODE): $output"
        return
    }

    $names = @(
        Get-Content -LiteralPath $yml |
            Where-Object { $_ -match '^(?<name>[A-Za-z0-9_-]+):' } |
            ForEach-Object { $Matches.name }
    )
    Write-Host "GitHub CLI aliases configured: $($names -join ', ')"
}

Function Invoke-GitConfigGitHubCli {
    # All per-user `gh`-driven configuration this bucket owns. Each step carries
    # its own guards and warns rather than throwing, so they stay independent: a
    # missing gh-aliases.yml must not cost you the credential helper, and an
    # unauthenticated gh must not cost you the aliases.
    [CmdletBinding()]
    param()
    Set-GitHubCliAlias
    Set-GitCredentialHelperFromGitHubCli
}
Invoke-GitConfigGitHubCli
