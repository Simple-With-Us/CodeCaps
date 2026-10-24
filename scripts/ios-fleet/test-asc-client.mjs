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
import { chmodSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
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
const keyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });
writeFileSync(keyPath, keyPem);
//  The staged key that ios-stage-asc-key.sh publishes is mode 600, and the
//  shell layer refuses a key file other users can read.
chmodSync(keyPath, 0o600);

const PROD = "https://api.appstoreconnect.apple.com";

function run(args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn("node", [script, ...args], {
      env: {
        ...process.env,
        ASC_KEY_ID: "SYNTHETICKEYID1",
        ASC_ISSUER_ID: "synthetic-issuer",
        //  The client takes the key from the environment:  a path on disk is
        //  not an approved secret source (Kody rule 42), so the shell layer
        //  hands the key over in ASC_KEY_P8.
        ASC_KEY_P8: keyPem,
        //  The credential sources are cleared so an ambient ASC_KEY_PATH or
        //  APPLE_API_* on the machine running the suite cannot decide which
        //  credential a test gets.
        ASC_KEY_PATH: "",
        APPLE_API_KEY_ID: "",
        APPLE_API_ISSUER_ID: "",
        APPLE_API_KEY_P8_BASE64: "",
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
  const pem = keyPem;
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
  const otherKeyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
    .export({ type: "pkcs8", format: "pem" });
  const otherKeyPath = join(root, "other-synthetic.p8");
  writeFileSync(otherKeyPath, otherKeyPem);
  chmodSync(otherKeyPath, 0o600);

  const server = createServer((req, res) => {
    res.writeHead(401, { "Content-Type": "text/plain" });
    res.end("unauthorized");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const previews = [];
  try {
    for (const pem of [keyPem, otherKeyPem]) {
      const result = await run(["latest-build-seq", "com.example.nothing", "1.0"], {
        ASC_API_BASE: base,
        ASC_KEY_P8: pem
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

test("a named key file is not a credential source", async () => {
  //  A path on disk is not an approved secret source, so the client never
  //  reads one:  the shell layer that owns the credential reads the staged
  //  key and hands it over in the environment.  The file below holds a real
  //  private key, so a client that still read paths would sign the request
  //  with it and name the file as the credential in play.
  const server = createServer((req, res) => {
    res.writeHead(401, { "Content-Type": "text/plain" });
    res.end("unauthorized");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let result;
  try {
    result = await run(["GET", "/v1/apps"], {
      ASC_API_BASE: base,
      ASC_KEY_PATH: keyPath
    });
  } finally {
    server.close();
  }
  assert.match(
    result.stderr,
    /asc-auth: using ASC_KEY_P8 environment/,
    `the environment was not the credential in play:\n${result.stderr}`
  );
  assert.doesNotMatch(result.stderr, /using ASC_KEY_PATH environment/);
});

test("a path that names the wrong file is not read, and its content stays out of the log", async () => {
  //  The path names a real file.  A client that read paths would treat it as
  //  key material and print a masked preview of it when App Store Connect
  //  refused the credential, so the file's content must never reach a log
  //  line and the request has to be signed with the environment credential.
  const notAKey = join(root, "not-a-key.txt");
  writeFileSync(notAKey, "hunter2 this is not a private key\n");
  chmodSync(notAKey, 0o600);
  let requests = 0;
  const server = createServer((req, res) => {
    requests += 1;
    res.writeHead(401, { "Content-Type": "text/plain" });
    res.end("unauthorized");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let result;
  try {
    result = await run(["GET", "/v1/apps"], { ASC_API_BASE: base, ASC_KEY_PATH: notAKey });
  } finally {
    server.close();
  }
  assert.match(result.stderr, /asc-auth: using ASC_KEY_P8 environment/);
  assert.doesNotMatch(result.stderr, /hunter2/, "the named file's content reached the log");
  assert.equal(requests, 1, "the request has to be signed with the environment credential");
});

test("a malformed PEM in the environment is a credential error, not a stack trace", async () => {
  //  An envelope is not a key:  a truncated key, an armored block or a
  //  mangled export carries the envelope and still fails to parse.  The
  //  refusal has to name the credential, because the signer would fail with a
  //  stack trace that says nothing about what to change.
  const malformed = "-----BEGIN PRIVATE KEY-----\nnot base64 at all\n-----END PRIVATE KEY-----\n"; // gitleaks:allow
  const result = await run(["GET", "/v1/apps"], { ASC_KEY_P8: malformed });
  assert.equal(result.code, 1, `expected the refusal exit, got ${result.code}: ${result.stderr}`);
  assert.match(result.stderr, /ASC_KEY_P8 is set but is not a PEM private key/);
  assert.ok(
    !/at Object\.|at Module\.|at file:/.test(result.stderr),
    `the refusal came with a stack trace:\n${result.stderr}`
  );
});

//  The two refusals below belong to the staged key file, which the shell
//  layer reads, not to the client.  They are covered in test-asc-key.test.mjs:
//  a file other users can read is refused, and a symlink is not followed.

test("a symlinked key path is never followed", async () => {
  //  A symlink is followed by every ordinary file read, so it would let a
  //  path that looks like a key file resolve to something else entirely.  The
  //  client reads no path at all, and the staged key reader that does read
  //  files refuses a symlink as well (test-asc-key.test.mjs).
  const link = join(root, "linked.p8");
  symlinkSync(keyPath, link);
  const result = await run(["GET", "/v1/apps"], { ASC_KEY_PATH: link });
  assert.match(result.stderr, /asc-auth: using ASC_KEY_P8 environment/);
  assert.doesNotMatch(result.stderr, /is not a regular file/);
});
//  A stub that answers the app lookup and then pages builds with whatever
//  next link `nextFor(page)` returns, so the build-floor loops can be driven.
async function buildFloorAgainst(nextFor) {
  let page = 0;
  const server = createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    if (req.url.startsWith("/v1/apps")) {
      res.end(JSON.stringify({ data: [{ id: "1", type: "apps", attributes: { bundleId: "com.example.app" } }] }));
      return;
    }
    page += 1;
    res.end(JSON.stringify({ data: [], links: { next: nextFor(page, base) } }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return { ...(await run(["build-floor", "com.example.app", "1.0.237"], { ASC_API_BASE: base })), pages: page };
  } finally {
    server.close();
  }
}

test("build-floor never follows a next link to another host", async () => {
  const result = await buildFloorAgainst(() => "https://not-the-real-host.example.com/v1/builds?cursor=x");
  assert.equal(result.code, 2, `expected a failed lookup, got ${result.code}: ${result.stderr}`);
  assert.ok(/next link leaves App Store Connect/.test(result.stderr), `the off-host link was not refused:\n${result.stderr}`);
  assert.equal(result.pages, 1, "only the first page on the stub was read");
});

test("build-floor fails instead of answering from a list cut off at 10 pages", async () => {
  const result = await buildFloorAgainst((page, base) => `${base}/v1/builds?cursor=${page}`);
  assert.equal(result.code, 2, `expected a failed lookup, got ${result.code}: ${result.stderr}`);
  assert.ok(/more than 10 pages of train builds/.test(result.stderr), `the cut-off list was not refused:\n${result.stderr}`);
  assert.equal(result.stdout.trim(), "", "no floor is printed for a cut-off list");
});
