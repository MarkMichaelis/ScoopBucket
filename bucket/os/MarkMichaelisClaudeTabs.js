// Helper for the Git Bash side of Windows Terminal tab colors and Claude tab restore
// (claude-tabs.bash). Mirrors ClaudeTabs.psm1: both read and write the same root map
// and session records, and resolve the same root, key, and color for a folder, so
// keep the rules here in sync with the module. Migrating an earlier path-keyed map is
// left to the module: until it has run, this helper leaves tabs uncolored.
//
//   color <dir>                     print the tab color for a Windows path, or nothing
//   sequence <count>                print the first <count> colors of the color sequence
//   shellstart <pid>                print a process's start time (Windows file time)
//   record <token> <launchDir> <shellPid> <shellStart> <sessionId> -- <claude args...>
//   restore <dir>                   for a tab restored into a session folder, print:
//                                   launchDir, sessionId to resume (or blank), token,
//                                   then one kept claude option per line
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const tabsRoot = path.join(os.homedir(), '.claude', 'terminal-tabs');
const sessionsRoot = path.join(tabsRoot, 'sessions');
const env = process.env;
const storeDir = path.join(env.OneDriveCommercial ? path.join(env.OneDriveCommercial, 'Documents')
  : env.OneDrive ? path.join(env.OneDrive, 'Documents') : env.APPDATA || '', 'WindowsTerminalTabs');
const rootsFile = path.join(storeDir, 'tab-roots.json');
const legacyColorFiles = [path.join(storeDir, 'colors.json'), path.join(tabsRoot, 'colors.json')];
const homeDir = os.homedir();
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

// Same sequence as Get-ClaudeTabSequenceColor: the palette, then golden-angle hues.
function sequenceColor(index) {
  if (index < palette.length) return palette[index];
  const k = index - palette.length;
  const h = ((k * 137.50776405) + 15) % 360;
  const s = 0.62;
  const l = [0.42, 0.32, 0.52][k % 3];
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  const rgb = [[c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x]][Math.min(Math.floor(h / 60), 5)];
  return '#' + rgb.map(v => Math.floor((v + m) * 255 + 0.5).toString(16).toUpperCase().padStart(2, '0')).join('');
}

function nextColor(colors) {
  const used = new Set(Object.values(colors).map(v => String(v).toUpperCase()));
  for (let i = 0; ; i++) {
    const color = sequenceColor(i);
    if (!used.has(color)) return color;
  }
}

function repoKey(url, folder) {
  const match = (url || '').match(/^(?:git@github\.com:|ssh:\/\/git@github\.com\/|https?:\/\/(?:[^@/]+@)?github\.com\/)(.+)$/i);
  if (match) {
    let slug = match[1].replace(/\/+$/, '');
    if (slug.toLowerCase().endsWith('.git')) slug = slug.slice(0, -4);
    if (/^[^/]+\/[^/]+$/.test(slug)) return slug.toLowerCase();
  }
  return folder.replace(/\\+$/, '').split('\\').pop().toLowerCase();
}

function originUrl(commonDir) {
  let lines;
  try {
    lines = fs.readFileSync(path.win32.join(commonDir, 'config'), 'utf8').split(/\r?\n/);
  } catch {
    return '';
  }
  let inOrigin = false;
  for (const line of lines) {
    if (/^\s*\[/.test(line)) { inOrigin = /^\s*\[remote\s+"origin"\]/.test(line); continue; }
    const match = inOrigin && line.match(/^\s*url\s*=\s*(.+?)\s*$/);
    if (match) return match[1];
  }
  return '';
}

function gitRoot(dir) {
  const out = run('git', ['-C', dir, 'rev-parse', '--path-format=absolute', '--git-common-dir', '--show-toplevel']);
  const lines = out.split(/\r?\n/);
  if (lines.length < 2) return null;
  const commonDir = lines[0].trim().replace(/\//g, '\\');
  const top = lines[1].trim().replace(/\//g, '\\');
  // The main worktree, even when dir is inside a linked worktree.
  const main = path.win32.basename(commonDir).toLowerCase() === '.git' ? path.win32.dirname(commonDir) : top;
  return { path: top, key: repoKey(originUrl(commonDir), main) };
}

function isUnder(dir, root) {
  const d = dir.replace(/\\+$/, '').toLowerCase();
  const r = root.replace(/\\+$/, '').toLowerCase();
  return d === r || d.startsWith(r + '\\');
}

function markedPath(key) {
  return key === '~' || key.startsWith('~\\') ? homeDir.replace(/\\+$/, '') + key.slice(1) : key;
}

function loadStore() {
  const json = readJson(rootsFile);
  if (json && json.version === 2 && json.colors && typeof json.colors === 'object') {
    const colors = {};
    for (const [key, value] of Object.entries(json.colors)) colors[key.toLowerCase()] = String(value);
    return { colors, roots: (json.roots || []).map(r => String(r).toLowerCase()), writable: true };
  }
  if (fs.existsSync(rootsFile)) return { colors: {}, roots: [], writable: false };  // never overwrite what we cannot read
  if (legacyColorFiles.some(f => fs.existsSync(f))) return null;  // PowerShell migrates it first
  return { colors: {}, roots: [], writable: true };
}

function saveStore(store) {
  fs.mkdirSync(storeDir, { recursive: true });
  const temp = `${rootsFile}.${process.pid}.tmp`;
  fs.writeFileSync(temp, JSON.stringify({ version: 2, colors: store.colors, roots: store.roots }, null, 2) + '\n');
  fs.renameSync(temp, rootsFile);
}

// The nearest root containing dir -- a repository, a marked folder, or home -- and its color.
function colorFor(dir) {
  const store = loadStore();
  if (!store) return '';
  const candidates = [];
  const repo = gitRoot(dir);
  if (repo) candidates.push(repo);
  for (const key of store.roots) {
    const rootPath = markedPath(key);
    if (isUnder(dir, rootPath)) candidates.push({ path: rootPath, key });
  }
  if (isUnder(dir, homeDir)) candidates.push({ path: homeDir, key: '~' });
  let best = null;
  for (const candidate of candidates) {
    if (!best || candidate.path.replace(/\\+$/, '').length > best.path.replace(/\\+$/, '').length) best = candidate;
  }
  if (!best) return '';
  if (!store.colors[best.key]) {
    store.colors[best.key] = nextColor(store.colors);
    if (store.writable) saveStore(store);
  }
  return store.colors[best.key];
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
  case 'color':
    if (rest[0]) process.stdout.write(colorFor(rest[0]));
    break;
  case 'sequence':
    process.stdout.write(Array.from({ length: Number(rest[0]) || 0 }, (_, i) => sequenceColor(i)).join('\n') + '\n');
    break;
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
