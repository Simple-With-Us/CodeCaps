// The ASC key handoff must never leave the key in the environment or the log.
// This drives scripts/stage-asc-key.mjs with the real
// scripts/ios-stage-asc-key.sh, and checks the file it writes.
//
// The key is read from the vault by the script itself, so the test stubs the
// Infisical HTTP API rather than putting a key in the environment.  That is
// the point of the contract: a key in the environment is the leak this
// script exists to prevent.
//
// Run: node --test scripts/stage-asc-key.node-test.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { run } from './stage-asc-key.mjs';

const KEY = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC-MULTILINE-FIXTURE-DO-NOT-USE\n-----END PRIVATE KEY-----";
const VAULT = {
  ASC_KEY_ID: 'STUBKEYID',
  ASC_ISSUER_ID: 'STUBISSUER',
  ASC_KEY_P8: KEY,
};

/** A stub of the two Infisical endpoints the script calls. */
function vaultFetch(values = VAULT) {
  return async (url) => {
    if (url.includes('/auth/universal-auth/login')) {
      return { ok: true, status: 200, json: async () => ({ accessToken: 'stub-token' }) };
    }
    if (url.includes('/api/v3/secrets/raw')) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          secrets: Object.entries(values).map(([secretKey, secretValue]) => ({ secretKey, secretValue })),
        }),
      };
    }
    throw new Error(`the script fetched an unexpected url: ${url}`);
  };
}

function baseEnv(dir, overrides = {}) {
  // The staging script makes its own directory inside the staging root, so
  // the root has to exist first.
  mkdirSync(join(dir, "staging"), { recursive: true });
  return {
    GITHUB_ENV: join(dir, "env"),
    ASC_STAGING_ROOT: join(dir, "staging"),
    INFISICAL_PROJECT_ID: 'stub-project',
    INFISICAL_CLIENT_ID: 'stub-client',
    INFISICAL_CLIENT_SECRET: 'stub-secret',
    ...overrides,
  };
}

function mode(path) {
  return statSync(path).mode & 0o777;
}

