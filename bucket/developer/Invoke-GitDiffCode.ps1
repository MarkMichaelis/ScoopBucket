<#
.SYNOPSIS
    Open VS Code diff views of HEAD vs working-tree without blocking the shell.

.DESCRIPTION
    Companion to the `git diffcode` alias installed by GitConfigVSCode.ps1.
    For each path supplied (or, with no args, every file reported by
    `git diff --name-only`), dumps the HEAD blob to a stable temp file under
    %TEMP%\diffcode\ and launches `code --diff <head-copy> <working-tree>`.

    `code` is a non-waiting shim (no --wait), so VS Code opens in the user's
    existing window and the shell returns immediately. The HEAD copies live
    in %TEMP%\diffcode\ and are pruned on subsequent invocations once older
    than 1 day, so VS Code has plenty of time to ingest them.

.NOTES
    Lives under bucket/ so it's shipped into the Scoop app dir alongside the
    GitConfigVSCode manifest; the alias hard-codes its absolute path at
    install time so the helper is reachable regardless of PATH state.

.EXAMPLE
    git diffcode             # diff every modified file
    git diffcode src\a.cs    # diff a single file
    git diffcode --staged    # diff every staged file (HEAD vs index)
#>
[CmdletBinding()]
param(
    [switch]$Staged,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Files
)

if (-not (Get-Command git -ErrorAction Ignore)) {
    Write-Error "git not found on PATH."
    exit 1
}
if (-not (Get-Command code -ErrorAction Ignore)) {
    Write-Error "VS Code 'code' launcher not found on PATH."
    exit 1
}

# Honor `git diffcode --staged` even when --staged arrives via $Files.
if ($Files -and $Files -contains '--staged') {
    $Staged = $true
    $Files = $Files | Where-Object { $_ -ne '--staged' }
}

if (-not $Files -or $Files.Count -eq 0) {
    $listArgs = if ($Staged) { @('diff', '--cached', '--name-only') }
                else         { @('diff', '--name-only') }
    $Files = (& git @listArgs) -split "`r?`n" | Where-Object { $_ }
}

if (-not $Files -or $Files.Count -eq 0) {
    Write-Host "No changes to diff."
    return
}

$tmpRoot = Join-Path $env:TEMP 'diffcode'
[void](New-Item -ItemType Directory -Force -Path $tmpRoot -ErrorAction SilentlyContinue)

# Prune anything older than 1 day so the temp dir doesn't grow unbounded.
$cutoff = (Get-Date).AddDays(-1)
Get-ChildItem -LiteralPath $tmpRoot -File -ErrorAction Ignore |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    Remove-Item -Force -ErrorAction Ignore

$ref = if ($Staged) { '' } else { 'HEAD' }
foreach ($file in $Files) {
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Warning "Path not found in working tree: $file"
        continue
    }
    $leaf  = Split-Path -Leaf $file
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $rand  = [Guid]::NewGuid().ToString('N').Substring(0,6)
    $prefix = if ($ref) { $ref } else { 'INDEX' }
    $left  = Join-Path $tmpRoot ("{0}-{1}-{2}-{3}" -f $prefix, $stamp, $rand, $leaf)

    # `git show :file` reads from the index; `git show HEAD:file` from HEAD.
    $spec = if ($Staged) { ":$file" } else { "HEAD:$file" }
    try {
        $blob = & git show $spec 2>$null
        Set-Content -LiteralPath $left -Value $blob -NoNewline
    } catch {
        Write-Warning "Could not retrieve $spec from git: $($_.Exception.Message)"
        continue
    }

    # No --wait => shell returns immediately. --reuse-window keeps the user's
    # current VS Code window focused instead of stacking new ones per file.
    & code --reuse-window --diff $left $file
}
