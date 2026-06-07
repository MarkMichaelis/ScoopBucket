#requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Module import resilience to a broken foreign format file' {
    BeforeAll {
        $script:ModulePath = Join-Path $PSScriptRoot 'MarkMichaelis.ScoopBucket.psd1'
        # The pwsh hosting this test -- reused to spawn an isolated child session so
        # the deliberately-corrupted format table never pollutes the test runner.
        $script:PwshPath = (Get-Process -Id $PID).Path
    }

    It 'imports the module even when a previously-registered foreign format file is missing from disk' {
        # Arrange: a child script that registers a foreign format file, deletes it
        # from disk (the PSReadLine-style "broken install" scenario), then imports
        # our module. Update-FormatData rebuilds the whole session format table, so
        # the missing foreign file is what would otherwise abort the import.
        $childScript = @'
param([Parameter(Mandatory)][string]$ModulePath)
$ErrorActionPreference = 'Stop'
$broken = Join-Path ([System.IO.Path]::GetTempPath()) ("scoopbucket-brokenfmt-" + [guid]::NewGuid().ToString('N') + ".ps1xml")
Set-Content -LiteralPath $broken -Encoding utf8 -Value '<?xml version="1.0" encoding="utf-8"?><Configuration></Configuration>'
Update-FormatData -PrependPath $broken
Remove-Item -LiteralPath $broken -Force
Import-Module $ModulePath -Force
if (Get-Command Update-Package -ErrorAction SilentlyContinue) { 'IMPORT_OK' } else { 'IMPORT_NO_CMD' }
'@
        $childPath = Join-Path $TestDrive 'import-with-broken-foreign-format.ps1'
        Set-Content -LiteralPath $childPath -Value $childScript -Encoding utf8

        # Act
        $output = & $script:PwshPath -NoProfile -ExecutionPolicy Bypass -File $childPath -ModulePath $script:ModulePath 2>&1

        # Assert: the import completed and the public surface is available.
        ($output -join "`n") | Should -Match 'IMPORT_OK'
    }
}