test("the key is staged to a mode-600 file and only its path is published", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    const env = baseEnv(dir);
    const lines = [];
    await run({ env, fetchImpl: vaultFetch(), log: (l) => lines.push(l) });

    const written = readFileSync(env.GITHUB_ENV, "utf8");
    const match = written.match(/^ASC_KEY_PATH=(.*)$/m);
    assert.ok(match, "the staging script must publish ASC_KEY_PATH");
    const keyPath = match[1].trim();
    assert.ok(!written.includes("SYNTHETIC-MULTILINE-FIXTURE"), "the key must never reach GITHUB_ENV");
    assert.equal(mode(keyPath), 0o600, "the key file must be mode 600");
    assert.equal(mode(join(keyPath, "..")), 0o700, "the key directory must be mode 700");
    assert.ok(readFileSync(keyPath, "utf8").includes("SYNTHETIC-MULTILINE-FIXTURE"));

    // The key may appear in the log only as an add-mask command, which the
    // runner consumes to register the value for redaction.  Any other line
    // carrying the key would be a leak.
    const leaked = lines.filter((l) => l.includes("SYNTHETIC-MULTILINE-FIXTURE"));
    assert.ok(leaked.length > 0, "the key must be registered with the runner for redaction");
    for (const line of leaked) {
      assert.ok(line.startsWith("::add-mask::"),
        `the key may only appear in an add-mask command, not in ${JSON.stringify(line)}`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the key is never in the environment, not even as a leftover entry", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    const env = baseEnv(dir);
    await run({ env, fetchImpl: vaultFetch(), log: () => {} });
    const written = readFileSync(env.GITHUB_ENV, "utf8");
    assert.ok(!/ASC_KEY_P8/.test(written), "no ASC_KEY_P8 entry may reach GITHUB_ENV at all");
    // The identifiers do cross, because the ship and notarize steps need them.
    assert.match(written, /ASC_KEY_ID/);
    assert.match(written, /ASC_ISSUER_ID/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a key in the environment is ignored, the vault is the only source", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    const env = baseEnv(dir, { ASC_KEY_P8: "DECOY-FROM-THE-ENVIRONMENT" });
    await run({ env, fetchImpl: vaultFetch(), log: () => {} });
    const written = readFileSync(env.GITHUB_ENV, "utf8");
    assert.ok(!written.includes("DECOY-FROM-THE-ENVIRONMENT"), "the environment copy must never be used");
    const keyPath = written.match(/^ASC_KEY_PATH=(.*)$/m)[1].trim();
    const staged = readFileSync(keyPath, "utf8");
    assert.ok(staged.includes("SYNTHETIC-MULTILINE-FIXTURE"), "the vault copy is the one that is staged");
    assert.ok(!staged.includes("DECOY-FROM-THE-ENVIRONMENT"), "the environment copy must never be staged");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing key fails the step and names the secret and its path", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    const lines = [];
    await assert.rejects(
      run({ env: baseEnv(dir), fetchImpl: vaultFetch({ ASC_KEY_ID: 'x', ASC_ISSUER_ID: 'y' }), log: (l) => lines.push(l) }),
      (err) => {
        assert.match(err.message, /Missing ASC_KEY_P8 in Fleet-OPS prod \/asc/);
        return true;
      },
    );
    assert.ok(lines.some((l) => l.includes("Fleet-OPS prod /asc")), "the error names the path");
    assert.ok(lines.some((l) => l.includes("ASC_KEY_P8")), "the error names the secret");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing Infisical connection fails before anything is staged", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    await assert.rejects(
      run({ env: baseEnv(dir, { INFISICAL_CLIENT_SECRET: '' }), fetchImpl: vaultFetch(), log: () => {} }),
      (err) => {
        assert.match(err.message, /Missing the Infisical connection settings/);
        return true;
      },
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// CI only ever runs `node scripts/stage-asc-key.mjs`, so the CLI entry point
// -- the invokedDirectly guard and the process.env lookup -- is the path that
// ships.  The tests above import run(), which cannot reach it.  The CLI
// talks to a real HTTP endpoint, so this test stands up a stub vault.
//
// The stub server lives in this process, so the child must be spawned
// asynchronously: a synchronous spawn would block this process's event loop
// and the server could never answer the child's request.
test("the CLI entry point stages the key from the vault and publishes only the path", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-cli-"));
  const server = createServer((req, res) => {
    const body = req.url.includes('/auth/universal-auth/login')
      ? { accessToken: 'stub-token' }
      : { secrets: Object.entries(VAULT).map(([secretKey, secretValue]) => ({ secretKey, secretValue })) };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(body));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    const env = baseEnv(dir);
    const script = fileURLToPath(new URL("./stage-asc-key.mjs", import.meta.url));
    const result = await new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [script], {
        env: {
          ...process.env,
          ...env,
          INFISICAL_SITE_URL: `http://127.0.0.1:${port}`,
        },
      });
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });
      child.on('error', reject);
      child.on('close', (status) => resolve({ status, stdout, stderr }));
    });
    assert.equal(result.status, 0, `the CLI must succeed: ${result.stderr}`);

    const written = readFileSync(env.GITHUB_ENV, "utf8");
    const match = written.match(/^ASC_KEY_PATH=(.*)$/m);
    assert.ok(match, "the CLI must publish ASC_KEY_PATH");
    const keyPath = match[1].trim();
    assert.equal(mode(keyPath), 0o600, "the key file must be mode 600");
    assert.ok(readFileSync(keyPath, "utf8").includes("SYNTHETIC-MULTILINE-FIXTURE"));
    assert.ok(!written.includes("SYNTHETIC-MULTILINE-FIXTURE"), "the key must never reach GITHUB_ENV");
    assert.ok(!/ASC_KEY_P8/.test(written), "no ASC_KEY_P8 entry may reach GITHUB_ENV at all");

    for (const stream of ["stdout", "stderr"]) {
      const offending = String(result[stream] || "")
        .split("\n")
        .filter((l) => l.includes("SYNTHETIC-MULTILINE-FIXTURE"))
        .filter((l) => !l.startsWith("::add-mask::"));
      assert.deepEqual(offending, [], `the key must never reach ${stream}`);
    }
  } finally {
    server.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
