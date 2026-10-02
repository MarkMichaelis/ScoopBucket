# Windows Terminal tab helpers, imported from the PowerShell profile. Installed to
# ~/.claude/scripts/ClaudeTabs.psm1 by Import-WindowsTerminalSettings (#412, #446).
#  - Colors each tab by the root its current directory belongs to: the nearest git
#    repository (linked worktrees and subfolders share the main repo's color), the
#    home folder, or a folder marked with Set-ClaudeTabRoot. Folders under no root
#    keep the default color. Every root gets its own color, assigned in order of
#    first sight from an unlimited sequence, and is keyed by identity (GitHub
#    owner/repo, "~", or a marked path) rather than by where it is cloned, so the
#    map roams through OneDrive and a repo has the same color on every machine.
#  - Lets tabs running Claude resume their session after a crash or reboot. While
#    Claude runs, the tab reports a per-launch folder as its working directory;
#    Windows Terminal saves that in its window layout, and a restored tab that
#    starts there resumes the recorded session. tab-session-hook.js keeps the
#    record's session ID current; claude-tabs.bash/.js are the Git Bash side and
#    share the root, key, and color rules below, so keep them in sync.

$script:TabsRoot = Join-Path $HOME '.claude\terminal-tabs'
$script:SessionsRoot = Join-Path $script:TabsRoot 'sessions'
# Session records are tied to this machine; the root map roams through OneDrive. Only
# tab-roots.json is read, so OneDrive conflict copies (tab-roots-<PC>.json) are ignored.
$script:StoreDir = Join-Path $(if ($env:OneDriveCommercial) { Join-Path $env:OneDriveCommercial 'Documents' } elseif ($env:OneDrive) { Join-Path $env:OneDrive 'Documents' } else { $env:APPDATA }) 'WindowsTerminalTabs'
$script:RootsFile = Join-Path $script:StoreDir 'tab-roots.json'
# Path-keyed maps written by earlier versions, migrated once into tab-roots.json. The
# roaming one is left in place (an older install elsewhere may still use it); the
# machine-local one is renamed to colors.json.migrated after it is merged.
$script:LegacyRoamingColors = Join-Path $script:StoreDir 'colors.json'
$script:LegacyLocalColors = Join-Path $script:TabsRoot 'colors.json'
$script:LocalMerged = $false
# Local, not in OneDrive: it only has to keep this machine's shells from racing.
$script:LockFile = Join-Path $script:TabsRoot 'tab-roots.lock'
$script:HomeDir = $HOME
$script:TempDir = [System.IO.Path]::GetTempPath()
# The first colors handed out; later roots continue with Get-ClaudeTabSequenceColor.
$script:Palette = @(
    '#2E86DE', '#E67E22', '#27AE60', '#C0392B', '#8E44AD', '#16A085',
    '#D81B60', '#B7950B', '#3949AB', '#6D4C41', '#00838F', '#7CB342')
$script:GitCache = @{}
$script:Store = $null
$script:StoreStamp = $null
$script:ClaudeExe = $null  # tests set this; otherwise resolved from PATH
$script:Esc = [char]27
$script:Bel = [char]7

function Get-ClaudeTabSequenceColor {
    # Color number $Index of the unlimited sequence: the palette, then hues a golden
    # angle apart (so neighbors in the sequence are far apart on the color wheel) at a
    # saturation and three lightness levels that keep tab text readable.
    param([int]$Index)
    if ($Index -lt $script:Palette.Count) { return $script:Palette[$Index] }
    $k = $Index - $script:Palette.Count
    $h = (($k * 137.50776405) + 15) % 360
    $s = 0.62
    $l = (0.42, 0.32, 0.52)[$k % 3]
    $c = (1 - [math]::Abs(2 * $l - 1)) * $s
    $x = $c * (1 - [math]::Abs((($h / 60) % 2) - 1))
    $m = $l - $c / 2
    $rgb = switch ([math]::Floor($h / 60)) {
        0 { $c, $x, 0 } 1 { $x, $c, 0 } 2 { 0, $c, $x } 3 { 0, $x, $c } 4 { $x, 0, $c } default { $c, 0, $x }
    }
    # Floor(v + 0.5), not [math]::Round (banker's rounding), to match Math.round in claude-tabs.js.
    '#' + (($rgb | ForEach-Object { '{0:X2}' -f [int][math]::Floor(($_ + $m) * 255 + 0.5) }) -join '')
}

