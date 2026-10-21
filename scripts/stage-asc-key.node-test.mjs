// The ASC key handoff must never leave the key in the environment or the log.
//
// This drives scripts/stage-asc-key.mjs against the real
// scripts/ios-stage-asc-key.sh and checks the file it writes.
//
// The script resolves every credential environment-first and then through an
// approved fallback, so the test stubs that fallback -- the injected getter
// -- rather than a network endpoint.  Nothing here reaches the vault.
//
// Run: node --test scripts/stage-asc-key.node-test.mjs
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { run } from './stage-asc-key.mjs';

// A synthetic fixture, not a credential.  It stands in for the private key
// so the test can tell a leak from a clean run.
const KEY_MARKER = 'SYNTHETIC-MULTILINE-FIXTURE-DO-NOT-USE';
const KEY = `-----BEGIN PRIVATE KEY-----\n${KEY_MARKER}\n-----END PRIVATE KEY-----`;
const VAULT = {
  ASC_KEY_ID: 'STUBKEYID',
  ASC_ISSUER_ID: 'STUBISSUER',
  ASC_KEY_P8: KEY,
};

function baseEnv(dir, overrides = {}) {
  // The staging script makes its own directory inside the staging root, so
  // the root has to exist first.
  mkdirSync(join(dir, 'staging'), { recursive: true });
  return {
    GITHUB_ENV: join(dir, 'env'),
    ASC_STAGING_ROOT: join(dir, 'staging'),
    ...overrides,
  };
}

/** The approved fallback, stubbed at its seam: the getter the script calls
 * when the environment does not carry the name. */
function stubGetter(values = VAULT) {
  const calls = [];
  const getSecret = async (name) => {
    calls.push(name);
    return values[name] ?? '';
  };
  getSecret.calls = calls;
  return getSecret;
}

function mode(path) {
  return statSync(path).mode & 0o777;
}

/** Write an entry the way the runner's environment file holds it: the
 * single-line form for a plain value, the heredoc form for one that carries
 * newlines. */
function writeEnvEntry(path, name, value) {
  const delimiter = 'INFISICAL_TESTDELIMITER';
  writeFileSync(path, `${name}<<${delimiter}\n${value}\n${delimiter}\n`, { flag: 'a' });
}

test('the key is staged to a mode-600 file and only its path is published', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    const lines = [];
    await run({ env, getSecret: stubGetter(), log: (l) => lines.push(l) });

    const written = readFileSync(env.GITHUB_ENV, 'utf8');
    const match = written.match(/^ASC_KEY_PATH=(.*)$/m);
    assert.ok(match, 'the staging script must publish ASC_KEY_PATH');
    const keyPath = match[1].trim();
    assert.ok(!written.includes(KEY_MARKER), 'the key must never reach GITHUB_ENV');
    assert.equal(mode(keyPath), 0o600, 'the key file must be mode 600');
    assert.equal(mode(join(keyPath, '..')), 0o700, 'the key directory must be mode 700');
    assert.ok(readFileSync(keyPath, 'utf8').includes(KEY_MARKER));

    // The key must not reach the log at all.  The report carries the count
    // only, so a failure never discloses the value it found.
    const keyBearing = lines.filter((l) => l.includes(KEY_MARKER)).length;
    assert.equal(keyBearing, 0, `the key must never reach the log (${keyBearing} key-bearing lines)`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the key never survives into a later step', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    await run({ env, getSecret: stubGetter(), log: () => {} });
    const written = readFileSync(env.GITHUB_ENV, 'utf8');
    assert.ok(!written.includes(KEY_MARKER), 'the key must never reach GITHUB_ENV');
    // The entry is blanked, so the runner hands a later step an empty
    // value rather than the key.
    assert.match(written, /^ASC_KEY_P8=$/m, 'the ASC_KEY_P8 entry must be blanked');
    // The identifiers do cross, because the ship and notarize steps need them.
    assert.match(written, /ASC_KEY_ID/);
    assert.match(written, /ASC_ISSUER_ID/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the environment is looked up first, before the approved fallback', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir, {
      ASC_KEY_ID: 'ENVKEYID',
      ASC_ISSUER_ID: 'ENVISSUER',
      ASC_KEY_P8: `-----BEGIN PRIVATE KEY-----\nENVIRONMENT-COPY\n-----END PRIVATE KEY-----`,
    });
    const getter = stubGetter();
    await run({ env, getSecret: getter, log: () => {} });

    assert.deepEqual(getter.calls, [], 'the fallback must not be consulted when the environment has the name');
    const written = readFileSync(env.GITHUB_ENV, 'utf8');
    assert.match(written, /ENVKEYID/);
    assert.match(written, /ENVISSUER/);
    const keyPath = written.match(/^ASC_KEY_PATH=(.*)$/m)[1].trim();
    assert.ok(readFileSync(keyPath, 'utf8').includes('ENVIRONMENT-COPY'), 'the environment copy is the one that is staged');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the job environment file is read when the process environment does not carry the name', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    // The approved loader writes into the job's environment file; the
    // script reads the same file when the process environment is empty.
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_ID', 'FILEKEYID');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_ISSUER_ID', 'FILEISSUER');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_P8', KEY);

    const getter = stubGetter();
    await run({ env, getSecret: getter, log: () => {} });

    assert.deepEqual(getter.calls, [], 'the fallback must not be consulted when the environment file has the name');
    const written = readFileSync(env.GITHUB_ENV, 'utf8');
    assert.match(written, /FILEKEYID/);
    const keyPath = written.match(/^ASC_KEY_PATH=(.*)$/m)[1].trim();
    assert.ok(readFileSync(keyPath, 'utf8').includes(KEY_MARKER));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the approved fallback is consulted when neither environment carries the name', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    const getter = stubGetter();
    await run({ env, getSecret: getter, log: () => {} });
    assert.deepEqual(getter.calls, ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8']);
    const written = readFileSync(env.GITHUB_ENV, 'utf8');
    assert.match(written, /STUBKEYID/);
    const keyPath = written.match(/^ASC_KEY_PATH=(.*)$/m)[1].trim();
    assert.ok(readFileSync(keyPath, 'utf8').includes(KEY_MARKER));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a missing credential fails the step and names it', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const lines = [];
    await assert.rejects(
      run({
        env: baseEnv(dir),
        getSecret: stubGetter({ ASC_KEY_ID: 'x', ASC_ISSUER_ID: 'y' }),
        log: (l) => lines.push(l),
      }),
      (err) => {
        assert.match(err.message, /Missing ASC_KEY_P8 in Fleet-OPS prod \/asc/);
        return true;
      },
    );
    assert.ok(lines.some((l) => l.includes('Fleet-OPS prod /asc')), 'the error names the path');
    assert.ok(lines.some((l) => l.includes('ASC_KEY_P8')), 'the error names the secret');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an unresolved Infisical reference is rejected before anything is staged', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    const lines = [];
    await assert.rejects(
      run({
        env,
        getSecret: stubGetter({ ...VAULT, ASC_KEY_P8: '${prod.some-folder.ASC_KEY_P8}' }),
        log: (l) => lines.push(l),
      }),
      (err) => {
        assert.match(err.message, /unresolved Infisical secret reference/);
        return true;
      },
    );
    assert.ok(!existsSync(env.GITHUB_ENV) || !readFileSync(env.GITHUB_ENV, 'utf8').includes('ASC_KEY_PATH'));
    assert.ok(lines.some((l) => l.includes('ASC_KEY_P8')), 'the error names the secret');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
