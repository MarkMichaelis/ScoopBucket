# Git Bash counterpart of ClaudeTabs.psm1, sourced from ~/.bashrc: colors the Windows
# Terminal tab by repository and lets tabs running Claude resume their session after a
# crash or reboot. Shares the color map and session records with the PowerShell module
# through claude-tabs.js, so a Claude tab started from bash can be restored by either.

# Only in Windows Terminal, and not in shells Claude itself runs.
[ -n "$WT_SESSION" ] && [ -z "$CLAUDECODE" ] || return 0

_ct_helper="$HOME/.claude/scripts/claude-tabs.js"
_ct_sessions_root="$HOME/.claude/terminal-tabs/sessions"
_ct_claude=claude  # tests point this at a fake executable
_ct_winpid=$(cat /proc/$$/winpid 2>/dev/null)
_ct_shell_start=
_ct_last_dir=
_ct_color_seq=
_ct_pending_session=
_ct_pending_token=
_ct_pending_dir=
_ct_pending_keep=()

_ct_report_dir() {
    printf '\e]9;9;%s\e\\' "$1"
}

_ct_update_tab() {
    local status=$?
    if [ "$PWD" != "$_ct_last_dir" ]; then
        _ct_last_dir=$PWD
        local color
        color=$(node "$_ct_helper" color "$(cygpath -w "$PWD")" 2>/dev/null)
        if [ -n "$color" ]; then
            # OSC 4 on color index 264 sets the Windows Terminal tab color.
            _ct_color_seq=$(printf '\e]4;264;rgb:%s/%s/%s\a' "${color:1:2}" "${color:3:2}" "${color:5:2}")
        else
            _ct_color_seq=$'\e]104;264\a'
        fi
    fi
    printf '%s' "$_ct_color_seq"
    _ct_report_dir "$(cygpath -w "$PWD")"
    if [ -n "$_ct_pending_session" ]; then
        claude
    fi
    return $status
}

claude() {
    # When run by Claude itself there is no tab to restore.
    if [ -n "$CLAUDECODE" ]; then
        command "$_ct_claude" "$@"
        return
    fi

    local token session_id="" launch_dir
    local -a args
    if [ -n "$_ct_pending_session" ]; then
        token=$_ct_pending_token
        session_id=$_ct_pending_session
        launch_dir=$_ct_pending_dir
        args=(--resume "$session_id" "${_ct_pending_keep[@]}")
        _ct_pending_session=
        printf '\e[90mResuming Claude session %s from before the restart...\e[0m\n' "$session_id"
    else
        token=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
        launch_dir=$(cygpath -w "$PWD")
        args=("$@")
    fi

    [ -n "$_ct_shell_start" ] || _ct_shell_start=$(node "$_ct_helper" shellstart "$_ct_winpid")
    if ! node "$_ct_helper" record "$token" "$launch_dir" "$_ct_winpid" "$_ct_shell_start" "$session_id" -- "${args[@]}"; then
        command "$_ct_claude" "${args[@]}"
        return
    fi

    local rc
    pushd "$(cygpath -u "$launch_dir")" >/dev/null || return
    _ct_report_dir "$(cygpath -w "$_ct_sessions_root")\\$token"
    CLAUDE_TAB_TOKEN=$token command "$_ct_claude" "${args[@]}"
    rc=$?
    popd >/dev/null
    rm -rf "${_ct_sessions_root:?}/$token"
    _ct_report_dir "$(cygpath -w "$PWD")"
    return $rc
}

_ct_init_restore() {
    local here root
    here=$(cygpath -w "$PWD")
    root=$(cygpath -w "$_ct_sessions_root")
    [[ "${here,,}" == "${root,,}\\"* ]] || return 0
    local -a lines
    mapfile -t lines < <(node "$_ct_helper" restore "$here")
    if [ -n "${lines[0]}" ]; then
        cd "$(cygpath -u "${lines[0]}")" || cd ~
    else
        cd ~
    fi
    if [ -n "${lines[1]}" ]; then
        _ct_pending_dir=${lines[0]}
        _ct_pending_session=${lines[1]}
        _ct_pending_token=${lines[2]}
        _ct_pending_keep=("${lines[@]:3}")
    fi
}

_ct_init_restore
PROMPT_COMMAND="_ct_update_tab${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
