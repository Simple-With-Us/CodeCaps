// The ASC key handoff must never leave the key in the environment or the log.
//
// This drives scripts/stage-asc-key.mjs against the real
// scripts/ios-stage-asc-key.sh and checks the file it writes.
//
// The script resolves every credential environment-first and then through an
// approved fallback, so the test stubs that fallback -- the injected getter
// -- rather than a network endpoint.  Nothing here reaches the vault.
//
// Every fixture is synthetic.  The private key in these tests is a marker
// string, not a credential.
//
// Run: node --test scripts/stage-asc-key.node-test.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { run } from './stage-asc-key.mjs';
import { run as loaderRun } from './infisical-fetch.mjs';

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

/** The runner imports the job's environment file into the environment of
 * every later step in the job: a `NAME=value` line sets the variable, and a
 * `NAME<<delimiter` block sets it to the body between the delimiters.  This
 * mirrors that reading, so a test can assert what a later step would actually
 * be handed. */
function importEnvironmentFile(path) {
  const imported = {};
  if (!existsSync(path)) return imported;
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const heredoc = /^([A-Za-z_][A-Za-z0-9_]*)<<(.+)$/.exec(lines[i]);
    if (heredoc) {
      const body = [];
      let j = i + 1;
      while (j < lines.length && lines[j] !== heredoc[2]) {
        body.push(lines[j]);
        j += 1;
      }
      if (j >= lines.length) {
        // An unterminated block: the runner cannot import it either.
        imported[heredoc[1]] = undefined;
        i = lines.length;
        continue;
      }
      imported[heredoc[1]] = body.join('\n');
      i = j;
      continue;
    }
    const single = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(lines[i]);
    if (single) imported[single[1]] = single[2];
  }
  return imported;
}

/** The assertion that matters after every path: the file carries no
 * key-bearing entry, and a later step is handed no key. */
