// The staged App Store Connect key file:  how it is validated, and how it is
// read.
//
// The private key is a secret, and the approved secret sources are the
// process environment, a captured `fleet-secrets get NAME` and bootstrap-only
// Keychain credentials.  A caller-supplied file is not one of them, so the
// node client never reads a key file:  the shell layer that owns the
// credential reads the staged key and hands it over in the environment.  These
// tests cover that reader, because it is the one place a file is read.
//
// Everything here is synthetic:  the keys are generated at test time and are
// never committed, and nothing reaches the network.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { generateKeyPairSync } from "node:crypto";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

import { normalizePrivateKey, readPrivateKeyFile } from "./asc-key.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const helper = join(here, "asc-key.mjs");
const client = join(here, "asc-api.mjs");
const repoRoot = join(here, "..", "..");
const apnsScript = join(repoRoot, "scripts", "ios-enable-apns.mjs");
const profilesScript = join(repoRoot, "scripts", "ios-install-appstore-profiles.sh");
const root = mkdtempSync(join(tmpdir(), "asc-key-test-"));
//  A PATH with node and nothing else:  the fleet reader lives in the operator's
//  own bin directory, and a test must never reach it or Infisical.
const safePath = [dirname(process.execPath), "/usr/bin", "/bin"].join(":");

const keyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });

function staged(name, content = keyPem, mode = 0o600) {
  const path = join(root, name);
  writeFileSync(path, content);
  chmodSync(path, mode);
  return path;
}

function run(args, stdin = "") {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [helper, ...args], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(stdin);
  });
}

test("a generated key is accepted and comes back with a trailing newline", () => {
  const normalized = normalizePrivateKey(keyPem);
  assert.ok(normalized, "a real key was refused");
  assert.ok(normalized.endsWith("\n"), "the key has to end with a newline");
  assert.equal(normalized.trim(), keyPem.trim());
});

test("a malformed PEM is refused, because the envelope is not a key", () => {
  //  A truncated key, an armored block and a mangled export all carry the
  //  envelope and still fail to parse.  Accepting them would hand the signer
  //  something it cannot use, and the failure would come back as a stack
  //  trace instead of a credential error.
  assert.equal(normalizePrivateKey("-----BEGIN PRIVATE KEY-----\nnot base64 at all\n-----END PRIVATE KEY-----\n"), null); // gitleaks:allow
  assert.equal(normalizePrivateKey("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----\n"), null); // gitleaks:allow
  assert.equal(normalizePrivateKey(""), null);
  assert.equal(normalizePrivateKey(undefined), null);
  assert.equal(normalizePrivateKey("hunter2"), null);
});

test("a staged key file is read and its key is returned", () => {
  const path = staged("good.p8");
  const read = readPrivateKeyFile(path);
  assert.ok(read.pem, `the staged key was not read: ${read.error}`);
  assert.equal(read.pem.trim(), keyPem.trim());
});

test("a path that names nothing is reported apart from every other failure", () => {
  //  A path that names nothing is not a credential, so the caller falls
  //  through to the next source instead of aborting the run.
  const read = readPrivateKeyFile(join(root, "no-such-key.p8"));
  assert.equal(read.missing, true);
  assert.equal(read.error, undefined);
});

test("a symlink is refused rather than followed", () => {
  //  Every ordinary file read follows a symlink, so a path that looks like a
  //  key file could resolve to something else entirely.  The path is opened
  //  once with O_NOFOLLOW, so the symlink is never followed.
  const target = staged("target.p8");
  const link = join(root, "linked.p8");
  symlinkSync(target, link);
  const read = readPrivateKeyFile(link);
  assert.ok(read.error, "a symlinked key path was read");
  assert.match(read.error, /symbolic link/);
});

test("a key file other users can read is refused", () => {
  //  A private key another user can read is already leaked.
  const path = staged("loose.p8", keyPem, 0o644);
  const read = readPrivateKeyFile(path);
  assert.ok(read.error, "a key file readable by others was accepted");
  assert.match(read.error, /readable by others/);
});

test("a file that is not a private key is refused", () => {
  const path = staged("not-a-key.p8", "hunter2 this is not a private key\n");
  const read = readPrivateKeyFile(path);
  assert.ok(read.error, "a file that is not a key was accepted");
  assert.match(read.error, /does not hold a PEM private key/);
});

test("the command line reads a staged key and reports a missing one", async () => {
  const path = staged("cli.p8");
  const ok = await run(["read", path]);
  assert.equal(ok.code, 0);
  assert.equal(ok.stdout.trim(), keyPem.trim());

  const missing = await run(["read", join(root, "no-such-key.p8")]);
  assert.notEqual(missing.code, 0);
  assert.match(missing.stderr, /does not exist/);
  assert.equal(missing.stdout, "", "a missing key must not put anything on stdout");
});

