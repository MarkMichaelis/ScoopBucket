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

# Playwright ships as two separate artefacts:
#   1. `playwright`      -- the browser DRIVER: the npm package carrying the
#                           `playwright` CLI and the module other tools
#                           resolve as require('playwright').
#   2. Browser binaries  -- downloaded out-of-band by `playwright install`
#                           into a per-user cache (%USERPROFILE%\AppData\
#                           Local\ms-playwright), NEVER by npm itself.
# The npmGlobal engine handles (1); (2) lives in ConfigScript rather than
# PostInstallScript so the browser download is re-checked on every update
# too -- a newer driver pins newer browser builds, and an npm-only upgrade
# would otherwise leave the CLI pointing at a browser revision that is not
# on disk. `playwright install chromium` is a no-op once the matching
# revision is cached, which satisfies the idempotency contract.
#
# NOT `@playwright/test`, which is a DIFFERENT package: the test runner.
# Two reasons it does not belong here (#423).
#   * It is the per-repo half. A project's tests pin a runner version and a
#     matching browser revision, so the runner belongs in that project's own
#     package.json. This bucket provisions the machine, and what the machine
#     needs is the driver the @playwright/mcp server drives a browser with.
#   * It does not make `playwright` resolvable. The runner depends on the
#     driver and carries a nested copy, but a nested dependency is not
#     resolvable as `playwright` from the global root -- that nesting is an
#     npm implementation detail. Anything doing require('playwright')
#     against the global root fails while the install reports success.
# Note that `playwright --version` succeeds either way: with the runner
# installed, that command is its bin shim. A resolving COMMAND does not
# verify a resolvable MODULE, which is what made the wrong package look fine.
#
# Only Chromium is downloaded: it is what the Playwright MCP server drives,
# and the full three-browser set costs several GB. Run
# `playwright install firefox webkit` by hand for cross-browser runs.

# Migration off the wrong package (#423). Both packages publish a `playwright`
# bin, so npm refuses to install the driver while the runner owns those shims:
#     npm error EEXIST: file already exists
#     npm error File exists: ...\npm\playwright.ps1
# Nothing downstream recovers from that -- the engine just reports a failed
# install -- so the conflicting global runner is removed first. This is the
# bucket cleaning up after itself: #417 is what installed it globally. A
# project's own `@playwright/test`, in its package.json where it belongs, is
# untouched; only the global copy goes.
#
# Top-level rather than a hook because it has to run BEFORE the engine install,
# and there is no pre-install hook. `scoop install` / `scoop update` both run
# this whole script, so the migration is covered either way. It is a no-op once
# the runner is gone, which keeps the script twice-runnable.
$npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
if ($npmCommand) {
    $globalList = & npm.cmd list -g --depth=0 2>$null | Out-String
    if ($globalList -match '(?m)^\S+\s+@playwright/test@') {
        Write-Host 'Removing the global @playwright/test; it owns the `playwright` command the driver needs...'
        & npm.cmd uninstall --global '@playwright/test' 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm uninstall --global @playwright/test exited with $LASTEXITCODE; the driver install below will fail with EEXIST until it is removed by hand."
        }
    }
}

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Playwright'
        Installer   = 'npmGlobal'
        Id          = 'playwright'
        CliCommands = @('playwright')
        Completion  = 'auto'
        Notes       = 'Browser driver for the @playwright/mcp server: the `playwright` npm package, which carries the CLI and the module other tools resolve as require("playwright"). Deliberately NOT @playwright/test -- that is the test runner, a per-project dependency, and it does not make `playwright` resolvable from the global root (#423). Requires Node.js/npm on PATH. playwright has no `completion powershell` subcommand and no PSCompletions catalog entry, so the completer is hand-curated. ConfigScript downloads the Chromium browser binaries (the npm package alone ships no browsers).'
        ExpectedCompletions = @{ playwright = @('test','install','codegen','show-report') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName playwright -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'test','install','install-deps','uninstall','codegen','open','screenshot','pdf',
        'show-report','merge-reports','clear-cache','show-trace','trace','cr','ff','wk',
        'init-agents','--help','-h','--version','-V',
        '--browser','--headed','--project','--reporter','--workers','--debug','--ui','--grep',
        '--list','--repeat-each','--retries','--timeout','--update-snapshots','--trace','--config'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
        ConfigScript = {
            $playwrightCmd = Get-Command playwright -ErrorAction SilentlyContinue
            if (-not $playwrightCmd) {
                # npm's global shim directory may not be on the PATH of the
                # session that just installed it. Fall back to npx, which
                # resolves the globally installed package itself.
                if (Get-Command npx -ErrorAction SilentlyContinue) {
                    Write-Host 'Downloading the Chromium browser for Playwright (via npx)...'
                    & npx.cmd -y 'playwright' install chromium
                }
                else {
                    Write-Warning 'Neither playwright nor npx is on PATH; skipping the Chromium browser download. Run `playwright install chromium` once Node.js is available.'
                    return
                }
            }
            else {
                Write-Host 'Downloading the Chromium browser for Playwright...'
                & playwright.cmd install chromium
            }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "playwright install chromium exited with code $LASTEXITCODE; browser-driving tools (including the Playwright MCP server) may fail at runtime."
            }
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'Playwright'
