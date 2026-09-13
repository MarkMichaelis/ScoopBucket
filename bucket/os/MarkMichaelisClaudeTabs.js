// Helper for the Git Bash side of Windows Terminal tab colors and Claude tab restore
// (claude-tabs.bash). Mirrors ClaudeTabs.psm1: both read and write the same color map
// and session records, so keep the palette and rules here in sync with the module.
//
//   color <dir>                     print the tab color for a Windows path, or nothing
//   shellstart <pid>                print a process's start time (Windows file time)
//   record <token> <launchDir> <shellPid> <shellStart> <sessionId> -- <claude args...>
//   restore <dir>                   for a tab restored into a session folder, print:
//                                   launchDir, sessionId to resume (or blank), token,
//                                   then one kept claude option per line
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const tabsRoot = path.join(os.homedir(), '.claude', 'terminal-tabs');
const sessionsRoot = path.join(tabsRoot, 'sessions');
const colorsFile = path.join(tabsRoot, 'colors.json');
const palette = [
  '#2E86DE', '#E67E22', '#27AE60', '#C0392B', '#8E44AD', '#16A085',
  '#D81B60', '#B7950B', '#3949AB', '#6D4C41', '#00838F', '#7CB342'];

function run(file, args) {
  try {
    return execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
  } catch {
    return null;
  }
}

function projectRoot(dir) {
  let root = null;
  const commonDir = run('git', ['-C', dir, 'rev-parse', '--path-format=absolute', '--git-common-dir']).replace(/\//g, '\\');
  if (commonDir) {
    if (path.win32.basename(commonDir).toLowerCase() === '.git') {
      // The main worktree, even when dir is inside a linked worktree.
      root = path.win32.dirname(commonDir);
    } else {
      const top = run('git', ['-C', dir, 'rev-parse', '--show-toplevel']);
      if (top) root = top.replace(/\//g, '\\');
    }
  }
  if (!root) {
    const match = dir.match(/^[A-Za-z]:\\Git\\[^\\]+/i);
    if (match) root = match[0];
  }
  return root;
}

function colorFor(root) {
  const key = root.replace(/\\+$/, '').toLowerCase();
  const map = {};
  for (const [name, value] of Object.entries(readJson(colorsFile) || {})) map[name.toLowerCase()] = String(value);
  if (map[key]) return map[key];
  const used = new Set(Object.values(map).map(v => v.toUpperCase()));
  let color = palette.find(c => !used.has(c));
  if (!color) color = palette[crypto.createHash('sha256').update(key, 'utf8').digest()[0] % palette.length];
  map[key] = color;
  fs.mkdirSync(tabsRoot, { recursive: true });
  fs.writeFileSync(colorsFile, JSON.stringify(map, null, 2) + '\n');
  return color;
}

// Launch options worth keeping when a session is resumed (same rules as the module).
function keepArgs(args) {
  const keep = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--') break;
    if (/^--(permission-mode|model|add-dir)=/.test(arg)) { keep.push(arg); continue; }
    if (/^--(permission-mode|model)$/.test(arg) && i + 1 < args.length) { keep.push(arg, args[++i]); continue; }
    if (arg === '--add-dir') {
      keep.push(arg);
      while (i + 1 < args.length && !args[i + 1].startsWith('-')) keep.push(args[++i]);
      continue;
    }
    if (arg === '--remote-control' || arg === '--dangerously-skip-permissions') keep.push(arg);
  }
  return keep;
}

function shellStart(pid) {
  const id = Number(pid);
  if (!Number.isInteger(id) || id <= 0) return '';
  return run('pwsh', ['-NoProfile', '-NonInteractive', '-Command',
    `$p = Get-Process -Id ${id} -ErrorAction SilentlyContinue; if ($p) { $p.StartTime.ToFileTimeUtc() }`]);
}

function ownerAlive(record) {
  const start = shellStart(record.shellPid);
  return start !== '' && start === String(record.shellStart);
}

const [command, ...rest] = process.argv.slice(2);
switch (command) {
  case 'color': {
    const root = projectRoot(rest[0] || '');
    if (root) process.stdout.write(colorFor(root));
    break;
  }
  case 'shellstart':
    process.stdout.write(shellStart(rest[0]));
    break;
  case 'record': {
    const [token, launchDir, shellPid, start, sessionId, separator, ...claudeArgs] = rest;
    if (!/^[0-9a-f]{32}$/.test(token || '') || separator !== '--') process.exit(2);
    const dir = path.join(sessionsRoot, token);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'record.json'), JSON.stringify({
      token,
      launchDir,
      keepArgs: keepArgs(claudeArgs),
      sessionId: sessionId || null,
      shellPid: Number(shellPid),
      shellStart: String(start),
      startedAt: new Date().toISOString(),
    }, null, 2) + '\n');
    break;
  }
  case 'restore': {
    const dir = rest[0] || '';
    if (!dir.toLowerCase().startsWith(sessionsRoot.toLowerCase() + '\\')) break;
    const record = readJson(path.join(dir, 'record.json'));
    if (!record || !record.launchDir || !fs.existsSync(record.launchDir)) {
      process.stdout.write('\n');
      break;
    }
    const ended = record.ended && record.ended.sessionId === record.sessionId &&
      ['prompt_input_exit', 'logout'].includes(record.ended.reason);
    const resume = record.sessionId && !ended && !ownerAlive(record) ? record.sessionId : '';
    const lines = [record.launchDir, resume, path.basename(dir), ...(record.keepArgs || [])];
    process.stdout.write(lines.join('\n') + '\n');
    break;
  }
  default:
    process.exit(2);
}
