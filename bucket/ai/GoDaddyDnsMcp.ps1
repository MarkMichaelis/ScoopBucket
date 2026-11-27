#requires -Version 7.0

<#
.SYNOPSIS
    GoDaddy DNS MCP server (stdio). Launched by an MCP client, e.g.:
        pwsh -NoLogo -NoProfile -NonInteractive -File GoDaddyDnsMcp.ps1

.DESCRIPTION
    Speaks newline-delimited JSON-RPC 2.0 (MCP stdio transport) on stdin and
    stdout. stdout carries protocol messages only, so every other stream is
    silenced and diagnostics go to stderr. All logic lives in
    GoDaddyDnsMcp.psm1 next to this file. See docs/GoDaddyDns.md.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding           = $utf8

try {
    Import-Module (Join-Path $PSScriptRoot 'GoDaddyDnsMcp.psm1') -Force
    $null = Start-GoDaddyMcpServer
}
catch {
    [Console]::Error.WriteLine("[godaddy-mcp] fatal: $($_ | Out-String)")
    exit 1
}
