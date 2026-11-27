# Link ~\.ssh to Data (#563): make ~\.ssh a junction to
# $env:Data\Profile\.ssh, so every machine uses the SSH keys kept there.
# Off by default: it puts private SSH keys in the Data folder, which syncs to
# Dropbox.
#
# Does nothing until $env:Data is set (#569), and never touches an existing
# ~\.ssh: it would hold this machine's own keys. Running it again keeps the
# link and changes nothing.

if (-not $env:Data) {
    Write-Host '  Link ~\.ssh to Data: $env:Data is not set, so there is nothing to link to yet.'
    return
}

$target = Join-Path $env:Data 'Profile\.ssh'
$link = Join-Path $env:USERPROFILE '.ssh'

$existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
if ($existing) {
    $points = @($existing.Target) | Where-Object { $_ }
    if ($existing.LinkType -eq 'Junction' -and ($points | Where-Object { $_.TrimEnd('\') -ieq $target.TrimEnd('\') })) {
        return
    }
    Write-Warning "Link ~\.ssh to Data: $link already exists, so it is left alone. To use the keys in $target instead, move what it holds there, delete it, and install this again."
    return
}
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Write-Warning "Link ~\.ssh to Data: $target does not exist, so there is nothing to link to yet."
    return
}
New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
Write-Host "  Link ~\.ssh to Data: $link now points to $target."
