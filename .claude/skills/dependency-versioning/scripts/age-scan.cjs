#!/usr/bin/env node
// Transitive-cascade 7-day check. Diffs package-lock.json against a git ref
// (default HEAD), then for EVERY package version that changed, reads its publish
// time from the npm registry and flags any version younger than 7 days.
//
// This catches the trap where bumping one hub package (e.g. `vite`) silently
// re-resolves transitives — including shipped native modules — up to a <7-day
// batch release that no direct `npm install` named.
//
// It fails closed: a publish time it can't read (registry down, a version the
// registry doesn't list, a git or file dependency) is never counted as safe.
//
// Usage:   node .claude/skills/dependency-versioning/scripts/age-scan.cjs [gitRef] [lockfile]   (from the repo root)
// Example: node .claude/skills/dependency-versioning/scripts/age-scan.cjs HEAD apps/game/package-lock.json
// A lockfile that doesn't exist at gitRef (a new app) has every package checked.
// Registry: $npm_config_registry, else https://registry.npmjs.org.
// Exit:    0 if every changed version is at least 7 days old; 1 if any is younger;
//          2 if gitRef isn't a commit or a lockfile can't be read;
//          3 if any publish time couldn't be read (and nothing younger was found).
const fs = require('fs');
const { execFileSync } = require('child_process');

const root = process.cwd();
const ref = process.argv[2] || 'HEAD';
const lockPath = (process.argv[3] || 'package-lock.json').replace(/\\/g, '/'); // repo-root-relative, forward slashes for git show
const registry = (process.env.npm_config_registry || 'https://registry.npmjs.org').replace(/\/+$/, '');
const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000; // published at or before this instant = safe
const CONCURRENCY = 8;
const TIMEOUT_MS = 20_000;

function fail(message) {
  console.error(message);
  process.exit(2);
}

/** The lockfile's `packages` map; a lockfile that isn't JSON, or has no such map, stops the scan. */
function lockPackages(json, where) {
  let parsed;
  try { parsed = JSON.parse(json); } catch { fail(`${where} isn't valid JSON`); }
  if (!parsed || typeof parsed.packages !== 'object' || parsed.packages === null) {
    fail(`${where} has no "packages" map (lockfileVersion 2 or 3 is needed)`);
  }
  return parsed.packages;
}

let curText;
try { curText = fs.readFileSync(root + '/' + lockPath, 'utf8'); } catch { fail(`can't read ${lockPath}`); }
const cur = lockPackages(curText, lockPath);

try { execFileSync('git', ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`], { cwd: root, stdio: 'ignore' }); }
catch { fail(`${ref} isn't a commit`); }
let base = {};
let atRef = true;
try { execFileSync('git', ['cat-file', '-e', `${ref}:${lockPath}`], { cwd: root, stdio: 'ignore' }); }
catch { atRef = false; } // a new lockfile: every package in it is new, so check them all
if (atRef) {
  let text;
  try { text = execFileSync('git', ['show', `${ref}:${lockPath}`], { cwd: root, maxBuffer: 1e9 }).toString(); }
  catch { fail(`could not read ${lockPath} at ${ref}`); }
  base = lockPackages(text, `${lockPath} at ${ref}`);
} else {
  console.log(`${lockPath} doesn't exist at ${ref}: checking every package in it`);
}

// Every package version that is new or changed at its install path. Keyed by name@version, so two
// versions of one package (one nested under another package) are both checked.
const nameOf = (k, entry) => entry.name || k.replace(/.*node_modules\//, '');
const changed = new Map(); // "name@version" -> { name, version, resolved }
for (const [k, entry] of Object.entries(cur)) {
  if (!k.includes('node_modules/') || entry.link) continue;
  const before = base[k] && base[k].version;
  if (!entry.version || before === entry.version) continue;
  const name = nameOf(k, entry);
  changed.set(`${name}@${entry.version}`, { name, version: entry.version, resolved: entry.resolved || '' });
}
if (!changed.size) { console.log('no resolved-version changes vs ' + ref); process.exit(0); }

const packageUrl = name => `${registry}/${name.startsWith('@') ? name.replace('/', '%2f') : name}`;

/** Publish time of name@version in epoch ms, or an Error saying why it isn't known. */
async function publishTime({ name, version, resolved }) {
  if (resolved && !/^https?:\/\//.test(resolved)) return new Error(`not from a registry (${resolved.split(':')[0]})`);
  let lastError = null;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const res = await fetch(packageUrl(name), { signal: AbortSignal.timeout(TIMEOUT_MS), headers: { accept: 'application/json' } });
      if (res.status === 404) return new Error('not in the registry');
      if (!res.ok) { lastError = new Error(`registry answered ${res.status}`); continue; }
      const t = ((await res.json()).time || {})[version];
      const ms = t ? Date.parse(t) : NaN;
      return Number.isNaN(ms) ? new Error('the registry lists no publish time for this version') : ms;
    } catch (err) {
      lastError = new Error(`registry unreachable (${err && err.name === 'TimeoutError' ? 'timeout' : (err && err.message) || err})`);
    }
  }
  return lastError;
}

async function main() {
  console.log(`checking publish times of ${changed.size} changed package versions (safe = published at or before ${new Date(cutoff).toISOString()})\n`);
  const items = [...changed.values()].sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await publishTime(items[i]);
    }
  }));

  let violations = 0;
  let unknown = 0;
  items.forEach((p, i) => {
    const t = results[i];
    const label = `  ${p.name}@${p.version}`;
    if (t instanceof Error) {
      unknown++;
      console.log(`${label}  ???  publish time unknown: ${t.message}`);
    } else if (t > cutoff) {
      violations++;
      console.log(`${label}  ${new Date(t).toISOString()}  <<< <7 DAYS — pin to newest-safe via overrides`);
    } else {
      console.log(`${label}  ${new Date(t).toISOString()}  safe`);
    }
  });
  console.log(`\n<7-day violations: ${violations}`);
  console.log(`unknown publish times: ${unknown}${unknown ? ' (not proven safe: re-run, or check those versions by hand)' : ''}`);
  // Exit once the report is written out: on Windows, writes to a pipe are asynchronous.
  const code = violations ? 1 : unknown ? 3 : 0;
  process.stdout.write('', () => process.exit(code));
}

main().catch(err => {
  console.error(`age-scan failed: ${(err && err.stack) || err}`);
  process.exit(2);
});
