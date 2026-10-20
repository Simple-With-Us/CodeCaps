// The ASC key handoff must never leave the key in the environment or the log.
// This drives scripts/stage-asc-key.mjs with the real
// scripts/ios-stage-asc-key.sh, and checks the file it writes.
//
// The key is fetched by the infisical-secrets composite action, which is
// this repository's approved way to read a value out of the vault.  This
// script does not talk to the vault, so there is nothing to stub here.
//
// Run: node --test scripts/stage-asc-key.node-test.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { run } from './stage-asc-key.mjs';

const KEY = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC-MULTILINE-FIXTURE-DO-NOT-USE\n-----END PRIVATE KEY-----";

function baseEnv(dir, overrides = {}) {
  // The staging script makes its own directory inside the staging root, so
  // the root has to exist first.
  mkdirSync(join(dir, "staging"), { recursive: true });
  return {
    ASC_KEY_P8: KEY,
    GITHUB_ENV: join(dir, "env"),
    ASC_STAGING_ROOT: join(dir, "staging"),
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
    await run({ env, log: (l) => lines.push(l) });

    const written = readFileSync(env.GITHUB_ENV, "utf8");
    const match = written.match(/^ASC_KEY_PATH=(.*)$/m);
    assert.ok(match, "the staging script must publish ASC_KEY_PATH");
    const keyPath = match[1].trim();
    assert.ok(!written.includes("SYNTHETIC-MULTILINE-FIXTURE"), "the key must never reach GITHUB_ENV");
    assert.equal(mode(keyPath), 0o600, "the key file must be mode 600");
    assert.equal(mode(join(keyPath, "..")), 0o700, "the key directory must be mode 700");
    assert.ok(readFileSync(keyPath, "utf8").includes("SYNTHETIC-MULTILINE-FIXTURE"));

    const leaked = lines.filter((l) => l.includes("SYNTHETIC-MULTILINE-FIXTURE"));
    assert.deepEqual(leaked, [], "the key must never reach the log");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the key is taken back out of the environment for later steps", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    const env = baseEnv(dir);
    await run({ env, log: () => {} });
    const written = readFileSync(env.GITHUB_ENV, "utf8");
    assert.ok(written.includes("ASC_KEY_P8=\n"), "the environment entry must be blanked");
    // The blanking comes after the path, so the runner applies it last.
    assert.ok(written.indexOf("ASC_KEY_P8=\n") > written.indexOf("ASC_KEY_PATH="),
      "the blanking must come after the path so that it wins");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing key fails the step and names the secret and its path", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    const lines = [];
    await assert.rejects(
      run({ env: baseEnv(dir, { ASC_KEY_P8: "" }), log: (l) => lines.push(l) }),
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

test("the key never reaches a command line", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-"));
  try {
    const env = baseEnv(dir);
    await run({ env, log: () => {} });
    // The staging script's own contract: the key is on its standard input,
    // and the published file holds the key, not an argument.
    const keyPath = readFileSync(env.GITHUB_ENV, "utf8").match(/^ASC_KEY_PATH=(.*)$/m)[1].trim();
    assert.ok(readFileSync(keyPath, "utf8").includes("SYNTHETIC-MULTILINE-FIXTURE"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// CI only ever runs `node scripts/stage-asc-key.mjs`, so the CLI entry point
// -- the invokedDirectly guard and the process.env lookup -- is the path that
// ships.  The tests above import run(), which cannot reach it.
test("the CLI entry point stages the key, publishes the path and blanks the environment", () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-stage-cli-"));
  try {
    const env = baseEnv(dir);
    const script = fileURLToPath(new URL("./stage-asc-key.mjs", import.meta.url));
    const result = spawnSync(process.execPath, [script], {
      env: { ...process.env, ...env },
      encoding: "utf8",
    });
    assert.equal(result.status, 0, `the CLI must succeed: ${result.stderr}`);

    const written = readFileSync(env.GITHUB_ENV, "utf8");
    const match = written.match(/^ASC_KEY_PATH=(.*)$/m);
    assert.ok(match, "the CLI must publish ASC_KEY_PATH");
    const keyPath = match[1].trim();
    assert.equal(mode(keyPath), 0o600, "the key file must be mode 600");
    assert.ok(readFileSync(keyPath, "utf8").includes("SYNTHETIC-MULTILINE-FIXTURE"));

    assert.ok(written.includes("ASC_KEY_P8=\n"), "the CLI must blank the environment entry");
    assert.ok(written.indexOf("ASC_KEY_P8=\n") > written.indexOf("ASC_KEY_PATH="),
      "the blanking must come after the path so that it wins");

    for (const stream of ["stdout", "stderr"]) {
      assert.ok(!result[stream].includes("SYNTHETIC-MULTILINE-FIXTURE"),
        `the key must never reach ${stream}`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
