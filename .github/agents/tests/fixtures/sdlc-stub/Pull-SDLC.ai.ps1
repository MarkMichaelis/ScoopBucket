# Stub Pull-SDLC.ai.ps1 used by sdlc-integration tests.
# Creates a marker file in the current working directory so the test can
# assert that the SDLC stage invoked the script with cwd = generated outDir.
[CmdletBinding()]
param(
    [string]$Branch = 'main',
    [string]$RemoteName = 'sdlc.ai'
)
Set-Content -LiteralPath (Join-Path (Get-Location).Path '.sdlc-pulled.marker') -Value "branch=$Branch;remote=$RemoteName" -Encoding utf8
Write-Host "stub Pull-SDLC.ai.ps1: wrote marker"
