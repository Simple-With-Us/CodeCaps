// The ASC key handoff must never put the key in the environment or the log.
// This drives scripts/infisical-fetch-asc-key.mjs with a stubbed Infisical
// and the real scripts/ios-stage-asc-key.sh, and checks the file it writes.
//
// Run: node --test scripts/infisical-fetch-asc-key.node-test.mjs
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { run } from './infisical-fetch-asc-key.mjs';

const KEY = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC-MULTILINE-FIXTURE-DO-NOT-USE\n-----END PRIVATE KEY-----";

/** Stub Infisical: the login succeeds and the list returns the fixture. */
function stubFetch(vaultSecrets, calls = []) {
  return async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, headers: init.headers || {} });
    if (u.includes("/api/v1/auth/universal-auth/login")) {
      return { ok: true, json: async () => ({ accessToken: "test-token", expiresIn: 3600 }) };
    }
    if (u.includes("/api/v3/secrets/raw")) {
      return {
        ok: true,
        json: async () => ({
          secrets: Object.entries(vaultSecrets).map(([secretKey, secretValue]) => ({ secretKey, secretValue })),
        }),
      };
    }
    throw new Error(`stubFetch: unexpected URL ${u}`);
  };
}

function baseEnv(dir, overrides = {}) {
  // The staging script makes its own directory inside the staging root, so
  // the root has to exist first.
  mkdirSync(join(dir, "staging"), { recursive: true });
  return {
    INFISICAL_PROJECT_ID: "synthetic-fleet-project",
    INFISICAL_ENVIRONMENT: "prod",
    INFISICAL_SECRET_PATH: "/asc",
    INFISICAL_CLIENT_ID: "synthetic-client",
    INFISICAL_CLIENT_SECRET: "synthetic-secret",
    GITHUB_ENV: join(dir, "env"),
    ASC_STAGING_ROOT: join(dir, "staging"),
    ...overrides,
  };
}

function mode(path) {
  return statSync(path).mode & 0o777;
}

test("the key is staged to a mode-600 file and only its path is published", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-fetch-"));
  try {
    const env = baseEnv(dir);
    const lines = [];
    await run({ env, fetchImpl: stubFetch({ ASC_KEY_P8: KEY }), log: (l) => lines.push(l) });

    const written = readFileSync(env.GITHUB_ENV, "utf8");
    const match = written.match(/^ASC_KEY_PATH=(.*)$/m);
    assert.ok(match, "the staging script must publish ASC_KEY_PATH");
    const keyPath = match[1].trim();
    assert.ok(!written.includes("SYNTHETIC-MULTILINE-FIXTURE"), "the key must never reach GITHUB_ENV");
    assert.equal(mode(keyPath), 0o600, "the key file must be mode 600");
    assert.equal(mode(join(keyPath, "..")), 0o700, "the key directory must be mode 700");
    assert.ok(readFileSync(keyPath, "utf8").includes("SYNTHETIC-MULTILINE-FIXTURE"));

    // The only place the key may appear in the log is on an ::add-mask::
    // line, which is the runner's own instruction to scrub it.  Anywhere
    // else and it is a leak.
    const leaked = lines.filter((l) => l.includes("SYNTHETIC-MULTILINE-FIXTURE") && !l.startsWith("::add-mask::"));
    assert.deepEqual(leaked, [], "the key must never reach the log outside an ::add-mask:: line");
    assert.ok(lines.some((l) => l.startsWith("::add-mask::")), "every line of the key must be masked");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the key is read from prod /asc of the given project, and nowhere else", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-fetch-"));
  try {
    const calls = [];
    await run({ env: baseEnv(dir), fetchImpl: stubFetch({ ASC_KEY_P8: KEY }, calls), log: () => {} });
    const list = calls.filter((c) => c.url.includes("/api/v3/secrets/raw"));
    assert.equal(list.length, 1, "one list call for the whole path");
    const url = new URL(list[0].url);
    assert.equal(url.searchParams.get("workspaceId"), "synthetic-fleet-project");
    assert.equal(url.searchParams.get("environment"), "prod");
    assert.equal(url.searchParams.get("secretPath"), "/asc");
    // The login helper returns the token string itself, so a destructured
    // read would silently send "Bearer undefined".
    assert.equal(list[0].headers.authorization, "Bearer test-token");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing key fails the step and names Fleet-OPS prod /asc, never a value", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-fetch-"));
  try {
    const lines = [];
    await assert.rejects(
      run({ env: baseEnv(dir), fetchImpl: stubFetch({}), log: (l) => lines.push(l) }),
      (err) => {
        assert.match(err.message, /ASC_KEY_P8/);
        assert.match(err.message, /Fleet-OPS prod \/asc/);
        return true;
      },
    );
    assert.ok(lines.some((l) => l.includes("Fleet-OPS prod /asc")), "the error names the path");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing project id fails before any network call", async () => {
  const dir = mkdtempSync(join(tmpdir(), "asc-fetch-"));
  try {
    const calls = [];
    await assert.rejects(
      run({ env: baseEnv(dir, { INFISICAL_PROJECT_ID: "" }), fetchImpl: stubFetch({ ASC_KEY_P8: KEY }, calls), log: () => {} }),
      /INFISICAL_PROJECT_ID is required/,
    );
    assert.equal(calls.length, 0, "nothing may be fetched without a project id");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
