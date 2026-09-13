# Windows Terminal tab helpers, imported from the PowerShell profile. Installed to
# ~/.claude/scripts/ClaudeTabs.psm1 by Import-WindowsTerminalSettings (#412).
#  - Colors each tab by the repository its current directory belongs to. Linked
#    worktrees and subdirectories share the repo's color; assignments persist in
#    ~/.claude/terminal-tabs/colors.json (edit it to pick colors).
#  - Lets tabs running Claude resume their session after a crash or reboot. While
#    Claude runs, the tab reports a per-launch folder as its working directory;
#    Windows Terminal saves that in its window layout, and a restored tab that
#    starts there resumes the recorded session. tab-session-hook.js keeps the
#    record's session ID current; claude-tabs.bash/.js are the Git Bash side and
#    share the palette and rules below, so keep them in sync.

$script:TabsRoot = Join-Path $HOME '.claude\terminal-tabs'
$script:SessionsRoot = Join-Path $script:TabsRoot 'sessions'
$script:ColorsFile = Join-Path $script:TabsRoot 'colors.json'
$script:Palette = @(
    '#2E86DE', '#E67E22', '#27AE60', '#C0392B', '#8E44AD', '#16A085',
    '#D81B60', '#B7950B', '#3949AB', '#6D4C41', '#00838F', '#7CB342')
$script:RootCache = @{}
$script:ColorMap = $null
$script:ColorsStamp = $null
$script:ClaudeExe = $null  # tests set this; otherwise resolved from PATH
$script:Esc = [char]27
$script:Bel = [char]7

function Get-ClaudeTabProjectRoot {
    param([string]$Directory)
    if ($script:RootCache.ContainsKey($Directory)) { return $script:RootCache[$Directory] }
    $root = $null
    $commonDir = git -C $Directory rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -eq 0 -and $commonDir) {
        $commonDir = $commonDir.Trim().Replace('/', '\')
        if ((Split-Path $commonDir -Leaf) -eq '.git') {
            # The main worktree, even when $Directory is inside a linked worktree.
            $root = Split-Path $commonDir -Parent
        }
        else {
            $top = git -C $Directory rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $top) { $root = $top.Trim().Replace('/', '\') }
        }
    }
    if (-not $root -and $Directory -match '^[A-Za-z]:\\Git\\[^\\]+') { $root = $Matches[0] }
    $script:RootCache[$Directory] = $root
    $root
}

function Get-ClaudeTabColorMap {
    $stamp = if (Test-Path -LiteralPath $script:ColorsFile) { (Get-Item -LiteralPath $script:ColorsFile).LastWriteTimeUtc }
    if ($null -eq $script:ColorMap -or $stamp -ne $script:ColorsStamp) {
        $map = [ordered]@{}
        if ($stamp) {
            try {
                $json = Get-Content -LiteralPath $script:ColorsFile -Raw | ConvertFrom-Json
                foreach ($property in $json.PSObject.Properties) { $map[$property.Name.ToLowerInvariant()] = [string]$property.Value }
            }
            catch { }
        }
        $script:ColorMap = $map
        $script:ColorsStamp = $stamp
    }
    $script:ColorMap
}

function Get-ClaudeTabColor {
    param([string]$ProjectRoot)
    $key = $ProjectRoot.TrimEnd('\').ToLowerInvariant()
    $map = Get-ClaudeTabColorMap
    if ($map.Contains($key)) { return $map[$key] }
    $used = @($map.Values)
    $color = $script:Palette | Where-Object { $_ -notin $used } | Select-Object -First 1
    if (-not $color) {
        $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($key))
        $color = $script:Palette[$hash[0] % $script:Palette.Count]
    }
    $map[$key] = $color
    New-Item -ItemType Directory -Force -Path $script:TabsRoot | Out-Null
    $map | ConvertTo-Json | Set-Content -LiteralPath $script:ColorsFile -Encoding utf8
    $script:ColorsStamp = (Get-Item -LiteralPath $script:ColorsFile).LastWriteTimeUtc
    $color
}

function Update-ClaudeTabColor {
    if (-not $env:WT_SESSION) { return }
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return }
    $directory = $location.ProviderPath
    $root = Get-ClaudeTabProjectRoot $directory
    if ($root) {
        $hex = (Get-ClaudeTabColor $root).TrimStart('#')
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
    Update-ClaudeTabColor
    $global:LASTEXITCODE = $exitCode
}

Export-ModuleMember -Function claude, Invoke-ClaudeTabRestore
