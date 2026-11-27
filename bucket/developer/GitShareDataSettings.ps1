# Share Git settings from Data (#563): add an include.path to the global git
# config that reads $env:Data\Profile\.gitconfig, so settings kept in the
# synced Data folder apply on every machine. It replaces GitConfigure's
# .gitconfig hard link, which broke whenever either file was rewritten.
#
# Does nothing until $env:Data is set (#569). Git ignores an include whose
# file does not exist, so including it before the file arrives is harmless.
# Running it again changes nothing: the include is added only when missing.

if (-not $env:Data) {
    Write-Host '  Share Git settings from Data: $env:Data is not set, so there is nothing to include yet.'
    return
}
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Share Git settings from Data: git is not on PATH. Install Git first (Install-Package -Name Git).'
}

$shared = Join-Path $env:Data 'Profile\.gitconfig'
$global = if ($env:GIT_CONFIG_GLOBAL) { $env:GIT_CONFIG_GLOBAL } else { Join-Path $env:USERPROFILE '.gitconfig' }

# GitConfigure used to hard-link the Data copy to the global config. Including
# a file in itself makes every git command fail ("exceeded maximum include
# depth"), and the link already shares the settings, so leave that alone.
$sharedItem = Get-Item -LiteralPath $shared -Force -ErrorAction SilentlyContinue
if ($sharedItem -and $sharedItem.LinkType -eq 'HardLink') {
    $names = @(fsutil hardlink list $shared 2>$null)
    $sameFile = $LASTEXITCODE -ne 0 -or $names -contains (Split-Path -NoQualifier $global)
    if ($sameFile) {
        Write-Warning "Share Git settings from Data: $shared is a hard link to $global (set up by the retired GitConfigure), so the settings are already shared and including it would make git recurse. To switch to the include, replace the link with a copy (Copy-Item; Remove-Item the link; rename the copy), then install this again."
        return
    }
}

$included = @(git config --global --get-all include.path 2>$null)
# Compare full paths; a value that is not a path at all cannot be this one.
$sameAs = { param($path) try { [IO.Path]::GetFullPath($path) -ieq [IO.Path]::GetFullPath($shared) } catch { $false } }
if ($included | Where-Object { $_ -and (& $sameAs $_) }) {
    return
}
git config --global --add include.path $shared
if ($LASTEXITCODE -ne 0) { throw "Share Git settings from Data: git config --global --add include.path failed (exit $LASTEXITCODE)." }
Write-Host "  Share Git settings from Data: the global git config now includes $shared."