function Get-ClaudeTabNextColor {
    # The first color in the sequence no root uses yet.
    param([System.Collections.IDictionary]$Colors)
    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Colors.Values) { [void]$used.Add([string]$value) }
    for ($i = 0; ; $i++) {
        $color = Get-ClaudeTabSequenceColor $i
        if (-not $used.Contains($color)) { return $color }
    }
}

function ConvertTo-ClaudeTabRepoKey {
    # owner/repo for a GitHub origin URL, otherwise the repository folder's name.
    param([string]$Url, [string]$Folder)
    if ($Url -match '^(?:git@github\.com:|ssh://git@github\.com/|https?://(?:[^@/]+@)?github\.com/)(.+)$') {
        $slug = $Matches[1].TrimEnd('/')
        if ($slug.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $slug = $slug.Substring(0, $slug.Length - 4) }
        if ($slug -match '^[^/]+/[^/]+$') { return $slug.ToLowerInvariant() }
    }
    $Folder.TrimEnd('\').Split('\')[-1].ToLowerInvariant()
}

function Get-ClaudeTabOriginUrl {
    # remote.origin.url read straight from the repository's config file: no extra git call.
    # (url.<base>.insteadOf rewrites and config includes are not applied.)
    param([string]$CommonDir)
    $inOrigin = $false
    foreach ($line in (Get-Content -LiteralPath (Join-Path $CommonDir 'config') -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*\[') { $inOrigin = $line -match '^\s*\[remote\s+"origin"\]'; continue }
        if ($inOrigin -and $line -match '^\s*url\s*=\s*(.+?)\s*$') { return $Matches[1] }
    }
}

function Get-ClaudeTabGitRoot {
    # The repository $Directory is in: its worktree top (for nearest-root comparison) and
    # the main repository's key. One git call per new directory, then cached.
    param([string]$Directory)
    if ($script:GitCache.ContainsKey($Directory)) { return $script:GitCache[$Directory] }
    $result = $null
    $lines = @(git -C $Directory rev-parse --path-format=absolute --git-common-dir --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $lines.Count -ge 2) {
        $commonDir = $lines[0].Trim().Replace('/', '\')
        $top = $lines[1].Trim().Replace('/', '\')
        # The main worktree, even when $Directory is inside a linked worktree.
        $main = if ((Split-Path $commonDir -Leaf) -eq '.git') { Split-Path $commonDir -Parent } else { $top }
        $result = [pscustomobject]@{
            Path = $top
            Kind = 'Repository'
            Key  = ConvertTo-ClaudeTabRepoKey -Url (Get-ClaudeTabOriginUrl $commonDir) -Folder $main
        }
    }
    $script:GitCache[$Directory] = $result
    $result
}

function Test-ClaudeTabUnder {
    param([string]$Directory, [string]$Root)
    $d = $Directory.TrimEnd('\')
    $r = $Root.TrimEnd('\')
    $d.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $d.StartsWith("$r\", [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-ClaudeTabMarkedKey {
    # A marked root's key: relative to home ("~\documents\notes") when under it, so it
    # roams between machines, else its absolute path. Keys are lowercase.
    param([string]$Path)
    $path = $Path.TrimEnd('\')
    $homeDir = $script:HomeDir.TrimEnd('\')
    if (Test-ClaudeTabUnder $path $homeDir) { $path = '~' + $path.Substring($homeDir.Length) }
    if ($path.EndsWith(':')) { $path += '\' }
    $path.ToLowerInvariant()
}

function ConvertFrom-ClaudeTabMarkedKey {
    param([string]$Key)
    if ($Key -eq '~' -or $Key.StartsWith('~\')) { return $script:HomeDir.TrimEnd('\') + $Key.Substring(1) }
    $Key
}

function Get-ClaudeTabFullPath {
    # Long-form provider path (expands 8.3 names) of an existing folder, else $null.
    param([string]$Path)
    try {
        Push-Location -LiteralPath $Path -ErrorAction Stop
        try { (Get-Location).ProviderPath } finally { Pop-Location }
    }
    catch { $null }
}

function Read-ClaudeTabJson {
    param([string]$Path)
    try { Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { $null }
}

function Add-ClaudeTabLegacyColors {
    # Merges a path-keyed map from an earlier version into $Store under identity keys,
    # keeping colors and the first color seen for a key. Paths that no longer exist or
    # are under the temp folder are dropped; a folder that is neither in a repository
    # nor the home folder becomes a marked root.
    param([System.Collections.IDictionary]$Store, [string]$Path)
    $legacy = Read-ClaudeTabJson $Path
    if ($legacy -isnot [System.Collections.IDictionary]) { return }
    $temp = Get-ClaudeTabFullPath $script:TempDir
    foreach ($entry in $legacy.GetEnumerator()) {
        if ([string]$entry.Value -notmatch '^#[0-9A-Fa-f]{6}$') { continue }
        $dir = Get-ClaudeTabFullPath $entry.Key
        if (-not $dir -or ($temp -and (Test-ClaudeTabUnder $dir $temp))) { continue }
        $repo = Get-ClaudeTabGitRoot $dir
        $key = if ($repo) { $repo.Key }
        elseif ((ConvertTo-ClaudeTabMarkedKey $dir) -eq '~') { '~' }
        else {
            $marked = ConvertTo-ClaudeTabMarkedKey $dir
            if ($marked -notin $Store.roots) { $Store.roots.Add($marked) }
            $marked
        }
        if (-not $Store.colors.Contains($key)) { $Store.colors[$key] = ([string]$entry.Value).ToUpperInvariant() }
    }
}

function Save-ClaudeTabStore {
    $store = $script:Store
    if (-not $store.Writable) { return $false }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:RootsFile) | Out-Null
    $json = [ordered]@{ version = 2; colors = $store.colors; roots = @($store.roots) } | ConvertTo-Json -Depth 5
    # Write a temp file and rename it over the map, so a reader never sees half a file.
    $temp = "$($script:RootsFile).$PID.tmp"
    Set-Content -LiteralPath $temp -Value $json -Encoding utf8
    [System.IO.File]::Move($temp, $script:RootsFile, $true)
    $script:StoreStamp = (Get-Item -LiteralPath $script:RootsFile).LastWriteTimeUtc
    $true
}

function Get-ClaudeTabStore {
    # The root map: colors (key -> #RRGGBB) and roots (marked root keys). Re-read when
    # the file changes (e.g. OneDrive syncs another machine's edit). A file that cannot
    # be parsed is never overwritten: colors are then assigned for this session only.
    param([switch]$Fresh)
    $stamp = if (Test-Path -LiteralPath $script:RootsFile) { (Get-Item -LiteralPath $script:RootsFile).LastWriteTimeUtc }
    if (-not $Fresh -and $null -ne $script:Store -and $stamp -eq $script:StoreStamp) { return $script:Store }
    $store = [ordered]@{ colors = [ordered]@{}; roots = [System.Collections.Generic.List[string]]::new(); Writable = $true }
    $dirty = $false
    if ($stamp) {
        $json = Read-ClaudeTabJson $script:RootsFile
        if ($json -is [System.Collections.IDictionary] -and $json['version'] -eq 2 -and $json['colors'] -is [System.Collections.IDictionary]) {
            foreach ($entry in $json['colors'].GetEnumerator()) { $store.colors[$entry.Key.ToLowerInvariant()] = [string]$entry.Value }
            foreach ($root in @($json['roots'])) { if ($root) { $store.roots.Add(([string]$root).ToLowerInvariant()) } }
        }
        else { $store.Writable = $false }
    }
    else {
        Add-ClaudeTabLegacyColors $store $script:LegacyRoamingColors
        $dirty = $true
    }
    $script:Store = $store
    $script:StoreStamp = $stamp
    # Merged once per session: if it cannot be renamed away, it is retried next session
    # rather than on every prompt.
    $mergeLocal = $store.Writable -and -not $script:LocalMerged -and (Test-Path -LiteralPath $script:LegacyLocalColors)
    if ($mergeLocal) {
        $script:LocalMerged = $true
        Add-ClaudeTabLegacyColors $store $script:LegacyLocalColors
        $dirty = $true
    }
    if ($dirty -and (Save-ClaudeTabStore) -and $mergeLocal) {
        Move-Item -LiteralPath $script:LegacyLocalColors -Destination "$($script:LegacyLocalColors).migrated" -Force -ErrorAction SilentlyContinue
    }
    $script:Store
}

function Invoke-ClaudeTabStoreUpdate {
    # Runs $Update against a fresh read of the map and saves the result, holding a lock
    # file so shells that discover roots at the same moment (a restored multi-tab
    # layout) cannot drop each other's entries. claude-tabs.js takes the same lock. A
    # lock older than a few seconds was left by a crashed shell and is broken.
    # Retrying for longer than that means the update proceeds unlocked only if the lock
    # cannot even be broken.
    param([scriptblock]$Update)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:LockFile) | Out-Null
    $lock = $null
    for ($i = 0; $i -lt 140 -and -not $lock; $i++) {
        try { $lock = [System.IO.File]::Open($script:LockFile, 'CreateNew', 'Write', 'None') }
        catch {
            $since = try { (Get-Date) - (Get-Item -LiteralPath $script:LockFile -ErrorAction Stop).LastWriteTime } catch { $null }
            if ($since -and $since.TotalSeconds -gt 5) { Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue }
            else { Start-Sleep -Milliseconds 50 }
        }
    }
    try {
        $result = & $Update (Get-ClaudeTabStore -Fresh)
        Save-ClaudeTabStore | Out-Null
        $result
    }
    finally {
        if ($lock) {
            $lock.Dispose()
            Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-ClaudeTabRoot {
    # The nearest root containing $Directory -- a repository, a marked folder, or the
    # home folder -- or $null when it is under none.
    param([string]$Directory)
    $candidates = [System.Collections.Generic.List[object]]::new()
    $repo = Get-ClaudeTabGitRoot $Directory
    if ($repo) { $candidates.Add($repo) }
    foreach ($key in (Get-ClaudeTabStore).roots) {
        $path = ConvertFrom-ClaudeTabMarkedKey $key
        if (Test-ClaudeTabUnder $Directory $path) { $candidates.Add([pscustomobject]@{ Path = $path; Kind = 'Marked'; Key = $key }) }
    }
    if (Test-ClaudeTabUnder $Directory $script:HomeDir) {
        $candidates.Add([pscustomobject]@{ Path = $script:HomeDir.TrimEnd('\'); Kind = 'Home'; Key = '~' })
    }
    $best = $null
    foreach ($candidate in $candidates) {
        if (-not $best -or $candidate.Path.TrimEnd('\').Length -gt $best.Path.TrimEnd('\').Length) { $best = $candidate }
    }
    $best
}

function Get-ClaudeTabRootColor {
    # The root's color, assigning (and saving) the next unused one on first sight.
    param($Root)
    $store = Get-ClaudeTabStore
    if ($store.colors.Contains($Root.Key)) { return $store.colors[$Root.Key] }
    Invoke-ClaudeTabStoreUpdate {
        param($fresh)
        if (-not $fresh.colors.Contains($Root.Key)) { $fresh.colors[$Root.Key] = Get-ClaudeTabNextColor $fresh.colors }
        $fresh.colors[$Root.Key]
    }
}

function Resolve-ClaudeTabDirectory {
    param([string]$Path)
    $full = Get-ClaudeTabFullPath $Path
    if (-not $full) { throw "Folder not found: $Path" }
    $full
}

function Get-ClaudeTabRoot {
    <#
    .SYNOPSIS
        Shows which root a folder's tab color comes from, and the color.
    .DESCRIPTION
        Kind is Repository, Home, Marked, or None (default tab color). A root seen for
        the first time is assigned its color, as the tab would be.
    .EXAMPLE
        Get-ClaudeTabRoot
    #>
    [CmdletBinding()]
    param([string]$Path = '.')
    $directory = Resolve-ClaudeTabDirectory $Path
    $root = Resolve-ClaudeTabRoot $directory
    [pscustomobject]@{
        Path  = $directory
        Root  = $root.Path
        Kind  = if ($root) { $root.Kind } else { 'None' }
        Key   = $root.Key
        Color = if ($root) { Get-ClaudeTabRootColor $root }
    }
}

function Set-ClaudeTabRoot {
    <#
    .SYNOPSIS
        Marks a folder as a tab-color root, so it and its subfolders share a color.
    .DESCRIPTION
        Without -Color the root gets the next unused color. On a folder that already is
        a root (a repository's top folder, the home folder, or a marked folder) only its
        color changes. The map roams through OneDrive.
    .EXAMPLE
        Set-ClaudeTabRoot ~\Documents\Notes
    .EXAMPLE
        Set-ClaudeTabRoot -Color '#7B1FA2'
        Marks the current folder with that color, or just recolors it if it already is a root.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path = '.',
        [ValidatePattern('^#[0-9A-Fa-f]{6}$')][string]$Color
    )
    $directory = Resolve-ClaudeTabDirectory $Path
    $store = Get-ClaudeTabStore
    if (-not $store.Writable) { throw "Cannot update $($script:RootsFile): it is not valid JSON. Fix or delete it first." }
    $root = Resolve-ClaudeTabRoot $directory
    $isRoot = $root -and $root.Path.TrimEnd('\').Equals($directory.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    $key = if ($isRoot) { $root.Key } else { ConvertTo-ClaudeTabMarkedKey $directory }
    if (-not $PSCmdlet.ShouldProcess($directory, "Set tab-color root $key")) { return }
    Invoke-ClaudeTabStoreUpdate {
        param($fresh)
        # Decided again against the fresh map: another shell may have marked it meanwhile.
        $root = Resolve-ClaudeTabRoot $directory
        $isRoot = $root -and $root.Path.TrimEnd('\').Equals($directory.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        $key = if ($isRoot) { $root.Key } else { ConvertTo-ClaudeTabMarkedKey $directory }
        if (-not $isRoot -and $key -notin $fresh.roots) { $fresh.roots.Add($key) }
        if ($Color) { $fresh.colors[$key] = $Color.ToUpperInvariant() }
        elseif (-not $fresh.colors.Contains($key)) { $fresh.colors[$key] = Get-ClaudeTabNextColor $fresh.colors }
    }
    try { Update-ClaudeTabColor } catch { }
    Get-ClaudeTabRoot -Path $directory
}

function Remove-ClaudeTabRoot {
    <#
    .SYNOPSIS
        Unmarks a folder marked with Set-ClaudeTabRoot; it then takes its parent root's color.
    .EXAMPLE
        Remove-ClaudeTabRoot ~\Documents\Notes
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path = '.')
    $directory = Get-ClaudeTabFullPath $Path
    if (-not $directory) {
        # A marked folder that has since been deleted: resolve the path as typed.
        $typed = if ($Path -eq '~' -or $Path -match '^~[\\/]') { $script:HomeDir.TrimEnd('\') + $Path.Substring(1) } else { $Path }
        $directory = [System.IO.Path]::GetFullPath($typed.Replace('/', '\'), (Get-Location -PSProvider FileSystem).ProviderPath)
    }
    $key = ConvertTo-ClaudeTabMarkedKey $directory
    $store = Get-ClaudeTabStore
    if ($key -notin $store.roots) { Write-Warning "$directory is not a marked root; Get-ClaudeTabRoot shows where its color comes from."; return }
    if (-not $store.Writable) { throw "Cannot update $($script:RootsFile): it is not valid JSON. Fix or delete it first." }
    if (-not $PSCmdlet.ShouldProcess($directory, "Remove tab-color root $key")) { return }
    Invoke-ClaudeTabStoreUpdate {
        param($fresh)
        [void]$fresh.roots.Remove($key)
        $fresh.colors.Remove($key)
    }
    try { Update-ClaudeTabColor } catch { }
}

function Update-ClaudeTabColor {
    if (-not $env:WT_SESSION) { return }
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return }
    $directory = $location.ProviderPath
    $root = Resolve-ClaudeTabRoot $directory
    if ($root) {
        $hex = (Get-ClaudeTabRootColor $root).TrimStart('#')
        # OSC 4 on color index 264 sets the Windows Terminal tab color.
        [Console]::Write("$script:Esc]4;264;rgb:$($hex.Substring(0, 2))/$($hex.Substring(2, 2))/$($hex.Substring(4, 2))$script:Bel")
    }
    else {
        [Console]::Write("$script:Esc]104;264$script:Bel")
    }
    # Report the directory so Windows Terminal's saved layout and Duplicate Tab use it.
    [Console]::Write("$script:Esc]9;9;$directory$script:Esc\")
}

function Get-ClaudeResumeArgs {
    # Launch options worth keeping when a session is resumed. The prompt, name, and
    # session selection are dropped; the resumed session already has them.
    param([string[]]$ArgumentList)
    $keep = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        $arg = $ArgumentList[$i]
        if ($arg -eq '--') { break }
        if ($arg -match '^--(permission-mode|model|add-dir)=') { $keep.Add($arg); continue }
        if ($arg -match '^--(permission-mode|model)$' -and $i + 1 -lt $ArgumentList.Count) {
            $keep.Add($arg); $keep.Add($ArgumentList[++$i]); continue
        }
        if ($arg -eq '--add-dir') {
            $keep.Add($arg)
            while ($i + 1 -lt $ArgumentList.Count -and $ArgumentList[$i + 1] -notlike '-*') { $keep.Add($ArgumentList[++$i]) }
            continue
        }
        if ($arg -in '--remote-control', '--dangerously-skip-permissions') { $keep.Add($arg) }
    }
    , $keep.ToArray()
}

function Test-ClaudeTabOwnerAlive {
    param($Record)
    $process = Get-Process -Id ([int]$Record.shellPid) -ErrorAction SilentlyContinue
    [bool]($process -and $process.StartTime.ToFileTimeUtc() -eq [long]$Record.shellStart)
}

function Read-ClaudeTabRecord {
    param([string]$Directory)
    try { Get-Content -LiteralPath (Join-Path $Directory 'record.json') -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { $null }
}

function claude {
    $exe = $script:ClaudeExe
    if (-not $exe) { $exe = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $exe) { Write-Error 'The claude executable was not found on PATH.'; return }
    # Outside Windows Terminal, or when run by Claude itself, there is no tab to restore.
    if (-not $env:WT_SESSION -or $env:CLAUDECODE) { & $exe @args; return }

    $pending = $global:ClaudeTabPendingRestore
    $global:ClaudeTabPendingRestore = $null
    if ($pending) {
        # This restored tab's own launch command called claude: resume instead of
        # starting over with the original prompt.
        $token = $pending.token
        $launchDir = $pending.launchDir
        $keepArgs = @($pending.keepArgs | Where-Object { $_ })
        $sessionId = $pending.sessionId
        $claudeArgs = @('--resume', $sessionId) + $keepArgs
        Write-Host "Resuming Claude session $sessionId from before the restart..." -ForegroundColor DarkGray
    }
    else {
        $token = [guid]::NewGuid().ToString('N')
        $launchDir = (Get-Location).ProviderPath
        $keepArgs = Get-ClaudeResumeArgs $args
        $sessionId = $null
        $claudeArgs = $args
    }

    $tokenDir = Join-Path $script:SessionsRoot $token
    New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null
    [ordered]@{
        token      = $token
        launchDir  = $launchDir
        keepArgs   = $keepArgs
        sessionId  = $sessionId
        shellPid   = $PID
        # A string: 18-digit file times lose precision when the Node.js hook rewrites the record.
        shellStart = (Get-Process -Id $PID).StartTime.ToFileTimeUtc().ToString()
        startedAt  = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tokenDir 'record.json') -Encoding utf8

    $previousToken = $env:CLAUDE_TAB_TOKEN
    $env:CLAUDE_TAB_TOKEN = $token
    Push-Location -LiteralPath $launchDir
    try {
        [Console]::Write("$script:Esc]9;9;$tokenDir$script:Esc\")
        & $exe @claudeArgs
    }
    finally {
        Pop-Location
        $env:CLAUDE_TAB_TOKEN = $previousToken
        Remove-Item -LiteralPath $tokenDir -Recurse -Force -ErrorAction SilentlyContinue
        [Console]::Write("$script:Esc]9;9;$((Get-Location).ProviderPath)$script:Esc\")
    }
}

function Initialize-ClaudeTabRestore {
    if (-not $env:WT_SESSION) { return }
    $here = (Get-Location).ProviderPath
    $root = $script:SessionsRoot
    if (Test-Path -LiteralPath $root) {
        # PowerShell reports locations in long form; normalize a root built from a
        # short (8.3) path the same way before comparing.
        Push-Location -LiteralPath $root
        $root = (Get-Location).ProviderPath
        Pop-Location
    }
    if (-not $here -or -not $here.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
    $record = Read-ClaudeTabRecord $here
    if (-not $record -or -not $record.launchDir -or -not (Test-Path -LiteralPath $record.launchDir)) {
        Set-Location $HOME
        return
    }
    Set-Location -LiteralPath $record.launchDir
    # A duplicate of a Claude tab that is still running just opens in the same folder.
    if (-not $record.sessionId -or (Test-ClaudeTabOwnerAlive $record)) { return }
    # The user had already exited Claude; only the shell was left when the tab died.
    # ('other' is excluded: Claude may report it while being shut down by a reboot.)
    if ($record.ended -and $record.ended.sessionId -eq $record.sessionId -and $record.ended.reason -in 'prompt_input_exit', 'logout') { return }
    $global:ClaudeTabPendingRestore = $record
}

function Invoke-ClaudeTabRestore {
    if (-not $global:ClaudeTabPendingRestore) { return }
    # A tab launched with its own command (e.g. Start-IssueAgent's new tab) runs
    # claude itself; the wrapper picks up the pending restore there.
    $launchedWithCommand = [Environment]::GetCommandLineArgs() | Select-Object -Skip 1 |
        Where-Object { $_ -match '^-(c|co\w*|ec|en\w*|f|fi\w*)$' }
    if ($launchedWithCommand) { return }
    claude
}

function Remove-StaleClaudeTabRecords {
    $cutoff = (Get-Date).AddDays(-14)
    Get-ChildItem -LiteralPath $script:SessionsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt $cutoff |
        ForEach-Object {
            $record = Read-ClaudeTabRecord $_.FullName
            if (-not $record -or -not (Test-ClaudeTabOwnerAlive $record)) {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
}

if (-not $global:ClaudeTabOriginalPrompt) {
    $global:ClaudeTabOriginalPrompt = (Get-Command -Name prompt -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
}
Set-Item function:global:prompt -Value {
    $exitCode = $global:LASTEXITCODE
    try { Update-ClaudeTabColor } catch { }
    if ($global:ClaudeTabPendingRestore) {
        $id = $global:ClaudeTabPendingRestore.sessionId
        $global:ClaudeTabPendingRestore = $null
        Write-Host "Claude session $id from before the restart was not resumed. Run: claude --resume $id" -ForegroundColor Yellow
    }
    $global:LASTEXITCODE = $exitCode
    if ($global:ClaudeTabOriginalPrompt) { & $global:ClaudeTabOriginalPrompt } else { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
}

# Tab work only happens inside Windows Terminal; elsewhere importing is side-effect free.
if ($env:WT_SESSION) {
    $exitCode = $global:LASTEXITCODE
    Remove-StaleClaudeTabRecords
    Initialize-ClaudeTabRestore
    try { Update-ClaudeTabColor } catch { }
    $global:LASTEXITCODE = $exitCode
}

Export-ModuleMember -Function claude, Invoke-ClaudeTabRestore, Get-ClaudeTabRoot, Set-ClaudeTabRoot, Remove-ClaudeTabRoot
