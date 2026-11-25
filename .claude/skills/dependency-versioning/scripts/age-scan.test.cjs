'use strict';
// Tests for age-scan.cjs, against a fake npm registry and a throwaway git repo per case.
// Run from the repo root: node --test .claude/skills/dependency-versioning/scripts/age-scan.test.cjs
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFile, execFileSync } = require('node:child_process');

const SCRIPT = path.join(__dirname, 'age-scan.cjs');
const DAY = 24 * 60 * 60 * 1000;
const iso = ms => new Date(ms).toISOString();

// The fake registry: routes[path] = { status, body }; anything else is a 404.
let server;
let registry;
let routes = {};
let hits = [];
before(async () => {
  server = http.createServer((req, res) => {
    hits.push(req.url);
    const route = routes[req.url];
    res.writeHead(route ? route.status || 200 : 404, { 'content-type': 'application/json' });
    res.end(JSON.stringify(route ? route.body || {} : {}));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  registry = `http://127.0.0.1:${server.address().port}`;
});
after(() => new Promise(resolve => server.close(resolve)));

/** Publish times for one package: { version: epoch ms }. */
const published = times => ({ body: { time: Object.fromEntries(Object.entries(times).map(([v, ms]) => [v, iso(ms)])) } });
const entry = (version, extra = {}) => ({ version, resolved: `https://registry.example/pkg-${version}.tgz`, ...extra });
const lockfile = packages => JSON.stringify({ name: 'app', lockfileVersion: 3, requires: true, packages: { '': { name: 'app' }, ...packages } }, null, 2);

// git with no system or user config, so the tests don't depend on the machine they run on.
function gitEnv(dir) {
  const empty = path.join(dir, '.gitconfig-empty');
  fs.writeFileSync(empty, '');
  return {
    ...process.env,
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: empty,
    GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 'test@example.invalid',
    GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 'test@example.invalid',
  };
}

/** A repo whose HEAD holds `base` as package-lock.json (null: no lockfile), with `current` in the working tree. */
function repo(t, base, current) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'age-scan-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const env = gitEnv(dir);
  const git = (...args) => execFileSync('git', args, { cwd: dir, env, stdio: 'ignore' });
  git('init', '-q');
  git('commit', '-q', '--allow-empty', '-m', 'start');
  if (base !== null) {
    fs.writeFileSync(path.join(dir, 'package-lock.json'), base);
    git('add', 'package-lock.json');
    git('commit', '-q', '-m', 'lockfile');
  }
  if (current === null) fs.rmSync(path.join(dir, 'package-lock.json'), { force: true });
  else fs.writeFileSync(path.join(dir, 'package-lock.json'), current);
  return { dir, env };
}

/** Runs the scan asynchronously (the fake registry lives in this process). */
function scan({ dir, env }, { args = ['HEAD', 'package-lock.json'], reg = registry } = {}) {
  hits = [];
  return new Promise(resolve => {
    execFile(process.execPath, [SCRIPT, ...args], { cwd: dir, env: { ...env, npm_config_registry: reg } }, (err, stdout, stderr) => {
      resolve({ code: err ? err.code : 0, out: stdout + stderr });
    });
  });
}

const before1 = lockfile({ 'node_modules/left-pad': entry('1.0.0') });
const after1 = version => lockfile({ 'node_modules/left-pad': entry(version) });

test('a version older than 7 days is safe', async t => {
  routes = { '/left-pad': published({ '1.1.0': Date.now() - 30 * DAY }) };
  const r = await scan(repo(t, before1, after1('1.1.0')));
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /left-pad@1\.1\.0 {2}\S+ {2}safe/);
});

test('a version published an hour ago is a violation', async t => {
  routes = { '/left-pad': published({ '1.1.0': Date.now() - 3600 * 1000 }) };
  const r = await scan(repo(t, before1, after1('1.1.0')));
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /<<< <7 DAYS/);
});

test('the cutoff is an instant, not a day: an hour inside the 7 days is a violation', async t => {
  routes = { '/left-pad': published({ '1.1.0': Date.now() - 7 * DAY + 3600 * 1000 }) };
  const r = await scan(repo(t, before1, after1('1.1.0')));
  assert.equal(r.code, 1, r.out);
});

