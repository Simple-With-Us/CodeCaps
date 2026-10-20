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
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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

test("a call that never answers is reported as a timeout", async () => {
  //  The server accepts the connection and then says nothing, so the call
  //  has to be aborted.  A timeout and a transport failure have different
  //  causes:  one means App Store Connect was slow, the other that the
  //  request never got there, and the operator needs the one that is true.
  const sockets = [];
  const server = createServer((req, res) => {
    //  Never answer.
  });
  server.on("connection", (socket) => sockets.push(socket));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let result;
  try {
    result = await run(["latest-build-seq", "com.example.nothing", "1.0"], {
      ASC_API_BASE: base,
      ASC_REQUEST_TIMEOUT_MS: "400"
    });
  } finally {
    for (const socket of sockets) socket.destroy();
    server.close();
  }
  assert.equal(result.code, 2, `expected a failed lookup, got ${result.code}: ${result.stderr}`);
  assert.ok(
    /timed out/.test(result.stderr),
    `a timeout was not reported as one:\n${result.stderr}`
  );
  assert.ok(
    !/never reached App Store Connect/.test(result.stderr),
    `a timeout was reported as a transport failure:\n${result.stderr}`
  );
});

test("a rejected key is reported as a rejected key, not as a missing app", async () => {
  //  The credential is what failed, so saying the bundle id is unknown sends
  //  the operator after the wrong thing entirely.
  const server = createServer((req, res) => {
    res.writeHead(401, { "Content-Type": "text/plain" });
    res.end("unauthorized");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let result;
  try {
    result = await run(["latest-build-seq", "com.example.nothing", "1.0"], { ASC_API_BASE: base });
  } finally {
    server.close();
  }
  assert.equal(result.code, 2, `expected a failed lookup, got ${result.code}: ${result.stderr}`);
  assert.ok(
    /rejected the key/.test(result.stderr),
    `a rejected key was not named:\n${result.stderr}`
  );
  assert.ok(
    !/app not found/.test(result.stderr),
    `a rejected key was reported as a missing app:\n${result.stderr}`
  );
  //  The fleet's masked preview, so the key in play can be identified without
  //  any of it being published.  It is taken from the key material rather
  //  than from the PEM envelope:  the envelope is the same for every key, so
  //  a preview of it names none of them.
  const pem = readFileSync(keyPath, "utf8");
  const material = pem.replace(/-----[^-]+-----/g, "").trim();
  const expectedPreview = `${material.slice(0, 8)}…${material.slice(-4)}`;
  assert.ok(
    result.stderr.includes(expectedPreview),
    `the failure did not carry the masked key preview ${expectedPreview}:\n${result.stderr}`
  );
  //  A preview with a newline in it splits the diagnostic into two lines, and
  //  ship-testflight.sh forwards only the lines starting with "latest-build-seq:",
  //  so the second half — which is where the HTTP status is — is lost.
  const diagnostic = result.stderr.split("\n").find((line) => line.startsWith("latest-build-seq:"));
  assert.ok(diagnostic, `no forwarded diagnostic line:\n${result.stderr}`);
  assert.ok(
    /HTTP 401/.test(diagnostic),
    `the HTTP status was split off the forwarded line:\n${result.stderr}`
  );
  //  The key id is public:  it travels in every request to App Store
  //  Connect, and it is the part that says which credential was refused.
  assert.ok(
    result.stderr.includes("SYNTHETICKEYID1"),
    `the failure did not name the key id:\n${result.stderr}`
  );
});

test("two different keys do not get the same masked preview", async () => {
  //  The preview exists to say which credential was rejected.  Recomputing it
  //  from the same file in the test above cannot catch a preview that is
  //  identical for every key, so the two keys have to be compared with each
  //  other.
  const otherKeyPath = join(root, "other-synthetic.p8");
  writeFileSync(otherKeyPath, generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
    .export({ type: "pkcs8", format: "pem" }));

  const server = createServer((req, res) => {
    res.writeHead(401, { "Content-Type": "text/plain" });
    res.end("unauthorized");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const previews = [];
  try {
    for (const path of [keyPath, otherKeyPath]) {
      const result = await run(["latest-build-seq", "com.example.nothing", "1.0"], {
        ASC_API_BASE: base,
        ASC_KEY_PATH: path
      });
      const diagnostic = result.stderr.split("\n").find((line) => line.startsWith("latest-build-seq:"));
      const preview = diagnostic && diagnostic.match(/key in play (\S+)/);
      assert.ok(preview, `no key preview in the diagnostic:\n${result.stderr}`);
      previews.push(preview[1]);
    }
  } finally {
    server.close();
  }
  assert.notEqual(
    previews[0],
    previews[1],
    "two different keys produced the same masked preview, so it identifies neither"
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