function assertNoKeySurvives(envPath) {
  const written = readFileSync(envPath, 'utf8');
  assert.ok(!written.includes(KEY_MARKER), 'the key bytes must not survive in the environment file');
  assert.doesNotMatch(written, /ASC_KEY_P8/, 'the ASC_KEY_P8 entry must be removed, not blanked');
  const imported = importEnvironmentFile(envPath);
  assert.ok(!('ASC_KEY_P8' in imported), 'a later step must not be handed the key');
  assert.equal(imported.ASC_KEY_P8, undefined, 'a later step must see no value for the key');
  return imported;
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
    // The entry is removed from the file, not blanked: the earlier bytes are
    // gone, so the runner has nothing to import into a later step.
    assert.doesNotMatch(written, /ASC_KEY_P8/, 'the ASC_KEY_P8 entry must be removed from the environment file');
    const imported = importEnvironmentFile(env.GITHUB_ENV);
    assert.ok(!('ASC_KEY_P8' in imported), 'a later step must not be handed the key');
    // The identifiers do cross, because the ship and notarize steps need them.
    assert.match(written, /ASC_KEY_ID/);
    assert.match(written, /ASC_ISSUER_ID/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the loader's key entry is removed from the environment file, not blanked", async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    // The approved loader writes the three values into the job's environment
    // file before this script runs.
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_ID', 'FILEKEYID');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_ISSUER_ID', 'FILEISSUER');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_P8', KEY);

    const before = readFileSync(env.GITHUB_ENV, 'utf8');
    assert.ok(before.includes(KEY_MARKER), 'the loader wrote the key into the environment file');

    await run({ env, getSecret: stubGetter(), log: () => {} });

    const imported = assertNoKeySurvives(env.GITHUB_ENV);
    assert.equal(imported.ASC_KEY_ID, 'FILEKEYID', 'the identifiers still cross into the later steps');
    assert.equal(imported.ASC_ISSUER_ID, 'FILEISSUER');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the loader-then-staging sequence leaves no key behind when the loader fails', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    // The vault answers with the private key and nothing for the identifier,
    // which is the shape of a partial read.  The loader writes every value it
    // does have into the job's environment file and only then fails on the
    // one that is missing, so the key is already in the file when the step
    // dies.
    const stubFetch = async (url) => {
      const u = String(url);
      if (u.includes('/api/v1/auth/universal-auth/login')) {
        return { ok: true, json: async () => ({ accessToken: 'test-token', expiresIn: 3600 }) };
      }
      if (u.includes('/api/v3/secrets/raw')) {
        return {
          ok: true,
          json: async () => ({
            secrets: [{ secretKey: 'ASC_KEY_P8', secretValue: KEY }],
          }),
        };
      }
      throw new Error(`stubFetch: unexpected URL ${u}`);
    };

    await assert.rejects(
      loaderRun({
        env: {
          ...env,
          INFISICAL_NAMES: 'ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8',
          INFISICAL_REQUIRED: 'ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8',
          INFISICAL_PROJECT_ID: 'project',
          INFISICAL_CLIENT_ID: 'client',
          INFISICAL_CLIENT_SECRET: 'secret',
        },
        fetchImpl: stubFetch,
        log: () => {},
      }),
      /Missing required Infisical name/,
    );

    // The loader wrote the key before it failed: this is the state the
    // staging script has to clean up, and the state the workflow leaves
    // behind when the fetch fails.
    assert.ok(
      readFileSync(env.GITHUB_ENV, 'utf8').includes(KEY_MARKER),
      'the loader wrote the key into the environment file before it failed',
    );

    // Now the staging script runs, exactly as the workflow runs it.
    await run({ env, getSecret: stubGetter(), log: () => {} });

    assertNoKeySurvives(env.GITHUB_ENV);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a staging failure leaves no key-bearing entry behind', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_ID', 'FILEKEYID');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_ISSUER_ID', 'FILEISSUER');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_P8', KEY);

    const failing = join(dir, 'failing-staging.sh');
    writeFileSync(failing, '#!/usr/bin/env bash\nexit 3\n');

    await assert.rejects(
      run({ env, getSecret: stubGetter(), log: () => {}, stagingScript: failing }),
      /staging script exited 3/,
    );

    // The step failed, so the key must not be waiting in the environment file
    // for the runner to hand to the next step.
    assertNoKeySurvives(env.GITHUB_ENV);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('malformed multiline data fails closed and leaves no key-bearing entry', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    // A heredoc block whose delimiter never arrives: the file was truncated,
    // or the step that wrote it was interrupted.
    writeFileSync(env.GITHUB_ENV, `ASC_KEY_P8<<INFISICAL_TESTDELIMITER\n${KEY}\n`);

    const lines = [];
    await assert.rejects(
      run({ env, getSecret: stubGetter(), log: (l) => lines.push(l) }),
      (err) => {
        assert.match(err.message, /malformed in the job environment file/);
        return true;
      },
    );
    assert.ok(lines.some((l) => l.includes('ASC_KEY_P8')), 'the error names the secret');
    assert.ok(lines.some((l) => l.includes('Fleet-OPS prod /asc')), 'the error names the path');

    assertNoKeySurvives(env.GITHUB_ENV);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a malformed entry does not reject a credential the environment carries', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir, { ASC_KEY_ID: 'ENVKEYID' });
    // The file holds a truncated block for the same name.  The malformed
    // verdict is about the file, not about the value in hand, so the
    // environment's own credential is used and the step is not failed with
    // an error that names a file nobody read.
    writeFileSync(env.GITHUB_ENV, 'ASC_KEY_ID<<INFISICAL_TESTDELIMITER\ntruncated\n');
    const lines = [];
    await run({ env, getSecret: stubGetter(), log: (l) => lines.push(l) });
    assert.ok(
      !lines.some((l) => l.includes('malformed')),
      'the verdict on the file must not reject a credential the environment carries',
    );
    const written = readFileSync(env.GITHUB_ENV, 'utf8');
    assert.match(written, /ENVKEYID/, 'the credential the environment carried is the one that crosses forward');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an interruption leaves no key-bearing entry behind', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_ID', 'FILEKEYID');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_ISSUER_ID', 'FILEISSUER');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_P8', KEY);

    // A staging script that announces itself and then waits, so the test can
    // interrupt the run while it is in flight.
    const stalling = join(dir, 'stalling-staging.sh');
    writeFileSync(stalling, '#!/usr/bin/env bash\nset -euo pipefail\ntouch "$ASC_STAGING_ROOT/ready"\nsleep 10\n');
    const ready = join(dir, 'staging', 'ready');

    const driver = join(dir, 'driver.mjs');
    writeFileSync(driver, [
      `import { run } from ${JSON.stringify(new URL('./stage-asc-key.mjs', import.meta.url).href)};`,
      `const env = { GITHUB_ENV: ${JSON.stringify(env.GITHUB_ENV)}, ASC_STAGING_ROOT: ${JSON.stringify(env.ASC_STAGING_ROOT)} };`,
      `await run({ env, getSecret: async () => '', stagingScript: ${JSON.stringify(stalling)} });`,
    ].join('\n'));

    // stdio is ignored so the orphaned staging shell holds no pipe open and
    // the test does not wait for it.
    const child = spawn(process.execPath, [driver], { stdio: 'ignore' });
    const exited = new Promise((resolve) => child.on('exit', (code) => resolve(code)));

    const deadline = Date.now() + 10000;
    while (!existsSync(ready) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 50));
    }
    assert.ok(existsSync(ready), 'the staging script must have started');

    child.kill('SIGTERM');
    const code = await exited;
    assert.notEqual(code, 0, 'an interrupted run must fail the step');

    assertNoKeySurvives(env.GITHUB_ENV);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the key does not survive in the process environment', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir, { ASC_KEY_P8: KEY });
    await run({ env, getSecret: stubGetter(), log: () => {} });
    assert.equal(env.ASC_KEY_P8, undefined, 'the key must not stay in the process environment');
    assertNoKeySurvives(env.GITHUB_ENV);
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
