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
#   1. @playwright/test  -- the npm package carrying the `playwright` CLI.
#   2. Browser binaries  -- downloaded out-of-band by `playwright install`
#                           into a per-user cache (%USERPROFILE%\AppData\
#                           Local\ms-playwright), NEVER by npm itself.
# The npmGlobal engine handles (1); (2) lives in ConfigScript rather than
# PostInstallScript so the browser download is re-checked on every update
# too -- a newer @playwright/test pins newer browser builds, and an npm-only
# upgrade would otherwise leave the CLI pointing at a browser revision that
# is not on disk. `playwright install chromium` is a no-op once the matching
# revision is cached, which satisfies the idempotency contract.
#
# Only Chromium is downloaded: it is what the Playwright MCP server drives,
# and the full three-browser set costs several GB. Run
# `playwright install firefox webkit` by hand for cross-browser runs.

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Playwright'
        Installer   = 'npmGlobal'
        Id          = '@playwright/test'
        CliCommands = @('playwright')
        Completion  = 'auto'
        Notes       = 'Global npm package providing the `playwright` CLI. Requires Node.js/npm on PATH. playwright has no `completion powershell` subcommand and no PSCompletions catalog entry, so the completer is hand-curated. ConfigScript downloads the Chromium browser binaries (the npm package alone ships no browsers).'
        ExpectedCompletions = @{ playwright = @('test','install','codegen','show-report') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName playwright -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'test','install','install-deps','uninstall','codegen','open','screenshot','pdf',
        'show-report','merge-reports','clear-cache','run-server','--help','-h','--version','-V',
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
                    & npx.cmd -y '@playwright/test' install chromium
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
