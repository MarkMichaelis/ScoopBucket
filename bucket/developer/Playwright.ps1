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
# The package's own install scriptblock handles (1) -- see the migration note
# below for why not the npmGlobal engine. (2) lives in ConfigScript rather
# than PostInstallScript so the browser download is re-checked on every update
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

# MIGRATION OFF THE WRONG PACKAGE, and why it is not the npmGlobal engine.
#
# Both packages publish a `playwright` bin, so npm refuses to install the
# driver while a global runner owns those shims:
#     npm error EEXIST: file already exists
#     npm error File exists: ...\npm\playwright.ps1
# Nothing downstream recovers -- the engine reports a failed install -- so the
# conflicting global runner has to go FIRST. The bucket is cleaning up after
# itself here: #417 is what installed it globally. Only the GLOBAL copy goes;
# a project's own dependency, in its package.json where it belongs, is never
# touched.
#
# There is no pre-install hook, and top-level code in a bundle script is NOT a
# substitute: Get-BundlePackageObjects deliberately harvests only the
# `$Packages` assignment via the AST and never runs the rest of the file, so
# anything top-level is silently skipped by Install-Package / Update-Package --
# this module's primary interface. (That is the same gap ConfigScript exists to
# close; see README.) Only `scoop install` would have run it.
#
# So the package drives its own install: Installer='custom' with the migration
# and the npm install together in one scriptblock, which every path executes.
# PostUpdateScript is the matching update hook -- for a custom package it is
# the ONLY one, and without it Update-Package reports NoAutoUpdateSupport.
# CustomUninstallScript keeps removal symmetric.
#
# The two scriptblocks differ on purpose: install short-circuits when the
# driver is already there (that is the idempotency contract), while update
# always re-runs `npm install --global`, which IS npm's upgrade path.

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Playwright'
        Installer   = 'custom'
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
        'open','codegen','install','install-deps','uninstall','cr','ff','wk',
        'screenshot','pdf','show-trace','trace','cli','mcp','test','show-report',
        'merge-reports','clear-cache','init-agents','init-skills','help',
        '--help','-h','--version','-V',
        '--browser','--headed','--project','--reporter','--workers','--debug','--ui','--grep',
        '--list','--repeat-each','--retries','--timeout','--update-snapshots','--trace','--config'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
        CustomInstallScript = {
            if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
                throw 'npm is not on PATH. Install Node.js first.'
            }
            $globalList = & npm.cmd list -g --depth=0 2>$null | Out-String

            # The conflicting global runner must go before npm will place the
            # driver's bin. Only the global copy; projects keep their own.
            if ($globalList -match '(?m)^\S+\s+@playwright/test@') {
                Write-Host 'Removing the global @playwright/test; it owns the `playwright` command the driver needs...'
                & npm.cmd uninstall --global '@playwright/test' 2>&1 | ForEach-Object { Write-Host "  $_" }
                if ($LASTEXITCODE -ne 0) {
                    throw "npm uninstall --global @playwright/test exited with $LASTEXITCODE; installing the driver would fail with EEXIST."
                }
            }

            if ($globalList -match '(?m)^\S+\s+playwright@') {
                Write-Host '  playwright is already installed globally.'
                return
            }
            Write-Host '  npm install --global playwright'
            & npm.cmd install --global playwright
            if ($LASTEXITCODE -ne 0) { throw "npm install --global playwright exited with $LASTEXITCODE." }
        }
        # The only update hook a custom package gets. Same migration, but it
        # always re-runs the install: for npm that IS the upgrade path.
        PostUpdateScript = {
            if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
                throw 'npm is not on PATH. Install Node.js first.'
            }
            $globalList = & npm.cmd list -g --depth=0 2>$null | Out-String
            if ($globalList -match '(?m)^\S+\s+@playwright/test@') {
                Write-Host 'Removing the global @playwright/test; it owns the `playwright` command the driver needs...'
                & npm.cmd uninstall --global '@playwright/test' 2>&1 | ForEach-Object { Write-Host "  $_" }
                if ($LASTEXITCODE -ne 0) {
                    throw "npm uninstall --global @playwright/test exited with $LASTEXITCODE; installing the driver would fail with EEXIST."
                }
            }
            Write-Host '  npm install --global playwright'
            & npm.cmd install --global playwright
            if ($LASTEXITCODE -ne 0) { throw "npm install --global playwright exited with $LASTEXITCODE." }
        }
        CustomUninstallScript = {
            if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
                throw 'npm is not on PATH.'
            }
            & npm.cmd uninstall --global playwright
            if ($LASTEXITCODE -ne 0) { throw "npm uninstall --global playwright exited with $LASTEXITCODE." }
        }
        ConfigScript = {
            # Drive the shim in npm's OWN global bin, not whatever `playwright`
            # resolves to on PATH. On a machine with a second Node install,
            # `Get-Command playwright` can point at a different tree entirely --
            # so the browser download would be requested from a binary this
            # package never installed, for a browser revision it never pins.
            $shim = $null
            if (Get-Command npm.cmd -ErrorAction SilentlyContinue) {
                $prefix = (& npm.cmd prefix -g 2>$null | Select-Object -First 1)
                if ($prefix) {
                    $candidate = Join-Path $prefix 'playwright.cmd'
                    if (Test-Path $candidate) { $shim = $candidate }
                }
            }
            if ($shim) {
                Write-Host 'Downloading the Chromium browser for Playwright...'
                & $shim install chromium
            }
            elseif (Get-Command npx -ErrorAction SilentlyContinue) {
                Write-Host 'Downloading the Chromium browser for Playwright (via npx)...'
                & npx.cmd -y 'playwright' install chromium
            }
            else {
                Write-Warning 'Neither the global playwright shim nor npx was found; skipping the Chromium browser download. Run `playwright install chromium` once Node.js is available.'
                return
            }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "playwright install chromium exited with code $LASTEXITCODE; browser-driving tools (including the Playwright MCP server) may fail at runtime."
            }
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'Playwright'