test("the key never travels in the command arguments", async () => {
  //  The key goes in on stdin and comes out on stdout, so it is never an
  //  argument of any process.
  const path = staged("argv.p8");
  const result = await run(["validate"], keyPem);
  assert.equal(result.code, 0);
  assert.equal(result.stdout.trim(), keyPem.trim());
  assert.ok(!result.stderr.includes("PRIVATE KEY"), "the key envelope reached a log line");
});

test("the command line writes a key to a file only its owner can read", async () => {
  const path = join(root, "written.p8");
  const result = await run(["write", path], keyPem);
  assert.equal(result.code, 0, `the write failed: ${result.stderr}`);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.equal(readFileSync(path, "utf8").trim(), keyPem.trim());
});

test("the command line refuses a value that is not a key", async () => {
  const path = join(root, "refused.p8");
  const result = await run(["write", path], "not a private key");
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /not a PEM private key/);
});

test("the staged key reaches the client through the environment", async () => {
  //  This is the hosted CI path end to end:  the runner stages the key to a
  //  mode-600 file and publishes only its path, the shell layer reads that
  //  file, and the client takes the key from the environment.  The client
  //  reads no file at all, which is why the path is in the environment here
  //  and the file is still the credential in play.
  const path = staged("ci.p8");
  const read = await run(["read", path]);
  assert.equal(read.code, 0, `the staged key was not read: ${read.stderr}`);
  const client = spawn(process.execPath, [join(here, "asc-api.mjs"), "GET", "http://127.0.0.1:1/v1/apps"], {
    env: {
      ...process.env,
      ASC_API_BASE: "http://127.0.0.1:1",
      ASC_KEY_ID: "SYNTHETICKEYID1",
      ASC_ISSUER_ID: "synthetic-issuer",
      ASC_KEY_P8: read.stdout,
      ASC_KEY_PATH: path
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  let stderr = "";
  client.stderr.on("data", (d) => { stderr += d; });
  client.stdout.resume();
  await new Promise((resolve) => client.on("close", resolve));
  assert.match(stderr, /asc-auth: using ASC_KEY_P8 environment/, `the client did not take the key from the environment:\n${stderr}`);
  assert.doesNotMatch(stderr, /using ASC_KEY_PATH environment/);
});

// The consumers that call the client as a child process.
//
// The client has no path source (Kody rule 42), so a consumer that runs in the
// hosted runner, where the staged key is published as a path, has to read that
// key and hand it to the child in the child's environment.  These tests drive
// the two consumers that do that, and prove the key stays out of argv, out of
// the environment file, and out of every log line.

function localServer({ holdFirst = 0 } = {}) {
  const seen = [];
  let requests = 0;
  const server = createServer((req, res) => {
    seen.push({ url: req.url, authorization: req.headers.authorization || "" });
    requests += 1;
    //  The first request is held open, so the child process is still alive
    //  while the process table is read.
    const delay = requests === 1 ? holdFirst : 0;
    setTimeout(() => {
      res.writeHead(200, { "Content-Type": "application/json" });
      if (req.url.startsWith("/v1/bundleIds?")) {
        res.end(JSON.stringify({ data: [{ type: "bundleIds", id: "BUNDLE1",
          attributes: { identifier: "com.simplewithus.codecaps.ios" } }] }));
        return;
      }
      res.end(JSON.stringify({ data: [] }));
    }, delay);
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({
      base: `http://127.0.0.1:${server.address().port}`,
      seen,
      close: () => server.close()
    }));
  });
}

function spawnNode(args, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function spawnBash(args, env) {
  return new Promise((resolve) => {
    const child = spawn("bash", args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function jwtKeyId(authorization) {
  const token = String(authorization || "").replace(/^Bearer /, "");
  if (!token) return null;
  return JSON.parse(Buffer.from(token.split(".")[0], "base64url").toString()).kid;
}

test("the staged key is handed to the child in its environment", async () => {
  const { stagedKeyEnvironment } = await import(pathToFileURL(apnsScript).href);
  const path = staged("handoff.p8");
  const env = stagedKeyEnvironment({ ASC_KEY_PATH: path });
  assert.equal(env.ASC_KEY_P8.trim(), keyPem.trim(), "the staged key was not handed over");
  assert.equal(Object.keys(env).length, 1, "the child environment carries nothing but the key");
  //  No staged key means no override, so a developer who exports ASC_KEY_P8 in
  //  their own shell keeps working.
  assert.deepEqual(stagedKeyEnvironment({}), {});
  assert.deepEqual(stagedKeyEnvironment({ ASC_KEY_P8: "ambient" }), {});
  //  A path that names nothing is not a credential, so the run falls through
  //  and the client resolves the credential the way it does today.
  assert.deepEqual(stagedKeyEnvironment({ ASC_KEY_PATH: join(root, "no-such-key.p8") }), {});
});

test("the child client reports the ASC_KEY_P8 environment source", async () => {
  const { stagedKeyEnvironment } = await import(pathToFileURL(apnsScript).href);
  const server = await localServer();
  try {
    const result = await spawnNode([client, "GET", `${server.base}/v1/apps`], {
      PATH: safePath,
      HOME: join(root, "home-client"),
      ASC_API_BASE: server.base,
      ASC_KEY_ID: "SYNTHETICKEYID1",
      ASC_ISSUER_ID: "synthetic-issuer",
      ...stagedKeyEnvironment({ ASC_KEY_PATH: staged("client.p8") })
    });
    assert.match(result.stderr, /asc-auth: using ASC_KEY_P8 environment/,
      `the client did not report the environment source:\n${result.stderr}`);
    assert.equal(jwtKeyId(server.seen[0].authorization), "SYNTHETICKEYID1",
      "the request was not signed with the staged key");
  } finally {
    server.close();
  }
});

test("with no staged key and no ambient key the client reports that it has no credential", async () => {
  const result = await spawnNode([client, "GET", "http://127.0.0.1:1/v1/apps"], {
    //  A bare PATH and a throwaway HOME keep the fleet reader out of the way,
    //  so the client really has no source left.
    PATH: "/usr/bin:/bin",
    HOME: join(root, "home-empty"),
    ASC_API_BASE: "http://127.0.0.1:1",
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer"
  });
  assert.equal(result.code, 1, `expected the refusal exit, got ${result.code}: ${result.stderr}`);
  assert.match(result.stderr, /no App Store Connect credential found/);
});

test("the APNs consumer signs its requests with the staged key", async () => {
  const server = await localServer();
  try {
    const home = join(root, "home-apns");
    mkdirSync(home, { recursive: true });
    const result = await spawnNode([apnsScript], {
      PATH: safePath,
      HOME: home,
      ASC_API_BASE: server.base,
      ASC_KEY_ID: "SYNTHETICKEYID1",
      ASC_ISSUER_ID: "synthetic-issuer",
      ASC_KEY_PATH: staged("apns.p8"),
      ASC_KEY_P8: ""
    });
    assert.ok(server.seen.length > 0, "the consumer never reached App Store Connect");
    assert.equal(jwtKeyId(server.seen[0].authorization), "SYNTHETICKEYID1",
      "the request was not signed with the staged key");
    assert.doesNotMatch(result.stdout + result.stderr, /BEGIN PRIVATE KEY/,
      "the key reached the consumer's output");
  } finally {
    server.close();
  }
});

test("the key never reaches argv and never reaches the environment file", async () => {
  const needle = keyPem.split("\n").find((line) => line.length > 32);
  const envFile = join(root, "github-env");
  writeFileSync(envFile, "");
  const home = join(root, "home-argv");
  mkdirSync(home, { recursive: true });
  const server = await localServer({ holdFirst: 1500 });
  const env = {
    PATH: safePath,
    HOME: home,
    ASC_API_BASE: server.base,
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer",
    ASC_KEY_PATH: staged("argv.p8"),
    ASC_KEY_P8: "",
    GITHUB_ENV: envFile
  };
  const runs = [
    spawnNode([apnsScript], env),
    spawnBash([profilesScript], env)
  ];
  try {
    //  While the consumers are waiting on App Store Connect, no process may
    //  carry the key in its command line.
    await new Promise((resolve) => setTimeout(resolve, 700));
    const table = execFileSync("ps", ["-A", "-o", "args="], { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
    assert.ok(!table.includes(needle), "the key reached a command line");
    const results = await Promise.all(runs);
    //  Both consumers signed their requests with the staged key, so the
    //  handoff is what put the credential in front of the client.
    const signed = server.seen.filter((entry) => jwtKeyId(entry.authorization) === "SYNTHETICKEYID1");
    assert.ok(signed.length >= 2, `only ${signed.length} of the requests carried the staged key`);
    assert.ok(server.seen.some((entry) => entry.url.startsWith("/v1/profiles?")),
      "the profile consumer never reached App Store Connect");
    assert.ok(server.seen.some((entry) => entry.url.startsWith("/v1/bundleIds?")),
      "the APNs consumer never reached App Store Connect");
    for (const result of results) {
      assert.doesNotMatch(result.stdout + result.stderr, /BEGIN PRIVATE KEY/,
        "the key reached a consumer's output");
    }
    assert.ok(!readFileSync(envFile, "utf8").includes(needle), "the key reached the environment file");
  } finally {
    server.close();
  }
});
