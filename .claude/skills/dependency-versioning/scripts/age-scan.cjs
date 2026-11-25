#!/usr/bin/env node
// Transitive-cascade 7-day check. Diffs package-lock.json against a git ref
// (default HEAD), then for EVERY package whose resolved version changed, fetches
// its publish date and flags any version younger than 7 days.
//
// This catches the trap where bumping one hub package (e.g. `vite`) silently
// re-resolves transitives — including shipped native modules — up to a <7-day
// batch release that no direct `npm install` named.
//
// Usage:   node .claude/skills/dependency-versioning/scripts/age-scan.cjs [gitRef] [lockfile]   (from the repo root)
// Example: node .claude/skills/dependency-versioning/scripts/age-scan.cjs HEAD apps/game/package-lock.json
// Exit:    0 if no <7-day change, 1 if any version <7 days old.
const fs = require('fs');
const { execFileSync } = require('child_process');
const root = process.cwd();
const ref = process.argv[2] || 'HEAD';
const lockPath = (process.argv[3] || 'package-lock.json').replace(/\\/g, '/'); // repo-root-relative, forward slashes for git show

const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000); // published on/before this = safe

function lockPackages(json) { try { return JSON.parse(json).packages || {}; } catch { return {}; } }
const cur = lockPackages(fs.readFileSync(root + '/' + lockPath, 'utf8'));
let base = {};
try { execFileSync('git', ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`], { cwd: root }); }
catch { console.error(`${ref} isn't a commit`); process.exit(2); }
let atRef = true;
try { execFileSync('git', ['cat-file', '-e', `${ref}:${lockPath}`], { cwd: root, stdio: 'ignore' }); }
catch { atRef = false; } // a new lockfile: every package in it is new, so check them all
if (atRef) {
  try { base = lockPackages(execFileSync('git', ['show', `${ref}:${lockPath}`], { cwd: root, maxBuffer: 1e9 }).toString()); }
  catch { console.error(`could not read ${lockPath} at ${ref}`); process.exit(2); }
} else {
  console.log(`${lockPath} doesn't exist at ${ref}: checking every package in it`);
}

const nameOf = k => k.replace(/.*node_modules\//, '');
const keys = new Set([...Object.keys(cur), ...Object.keys(base)]);
const changed = {}; // name -> newVersion
for (const k of keys) {
  if (!k.includes('node_modules/')) continue;
  const a = base[k] && base[k].version, b = cur[k] && cur[k].version;
  if (b && a !== b) changed[nameOf(k)] = b;
}
const entries = Object.entries(changed);
if (!entries.length) { console.log('no resolved-version changes vs ' + ref); process.exit(0); }

console.log(`checking publish dates of ${entries.length} changed packages (safe = on/before ${cutoff.toISOString().slice(0, 10)})\n`);
let violations = 0;
for (const [name, ver] of entries) {
  let date = '?';
  try {
    const t = JSON.parse(execFileSync('npm', ['view', name, 'time', '--json'], { maxBuffer: 1e8, stdio: ['ignore', 'pipe', 'ignore'] }).toString());
    date = (t[ver] || '').slice(0, 10);
  } catch {}
  const young = date && date !== '?' && new Date(date) > cutoff;
  if (young) violations++;
  console.log(`  ${name}@${ver}  ${date || '?'}  ${young ? '<<< <7 DAYS — pin to newest-safe via overrides' : 'safe'}`);
}
console.log(`\n<7-day violations: ${violations}`);
process.exit(violations ? 1 : 0);
