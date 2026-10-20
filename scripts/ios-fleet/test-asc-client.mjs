// The App Store Connect client reports its own failures correctly.
//
// Two things go wrong easily here and both send the operator in the wrong
// direction.  A host override that is not the production host has to be
// refused without a stack trace, because the stack trace names a module scope
// rather than the thing the operator has to change.  And a request that never
// reached App Store Connect is not a verdict about the app, so it must not be
// reported as "app not found".
//
// These tests run the real client against a local server, or against a closed
// port, with a synthetic key.  No network, no fleet-secrets, no real secret.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { generateKeyPairSync } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "asc-api.mjs");
const root = mkdtempSync(join(tmpdir(), "asc-client-test-"));

const keyPath = join(root, "synthetic.p8");
writeFileSync(keyPath, generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" }));

const PROD = "https://api.appstoreconnect.apple.com";

function run(args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn("node", [script, ...args], {
      env: {
        ...process.env,
        ASC_KEY_ID: "SYNTHETICKEYID1",
        ASC_ISSUER_ID: "synthetic-issuer",
        ASC_KEY_PATH: keyPath,
        ...env
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

test("the production host is accepted when it is pinned explicitly", async () => {
  //  No arguments, so the run stops at the usage message and never touches
  //  the network.  What matters is that the host was accepted at all: the
  //  refusal would exit 2 with a different message.
  const { code, stderr } = await run([], { ASC_API_BASE: PROD });
  assert.equal(code, 1, `expected the usage exit, got ${code}: ${stderr}`);
  assert.ok(
    !/loopback/.test(stderr),
    `pinning the production host was refused:\n${stderr}`
  );
  assert.ok(/Usage: node asc-api.mjs/.test(stderr), "the usage message was not printed");
});

test("a host that is neither the production host nor loopback is refused by name", async () => {
  const { code, stderr } = await run([], { ASC_API_BASE: "https://not-the-real-host.example.com" });
  assert.equal(code, 2, `expected a named refusal, got ${code}: ${stderr}`);
  assert.ok(
    /must be the production host or a loopback address/.test(stderr),
    `the refusal did not say what to change:\n${stderr}`
  );
  assert.ok(
    !/at Object\.|at Module\.|at file:/.test(stderr),
    `the refusal came with a stack trace:\n${stderr}`
  );
});

test("a trailing slash on the override does not double the path separator", async () => {
  const paths = [];
  const server = createServer((req, res) => {
    paths.push(req.url);
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("no");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}/`;
  try {
    await run(["GET", "/v1/apps"], { ASC_API_BASE: base });
  } finally {
    server.close();
  }
  assert.ok(paths.length > 0, "the server never received a request");
  for (const path of paths) {
    assert.ok(
      !path.includes("//"),
      `the request path has a doubled separator: ${path}`
    );
  }
});

test("a request that never reached App Store Connect is not reported as app not found", async () => {
  //  Port 1 on loopback has nothing listening, so the connection is refused
  //  and the request never leaves the machine.
  const { code, stderr } = await run(
    ["latest-build-seq", "com.example.nothing", "1.0"],
    { ASC_API_BASE: "http://127.0.0.1:1" }
  );
  assert.equal(code, 2, `expected a failed lookup, got ${code}: ${stderr}`);
  assert.ok(
    /never reached App Store Connect/.test(stderr),
    `a transport failure was reported as a verdict about the app:\n${stderr}`
  );
  assert.ok(
    !/app not found/.test(stderr),
    `a transport failure was reported as "app not found":\n${stderr}`
  );
});

test("the message that explains a failure is not lost on the way out", async () => {
  //  stderr is a pipe here, and a pending write to a pipe is not flushed by
  //  process.exit(), so the diagnostic could be dropped entirely.
  const { code, stderr } = await run([], { ASC_API_BASE: "https://not-the-real-host.example.com" });
  assert.equal(code, 2);
  assert.ok(
    stderr.trim().length > 0,
    "the failure left no message behind: the exit discarded the write"
  );
});

test("a large payload is not truncated on the way out", async () => {
  //  The failure body is deliberately bigger than a pipe buffer, so a write
  //  that is still queued when the process ends is visibly cut short.  This
  //  is the shape of the bug: the caller gets half an answer and no idea that
  //  anything is missing.
  const body = "x".repeat(1024 * 1024);
  const server = createServer((req, res) => {
    res.writeHead(500, { "Content-Type": "text/plain" });
    res.end(body);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let result;
  try {
    result = await run(["GET", "/v1/apps"], { ASC_API_BASE: base });
  } finally {
    server.close();
  }
  assert.equal(result.code, 2, "the failed call has to exit non-zero");
  assert.ok(
    result.stdout.length >= body.length,
    `the payload was cut short: ${result.stdout.length} of ${body.length} bytes arrived`
  );
});