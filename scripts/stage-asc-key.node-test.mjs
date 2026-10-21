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
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { run, UNRESOLVED_REFERENCE } from './stage-asc-key.mjs';

// A synthetic fixture, not a credential.  It stands in for the private key
// so the test can tell a leak from a clean run.
const KEY_MARKER = 'SYNTHETIC-MULTILINE-FIXTURE-DO-NOT-USE';
const KEY = `-----BEGIN PRIVATE KEY-----\n${KEY_MARKER}\n-----END PRIVATE KEY-----`; // gitleaks:allow
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

/** Run a shell script and collect what it said and how it ended.  Used for
 * the installer, which is a shell script and not a function. */
function runScript(script, { env, args = [], shell = '/bin/bash' }) {
  return new Promise((resolve) => {
    const child = spawn(shell, [script, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

/** A stub reader that fails the way the fleet's reader fails.  The fleet
 * reader's exit codes are its own: 2 is a refused configuration, 4 is a fetch
 * or auth failure and 5 is an unresolved reference in the vault.  A working
 * reader lists the names it found on stdout, one per line, as `names` does. */
function writeStubReader(dir, exitCode, message, names = []) {
  const stubDir = join(dir, 'reader');
  mkdirSync(stubDir, { recursive: true });
  const path = join(stubDir, 'fleet-secrets');
  const listing = names.map((name) => `printf '%s\\n' ${JSON.stringify(name)}\n`).join('');
  writeFileSync(path, `#!/bin/bash\n${listing}printf '%s\\n' ${JSON.stringify(message)} >&2\nexit ${exitCode}\n`, { mode: 0o755 });
  return path;
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

test('a key-bearing entry in the environment file is removed, not blanked', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    // A step wrote the three values into the job's environment file before
    // this script runs.
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_ID', 'FILEKEYID');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_ISSUER_ID', 'FILEISSUER');
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_P8', KEY);

    const before = readFileSync(env.GITHUB_ENV, 'utf8');
    assert.ok(before.includes(KEY_MARKER), 'the key was written into the environment file');

    await run({ env, getSecret: stubGetter(), log: () => {} });

    const imported = assertNoKeySurvives(env.GITHUB_ENV);
    assert.equal(imported.ASC_KEY_ID, 'FILEKEYID', 'the identifiers still cross into the later steps');
    assert.equal(imported.ASC_ISSUER_ID, 'FILEISSUER');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the seeded environment and the reader fallback leave no key behind', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    // The environment carries the identifiers and the approved reader carries
    // the key: that is the composition the workflow runs.  The reader is
    // stubbed at its seam, so nothing here reaches the vault.
    const env = baseEnv(dir, { ASC_KEY_ID: 'ENVKEYID', ASC_ISSUER_ID: 'ENVISSUER' });
    const getSecret = stubGetter();

    await run({ env, getSecret, log: () => {} });

    const imported = assertNoKeySurvives(env.GITHUB_ENV);
    assert.equal(imported.ASC_KEY_ID, 'ENVKEYID', 'the identifier the environment carried is the one that crosses forward');
    assert.equal(imported.ASC_ISSUER_ID, 'ENVISSUER');
    assert.ok(imported.ASC_KEY_PATH, 'the path of the mode-600 key file crosses forward');
    // The reader is asked only for the name the environment did not carry.
    assert.deepEqual(getSecret.calls, ['ASC_KEY_P8']);
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
    // The truncated block is removed before the fresh value is written, so a
    // later step is handed the identifier instead of a file it cannot read
    // past.
    const imported = importEnvironmentFile(env.GITHUB_ENV);
    assert.equal(imported.ASC_KEY_ID, 'ENVKEYID', 'a later step is handed the identifier the environment carried');
    assert.equal(imported.ASC_ISSUER_ID, 'STUBISSUER');
    assert.ok(imported.ASC_KEY_PATH, 'the path of the mode-600 key file crosses forward');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an empty truncated entry fails closed instead of passing as a clean file', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  try {
    const env = baseEnv(dir);
    // The block is truncated and empty: the file carries an entry for the
    // name, but no usable value.  The reader can supply one, and the file is
    // still corrupt, so the step fails closed.
    writeFileSync(env.GITHUB_ENV, 'ASC_KEY_ID<<INFISICAL_TESTDELIMITER\n');
    const lines = [];
    await assert.rejects(
      run({ env, getSecret: stubGetter(), log: (l) => lines.push(l) }),
      /malformed in the job environment file/,
    );
    assertNoKeySurvives(env.GITHUB_ENV);
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
      ASC_KEY_P8: `-----BEGIN PRIVATE KEY-----\nENVIRONMENT-COPY\n-----END PRIVATE KEY-----`, // gitleaks:allow
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

test('a reader that reports an unresolved reference is not read as a missing credential', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-stage-'));
  const saved = process.env.FLEET_SECRETS;
  try {
    // At the seam:  the fallback hands back the reader's verdict, and the
    // consumer names the reference.
    const lines = [];
    await assert.rejects(
      run({
        env: baseEnv(dir),
        getSecret: stubGetter({ ...VAULT, ASC_KEY_P8: UNRESOLVED_REFERENCE }),
        log: (l) => lines.push(l),
      }),
      (err) => {
        assert.match(err.message, /ASC_KEY_P8 is still an unresolved Infisical secret reference/);
        return true;
      },
    );
    assert.ok(!lines.some((l) => l.includes('Missing ASC_KEY_P8')), 'a reference must not read as a missing credential');

    // Through the real fallback:  `fleet-secrets get` exits 5 and prints
    // nothing, and the exit code is what has to survive.
    process.env.FLEET_SECRETS = writeStubReader(dir, 5, 'fleet-secrets: unresolved-reference:  ASC_KEY_ID');
    const env = baseEnv(dir);
    writeEnvEntry(env.GITHUB_ENV, 'ASC_KEY_P8', KEY);
    const realLines = [];
    await assert.rejects(
      run({ env, log: (l) => realLines.push(l) }),
      (err) => {
        assert.match(err.message, /ASC_KEY_ID is still an unresolved Infisical secret reference/);
        return true;
      },
    );
    assert.ok(!realLines.some((l) => l.includes('Missing ASC_KEY_ID')), 'a reference must not read as a missing credential');
    assertNoKeySurvives(env.GITHUB_ENV);
  } finally {
    if (saved === undefined) delete process.env.FLEET_SECRETS;
    else process.env.FLEET_SECRETS = saved;
    rmSync(dir, { recursive: true, force: true });
  }
});

/** The installer, run for real, with the install made to fail.
 *
 * The install is allowed to fail and the consumer still has to run, because
 * the consumer is what removes a key-bearing entry from the job's environment
 * file.  The step then reports the status of the command that actually
 * failed, so a failed install is never reported as a clean run.
 *
 * The install is made to fail with a stub `curl` on PATH, so nothing here
 * reaches the network and the pinned download cannot succeed.
 *
 * The state is the one the release workflows reach after a failed install.
 * No step before the installer writes ASC_KEY_ID or ASC_ISSUER_ID into the
 * job's environment file, and with the install failed there is no working
 * reader and no minted token, so the consumer cannot resolve the identifiers
 * and fails on the first one.  Only the key is seeded, because a key-bearing
 * entry is what the consumer has to remove even when it fails:  the key must
 * not survive into the steps that follow.
 */
test('an installer failure still runs the consumer and clears the key', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-install-'));
  try {
    const envFile = join(dir, 'env');
    writeEnvEntry(envFile, 'ASC_KEY_P8', KEY);

    // A stub curl that always fails:  the pinned download cannot succeed.
    // A stub reader that fails the way a reader with no token fails (exit 4),
    // so the consumer's fallback never reaches a reader this machine happens
    // to have installed.
    const stubDir = join(dir, 'stub');
    mkdirSync(stubDir, { recursive: true });
    writeFileSync(join(stubDir, 'curl'), '#!/usr/bin/env bash\nexit 22\n', { mode: 0o755 });
    const reader = join(stubDir, 'fleet-secrets');
    writeFileSync(reader, '#!/usr/bin/env bash\nexit 4\n', { mode: 0o755 });

    const home = join(dir, 'home');
    mkdirSync(home, { recursive: true });
    const staging = join(dir, 'staging');
    mkdirSync(staging, { recursive: true });

    const env = {
      ...process.env,
      HOME: home,
      PATH: `${stubDir}:${process.env.PATH}`,
      FLEET_SECRETS: reader,
      GITHUB_ENV: envFile,
      ASC_STAGING_ROOT: staging,
      INFISICAL_PROJECT_ID: 'test-project-id',
      INFISICAL_CLIENT_ID: 'test-client-id',
      INFISICAL_CLIENT_SECRET: 'test-client-secret',
    };
    // Nothing from the shell that runs the suite may stand in for the
    // credentials or the token the failed install never produced.
    for (const name of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8', 'INFISICAL_TOKEN']) delete env[name];

    const result = await runScript(fileURLToPath(new URL('install-release-secrets-tooling.sh', import.meta.url)), { env });

    // The install failed, and the step says so instead of reporting success.
    assert.notEqual(result.code, 0, 'a failed install must fail the step');
    assert.match(result.stderr, /could not be downloaded/, 'the failure must name what failed');

    // The consumer ran anyway:  it could not resolve the identifiers, so it
    // said which one was missing, and it still took the key-bearing entry out
    // of the environment file on its way out.
    assert.match(
      result.stderr,
      /Missing ASC_KEY_ID in Fleet-OPS prod \/asc/,
      'the consumer has to run, and it fails on the identifier the workflow never supplied',
    );
    const imported = assertNoKeySurvives(envFile);
    assert.equal(imported.ASC_KEY_PATH, undefined, 'nothing was staged, so no key path crosses forward');

    // And the key never reached the log.
    assert.ok(!result.stdout.includes(KEY_MARKER), 'the key bytes must not reach stdout');
    assert.ok(!result.stderr.includes(KEY_MARKER), 'the key bytes must not reach stderr');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a broken reader is reported as a reader fault, not as a missing credential', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-reader-'));
  try {
    const script = fileURLToPath(new URL('install-release-secrets-tooling.sh', import.meta.url));
    const home = join(dir, 'home');
    mkdirSync(home, { recursive: true });

    // The path holds bash and the coreutils and nothing else, so the reader
    // is only ever the stub this test names.
    const base = {
      ...process.env,
      HOME: home,
      PATH: '/usr/bin:/bin',
      INFISICAL_TOKEN: 'test-token',
      INFISICAL_FLEET_OPS_PROJECT_ID: '11111111-2222-3333-4444-555555555555',
    };

    // A reader that cannot authenticate:  the token is at fault, and the
    // message has to say so instead of blaming the vault permissions.
    // The reader's own text is passed through for the diagnosis, so the
    // stub repeats the token in it:  the token must not reach the log.
    const rejected = writeStubReader(dir, 4, 'fleet-secrets: fetch-failed:  exit-1 for test-token');
    const rejectedResult = await runScript(script, { env: { ...base, FLEET_SECRETS: rejected }, args: ['check-reader'] });
    assert.notEqual(rejectedResult.code, 0, 'a reader that cannot authenticate must fail the check');
    assert.match(rejectedResult.stderr, /access token was rejected/, 'the message must name the token');
    assert.doesNotMatch(rejectedResult.stderr, /Missing ASC_KEY_ID/, 'a reader fault must not read as a missing credential');
    assert.ok(!rejectedResult.stderr.includes('test-token'), 'the access token must not reach the log');
    assert.ok(!rejectedResult.stdout.includes('test-token'), 'the access token must not reach the log');
    assert.ok(!rejectedResult.stderr.includes('test-tok'), 'no slice of a short access token may reach the log');
    assert.ok(!rejectedResult.stdout.includes('test-tok'), 'no slice of a short access token may reach the log');
    assert.match(rejectedResult.stderr, /fetch-failed:  exit-1 for <redacted>/, 'a token too short to have a hidden middle is redacted outright');

    // A reader that refuses the request:  the tooling is at fault.
    const refused = writeStubReader(dir, 2, 'fleet-secrets: refusing Infisical environment');
    const refusedResult = await runScript(script, { env: { ...base, FLEET_SECRETS: refused }, args: ['check-reader'] });
    assert.notEqual(refusedResult.code, 0, 'a refused reader must fail the check');
    assert.match(refusedResult.stderr, /reader or its configuration is at fault/, 'the message must name the reader');

    // An unresolved reference is a credential fault and the consumer names
    // it, so the check does not blame the tooling for it.
    const unresolved = writeStubReader(dir, 5, 'fleet-secrets: unresolved-reference:  ASC_KEY_P8 came back as an unexpanded Infisical reference');
    const unresolvedResult = await runScript(script, { env: { ...base, FLEET_SECRETS: unresolved }, args: ['check-reader'] });
    assert.equal(unresolvedResult.code, 0, 'an unresolved reference is not a reader fault');

    // A working reader that finds every name the release needs passes.
    const working = writeStubReader(dir, 0, '', ['ASC_ISSUER_ID', 'ASC_KEY_ID', 'ASC_KEY_P8', 'OTHER_NAME']);
    const workingResult = await runScript(script, { env: { ...base, FLEET_SECRETS: working }, args: ['check-reader'] });
    assert.equal(workingResult.code, 0, 'a working reader must pass the check');
    assert.match(workingResult.stdout, /can read Fleet-OPS prod \/asc/, 'a passing check says so');

    // A working reader that does not find a name the release needs:  the
    // credential is missing from the vault, and the check names it instead
    // of letting the consumer blame the read permissions.
    const partial = writeStubReader(dir, 0, '', ['ASC_ISSUER_ID', 'ASC_KEY_ID', 'ASC_KEY_P8_OLD']);
    const partialResult = await runScript(script, { env: { ...base, FLEET_SECRETS: partial }, args: ['check-reader'] });
    assert.notEqual(partialResult.code, 0, 'a name the release needs must be in the vault');
    assert.match(partialResult.stderr, /but ASC_KEY_P8 is not there/, 'the message must name the missing credential');
    assert.doesNotMatch(partialResult.stderr, /ASC_KEY_ID|ASC_ISSUER_ID/, 'only the missing name is reported');

    // A name the job's own environment carries is resolved from there first
    // (stage-asc-key.mjs reads the environment before the vault), so its
    // absence from the vault is not a fault and the check must not fail.
    const envProvided = writeStubReader(dir, 0, '', ['ASC_ISSUER_ID', 'ASC_KEY_ID']);
    const envProvidedResult = await runScript(script, {
      env: { ...base, FLEET_SECRETS: envProvided, ASC_KEY_P8: 'test-key-pem' },
      args: ['check-reader']
    });
    assert.equal(envProvidedResult.code, 0, 'a name the environment carries must not be required in the vault');
    assert.doesNotMatch(envProvidedResult.stderr, /ASC_KEY_P8/, 'the name is not reported as missing');

    // No token in the environment:  the reader would fail the way a rejected
    // token fails, so the absent token is named before the reader is asked.
    const noToken = { ...base, FLEET_SECRETS: working };
    delete noToken.INFISICAL_TOKEN;
    const noTokenResult = await runScript(script, { env: noToken, args: ['check-reader'] });
    assert.notEqual(noTokenResult.code, 0, 'a check without a token must fail');
    assert.match(noTokenResult.stderr, /no Infisical access token in the environment/, 'the message must name the absent token');
    assert.doesNotMatch(noTokenResult.stderr, /was rejected/, 'an absent token is not a rejected one');

    // No reader at all is a tooling fault, and it is named as one.
    const missingResult = await runScript(script, { env: base, args: ['check-reader'] });
    assert.notEqual(missingResult.code, 0, 'a missing reader must fail the check');
    assert.match(missingResult.stderr, /reader is not on PATH/, 'the message must name the reader');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/** A literal string for a regular expression.  The preview carries an ellipsis
 * and angle brackets, neither of which is a metacharacter, but the helper keeps
 * a future preview from changing the meaning of the pattern. */
function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

test('a credential is previewed only when the middle of it is really hidden', async () => {
  const script = fileURLToPath(new URL('install-release-secrets-tooling.sh', import.meta.url));

  // The two slices the preview is built from cover twelve characters between
  // them, so a value of twelve characters or fewer is reconstructed in full
  // by the two of them together.  Thirteen is the first length with a middle
  // left over, and it is the boundary the helper has to hold.  The hidden
  // middle of each case is a string that does not occur in the prose around
  // it, so a leak of it is a leak and not a coincidence.
  const cases = [
    { token: 'abcdefghij', preview: '<redacted>', hidden: 'abcdefghij' },
    { token: 'abcdefghijkl', preview: '<redacted>', hidden: 'abcdefghijkl' },
    { token: 'abcdefghZijkl', preview: 'abcdefgh…ijkl', hidden: 'Z' },
    { token: 'abcdefghijklmnopqrstuvwxyz0123', preview: 'abcdefgh…0123', hidden: 'ijklmnopqrstuvwxyz' }
  ];

  for (const { token, preview, hidden } of cases) {
    const dir = mkdtempSync(join(tmpdir(), 'asc-preview-'));
    try {
      const home = join(dir, 'home');
      mkdirSync(home, { recursive: true });
      const base = {
        ...process.env,
        HOME: home,
        PATH: '/usr/bin:/bin',
        INFISICAL_TOKEN: token,
        INFISICAL_FLEET_OPS_PROJECT_ID: '11111111-2222-3333-4444-555555555555'
      };

      // The reader repeats the token in its own error text, which is the text
      // the failure carries, so the token is in the log unless it is masked.
      const rejected = writeStubReader(dir, 4, `fleet-secrets: fetch-failed:  exit-1 for ${token}`);
      const result = await runScript(script, { env: { ...base, FLEET_SECRETS: rejected }, args: ['check-reader'] });

      assert.notEqual(result.code, 0, 'a reader that cannot authenticate must fail the check');
      assert.ok(!result.stderr.includes(token), `the access token must not reach the log (${token.length} characters)`);
      assert.ok(!result.stdout.includes(token), `the access token must not reach stdout (${token.length} characters)`);
      assert.match(result.stderr, new RegExp(`fetch-failed:  exit-1 for ${escapeRegExp(preview)}`), `the failure carries the preview of a ${token.length} character token`);
      assert.ok(!result.stderr.includes(hidden), `the hidden middle must stay hidden (${token.length} characters)`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

/** The shells the script has to be safe in.  The replacement in a bash
 * substitution expands an ampersand to the text that matched in bash 5.2 and
 * later, so that failure only appears in the newer shell; the test runs in
 * every bash it can find so both generations are covered. */
function shells() {
  const found = ['/bin/bash'];
  for (const candidate of ['/opt/homebrew/bin/bash', '/usr/local/bin/bash', '/opt/homebrew/bin/bash5']) {
    if (!existsSync(candidate)) continue;
    let version = '';
    try {
      version = spawnSync(candidate, ['--version']).stdout.toString();
    } catch {
      continue;
    }
    const match = version.match(/version (\d+)\.(\d+)/);
    if (!match) continue;
    const major = Number(match[1]);
    const minor = Number(match[2]);
    if (major > 5 || (major === 5 && minor >= 2)) found.push(candidate);
  }
  return found;
}

test('a credential that carries an ampersand is never expanded back into the log', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-amp-'));
  try {
    const script = fileURLToPath(new URL('install-release-secrets-tooling.sh', import.meta.url));
    const home = join(dir, 'home');
    mkdirSync(home, { recursive: true });

    // The replacement in a bash substitution is a pattern, and in bash 5.2
    // and later an ampersand in it expands to the text that matched, which
    // here would be the whole credential.  The ampersand sits in the first
    // eight characters, so it is in the part of the value a preview shows.
    const token = 'abc&efghijklmnopqrst';
    const base = {
      ...process.env,
      HOME: home,
      PATH: '/usr/bin:/bin',
      INFISICAL_TOKEN: token,
      INFISICAL_FLEET_OPS_PROJECT_ID: '11111111-2222-3333-4444-555555555555'
    };
    const rejected = writeStubReader(dir, 4, `fleet-secrets: fetch-failed:  exit-1 for ${token}`);

    for (const shell of shells()) {
      const result = await runScript(script, { env: { ...base, FLEET_SECRETS: rejected }, args: ['check-reader'], shell });
      assert.notEqual(result.code, 0, 'a reader that cannot authenticate must fail the check');
      assert.ok(!result.stderr.includes(token), `the access token must not reach the log (${shell})`);
      assert.ok(!result.stdout.includes(token), `the access token must not reach stdout (${shell})`);
      assert.ok(!result.stderr.includes('&'), `no ampersand may reach the log (${shell})`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the long lived client credentials are redacted whole', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-client-'));
  try {
    const script = fileURLToPath(new URL('install-release-secrets-tooling.sh', import.meta.url));
    const home = join(dir, 'home');
    mkdirSync(home, { recursive: true });

    // The client id and the client secret stand for months and the runner
    // masks them by value, so a preview of either would defeat that masking
    // and put twelve characters of a standing credential in a public log.
    const clientId = 'client-id-abcdefghijklmnop';
    const clientSecret = 'client-secret-abcdefghijklmnop';
    const base = {
      ...process.env,
      HOME: home,
      PATH: '/usr/bin:/bin',
      INFISICAL_CLIENT_ID: clientId,
      INFISICAL_CLIENT_SECRET: clientSecret,
      INFISICAL_TOKEN: 'abcdefghijklmnopqrstuvwxyz0123',
      INFISICAL_FLEET_OPS_PROJECT_ID: '11111111-2222-3333-4444-555555555555'
    };
    const rejected = writeStubReader(dir, 4, `fleet-secrets: fetch-failed:  exit-1 for ${clientId} and ${clientSecret}`);
    const result = await runScript(script, { env: { ...base, FLEET_SECRETS: rejected }, args: ['check-reader'] });

    assert.notEqual(result.code, 0, 'a reader that cannot authenticate must fail the check');
    assert.ok(!result.stderr.includes(clientId), 'the client id must not reach the log');
    assert.ok(!result.stderr.includes(clientSecret), 'the client secret must not reach the log');
    assert.ok(!result.stderr.includes('client-id-abc'), 'no slice of the client id may reach the log');
    assert.ok(!result.stderr.includes('client-sec'), 'no slice of the client secret may reach the log');
    assert.match(result.stderr, /for <redacted>/, 'the credentials are redacted whole');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a name the environment carries as whitespace is still required in the vault', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'asc-blank-'));
  try {
    const script = fileURLToPath(new URL('install-release-secrets-tooling.sh', import.meta.url));
    const home = join(dir, 'home');
    mkdirSync(home, { recursive: true });

    const base = {
      ...process.env,
      HOME: home,
      PATH: '/usr/bin:/bin',
      INFISICAL_TOKEN: 'abcdefghijklmnopqrstuvwxyz0123',
      INFISICAL_FLEET_OPS_PROJECT_ID: '11111111-2222-3333-4444-555555555555'
    };

    // The consumer trims a value and refuses one that holds nothing but
    // whitespace, so a name the environment carries in that shape is not
    // resolved from there and the vault still has to carry it.
    const reader = writeStubReader(dir, 0, '', ['ASC_ISSUER_ID', 'ASC_KEY_P8']);
    const result = await runScript(script, { env: { ...base, FLEET_SECRETS: reader, ASC_KEY_ID: '   ' }, args: ['check-reader'] });

    assert.notEqual(result.code, 0, 'a name the environment holds only whitespace is not resolved from there');
    assert.match(result.stderr, /but ASC_KEY_ID is not there/, 'the message must name the credential the vault has to carry');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
