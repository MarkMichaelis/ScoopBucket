// Claude Code SessionStart/SessionEnd hook for Windows Terminal tab restore.
// The `claude` wrapper in ClaudeTabs.psm1 sets CLAUDE_TAB_TOKEN and writes
// ~/.claude/terminal-tabs/sessions/<token>/record.json before launching Claude;
// this hook keeps that record's session ID current (new session, /clear, /resume)
// so a tab restored after a crash or reboot resumes the right session.
const fs = require('fs');
const os = require('os');
const path = require('path');

let data = '';
process.stdin.on('data', c => (data += c));
process.stdin.on('end', () => {
  try {
    update(JSON.parse(data));
  } catch {
    // Restore bookkeeping must never block or disturb the session.
  }
});

function update(input) {
  const token = process.env.CLAUDE_TAB_TOKEN || '';
  if (!/^[0-9a-f]{32}$/.test(token) || input.agent_id) return;
  const file = path.join(os.homedir(), '.claude', 'terminal-tabs', 'sessions', token, 'record.json');
  if (!fs.existsSync(file)) return;
  const record = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));

  // A claude started from inside this session inherits the token; leave the record alone.
  const claudePid = Number(process.env.CLAUDE_PID) || null;
  if (record.claudePid && claudePid && record.claudePid !== claudePid) return;

  const now = new Date().toISOString();
  if (input.hook_event_name === 'SessionStart') {
    Object.assign(record, {
      claudePid: claudePid || record.claudePid || null,
      sessionId: input.session_id,
      sessionCwd: input.cwd,
      source: input.source,
      updatedAt: now,
    });
    delete record.ended;
  } else if (input.hook_event_name === 'SessionEnd') {
    record.ended = { sessionId: input.session_id, reason: input.reason, at: now };
  } else {
    return;
  }

  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(record, null, 2));
  fs.renameSync(tmp, file);
}
