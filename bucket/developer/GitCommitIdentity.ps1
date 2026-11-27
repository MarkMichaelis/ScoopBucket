# Commit identity (#563, split out of GitConfigure): the owner's user.name and
# user.email, written only where unset, so an identity a machine already has
# is never replaced and running it again changes nothing.

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Commit identity: git is not on PATH. Install Git first (Install-Package -Name Git).'
}

$identity = [ordered]@{ 'user.name' = 'Mark Michaelis'; 'user.email' = 'Mark@IntelliTect.com' }
foreach ($key in $identity.Keys) {
    $current = git config --global --get $key
    if ($current) {
        Write-Host "  git $key is already set ($current); left as it is."
        continue
    }
    git config --global $key $identity[$key]
    if ($LASTEXITCODE -ne 0) { throw "Commit identity: git config --global $key failed (exit $LASTEXITCODE)." }
}
