# Global Git settings (#563, split out of GitConfigure): colors, push.default
# and core.autocrlf. Every setting is a plain `git config --global` write, so
# running it again changes nothing.

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Global Git settings: git is not on PATH. Install Git first (Install-Package -Name Git).'
}

$settings = [ordered]@{
    'color.ui'      = 'auto'
    'push.default'  = 'simple'
    # Normalize line endings on the way INTO the object database, and leave
    # the working tree alone. `input` deliberately, not `true`: `true` also
    # rewrites the working tree to CRLF, which breaks shell scripts under
    # WSL, Docker and Linux CI. Without it, whatever an editor happens to
    # write is what gets committed. A per-machine safety net for repositories
    # with no .gitattributes -- not the real fix, which lives in the repo.
    'core.autocrlf' = 'input'
    'color.status.untracked' = 'red normal bold'
    'color.status.changed'   = 'red normal bold'
    'color.status.add'       = 'green normal bold'
    'color.status.added'     = 'green normal bold'
    'color.status.updated'   = 'green normal bold'
    'color.branch.current'   = 'green normal bold'
    'color.branch.remote'    = 'bold'   # equivalent to yellow normal bold
    'color.diff.old'         = 'red normal bold'
    'color.diff.new'         = 'green normal bold'
}
foreach ($key in $settings.Keys) {
    git config --global $key $settings[$key]
    if ($LASTEXITCODE -ne 0) { throw "Global Git settings: git config --global $key failed (exit $LASTEXITCODE)." }
}