for (const [name, setup, reason] of [
  ['the registry answers 500 (asked twice)', () => ({ '/left-pad': { status: 500 } }), /registry answered 500/],
  ['the registry lists no time for the version', () => ({ '/left-pad': published({ '1.0.0': Date.now() - 30 * DAY }) }), /no publish time/],
  ['the package is not in the registry', () => ({}), /not in the registry/],
]) {
  test(`fails closed when ${name}`, async t => {
    routes = setup();
    const r = await scan(repo(t, before1, after1('1.1.0')));
    assert.equal(r.code, 3, r.out);
    assert.match(r.out, reason);
    assert.match(r.out, /unknown publish times: 1/);
    if (name.includes('500')) assert.equal(hits.length, 2, 'one retry');
  });
}

test('fails closed when the registry is unreachable', async t => {
  const closed = http.createServer();
  await new Promise(resolve => closed.listen(0, '127.0.0.1', resolve));
  const port = closed.address().port;
  await new Promise(resolve => closed.close(resolve));
  const r = await scan(repo(t, before1, after1('1.1.0')), { reg: `http://127.0.0.1:${port}` });
  assert.equal(r.code, 3, r.out);
  assert.match(r.out, /registry unreachable/);
});

test('a git dependency is never counted as safe', async t => {
  routes = {};
  const current = lockfile({ 'node_modules/left-pad': entry('1.1.0', { resolved: 'git+ssh://git@example.com/left-pad.git#abc' }) });
  const r = await scan(repo(t, before1, current));
  assert.equal(r.code, 3, r.out);
  assert.match(r.out, /not from a registry \(git\+ssh\)/);
  assert.equal(hits.length, 0);
});

test('a violation wins over an unknown time', async t => {
  routes = { '/a': published({ '1.0.0': Date.now() - 3600 * 1000 }), '/b': { status: 503 } };
  const r = await scan(repo(t, lockfile({}), lockfile({ 'node_modules/a': entry('1.0.0'), 'node_modules/b': entry('1.0.0') })));
  assert.equal(r.code, 1, r.out);
});

test('two versions of one package are both checked', async t => {
  routes = { '/ms': published({ '2.1.3': Date.now() - 300 * DAY, '3.0.0': Date.now() - 3600 * 1000 }) };
  const base = lockfile({});
  const current = lockfile({ 'node_modules/ms': entry('2.1.3'), 'node_modules/debug/node_modules/ms': entry('3.0.0') });
  const r = await scan(repo(t, base, current));
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /ms@2\.1\.3 .* safe/);
  assert.match(r.out, /ms@3\.0\.0 .*<<< <7 DAYS/);
});

test('a scoped package is fetched with an encoded slash', async t => {
  routes = { '/@types%2fnode': published({ '26.6.6': Date.now() - 30 * DAY }) };
  const r = await scan(repo(t, lockfile({}), lockfile({ 'node_modules/@types/node': entry('26.6.6') })));
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(hits, ['/@types%2fnode']);
});

test('an unchanged lockfile needs no registry', async t => {
  routes = {};
  const r = await scan(repo(t, before1, before1));
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /no resolved-version changes/);
  assert.equal(hits.length, 0);
});

test('a lockfile new at the ref has every package checked', async t => {
  routes = { '/left-pad': published({ '1.0.0': Date.now() - 30 * DAY }) };
  const r = await scan(repo(t, null, before1));
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /doesn't exist at HEAD: checking every package/);
});

test('links (workspace packages) are skipped', async t => {
  routes = {};
  const r = await scan(repo(t, lockfile({}), lockfile({ 'node_modules/local': { resolved: 'packages/local', link: true } })));
  assert.equal(r.code, 0, r.out);
  assert.equal(hits.length, 0);
});

for (const [name, base, current, args, reason] of [
  ['the ref is not a commit', before1, after1('1.1.0'), ['no-such-ref', 'package-lock.json'], /isn't a commit/],
  ['the lockfile is missing', before1, null, undefined, /can't read/],
  ['the lockfile is not JSON', before1, '{ not json', undefined, /isn't valid JSON/],
  ['the lockfile has no packages map', before1, JSON.stringify({ lockfileVersion: 1, dependencies: {} }), undefined, /no "packages" map/],
  ['the lockfile at the ref is not JSON', '{ broken', after1('1.1.0'), undefined, /at HEAD isn't valid JSON/],
]) {
  test(`exits 2 when ${name}`, async t => {
    routes = {};
    const r = await scan(repo(t, base, current), args ? { args } : {});
    assert.equal(r.code, 2, r.out);
    assert.match(r.out, reason);
  });
}
