// The submit-review command refuses to submit a version that is not ready.
//
// Submitting is the one call in this client that cannot be undone, so the
// things that have to be true first are checked rather than discovered from
// Apple's refusal.  These tests drive the real command against a local
// server:  no network, no fleet-secrets, no real secret.
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
const root = mkdtempSync(join(tmpdir(), "asc-submit-test-"));

const keyPath = join(root, "synthetic.p8");
writeFileSync(keyPath, generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" }));

const VERSION_ID = "version-1";
const APP_ID = "app-1";
const SUBMISSION_ID = "sub-1";

// A server that answers the endpoints the command walks.
//
// `options` says what the server should report:
//   iphoneScreens / ipadScreens: the count in each display type's set
//   setsFail: the screenshot-set read answers 401
//   boundTo: the version the review submission is bound to
//   platform: the platform the submission answers with
function serve(options) {
  const patched = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => { raw += chunk; });
    req.on("end", () => {
      const json = (status, payload) => {
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(JSON.stringify(payload));
      };
      const url = req.url.split("?")[0];

      if (req.method === "PATCH" && url.startsWith("/v1/reviewSubmissions/")) {
        patched.push({ url, body: JSON.parse(raw || "{}") });
        return json(200, {
          data: {
            type: "reviewSubmissions",
            id: SUBMISSION_ID,
            attributes: { state: "WAITING_FOR_REVIEW", submittedDate: "2026-10-20T00:00:00Z" }
          }
        });
      }
      if (url === `/v1/appStoreVersions/${VERSION_ID}/appStoreVersionLocalizations`) {
        return json(200, { data: [{ type: "appStoreVersionLocalizations", id: "loc-1" }] });
      }
      if (url === "/v1/appStoreVersionLocalizations/loc-1/appScreenshotSets") {
        if (options.setsFail) {
          return json(401, { errors: [{ title: "unauthorized" }] });
        }
        return json(200, { data: [
          {
            id: "set-1",
            attributes: { screenshotDisplayType: "APP_IPHONE_67", screenshotCount: options.iphoneScreens }
          },
          {
            id: "set-2",
            attributes: { screenshotDisplayType: "APP_IPAD_PRO_129", screenshotCount: options.ipadScreens }
          }
        ] });
      }
      if (url === `/v1/appStoreVersions/${VERSION_ID}/build`) {
        return json(200, { data: { type: "builds", id: "build-1", attributes: { version: "243" } } });
      }
      if (url === `/v1/builds/build-1`) {
        return json(200, {
          data: {
            type: "builds",
            id: "build-1",
            attributes: { version: "243" },
            relationships: { preReleaseVersion: { data: { type: "preReleaseVersions", id: "pre-1" } } }
          },
          included: [{ type: "preReleaseVersions", id: "pre-1", attributes: { versionString: "1.0.243" } }]
        });
      }
      if (url === `/v1/appStoreVersions/${VERSION_ID}`) {
        return json(200, { data: {
          type: "appStoreVersions",
          id: VERSION_ID,
          attributes: { versionString: options.versionString || "1.0.243", appStoreState: "PREPARE_FOR_SUBMISSION" },
          relationships: { app: { data: { type: "apps", id: APP_ID } } }
        } });
      }
      if (url === `/v1/apps/${APP_ID}/reviewSubmissions`) {
        return json(200, { data: [{
          id: SUBMISSION_ID,
          type: "reviewSubmissions",
          attributes: { platform: "IOS", state: "READY_FOR_REVIEW", submittedDate: null }
        }] });
      }
      if (url === `/v1/reviewSubmissions/${SUBMISSION_ID}/items`) {
        return json(200, { data: [{ type: "appStoreVersions", id: options.boundTo }] });
      }
      if (req.method === "GET" && url === `/v1/reviewSubmissions/${SUBMISSION_ID}`) {
        //  The read back after the submit, so the report can say what the
        //  submission's state actually is.
        return json(200, {
          data: {
            type: "reviewSubmissions",
            id: SUBMISSION_ID,
            attributes: { state: "WAITING_FOR_REVIEW", submittedDate: "2026-10-20T00:00:00Z" }
          }
        });
      }
      return json(404, { errors: [{ title: "not found" }] });
    });
  });
  return { server, patched };
}

function submit(base, args = []) {
  return new Promise((resolve) => {
    const child = spawn("node", [script, "submit-review", VERSION_ID, ...args], {
      env: {
        ...process.env,
        ASC_API_BASE: base,
        ASC_KEY_ID: "SYNTHETICKEYID1",
        ASC_ISSUER_ID: "synthetic-issuer",
        ASC_KEY_PATH: keyPath
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

async function withServer(options, fn) {
  const { server, patched } = serve(options);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn(base, patched);
  } finally {
    server.close();
  }
}

const READY = { iphoneScreens: 3, ipadScreens: 3, boundTo: VERSION_ID };

test("a version with no screenshots is not submitted", async () => {
  await withServer({ ...READY, iphoneScreens: 0, ipadScreens: 0 }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /no screenshot for iphone and ipad/.test(stderr),
      `the refusal did not say what was missing:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched even though the version was not ready");
  });
});

test("an empty iPad set does not pass on the iPhone images alone", async () => {
  //  The counts are pooled across display types, so three iPhone images and
  //  an empty iPad set would pass a total of six and still be refused by
  //  App Store Connect.
  await withServer({ ...READY, ipadScreens: 0 }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /no screenshot for ipad/.test(stderr),
      `the refusal did not name the missing family:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched without an iPad screenshot");
  });
});

test("a screenshot set that could not be read stops the submission", async () => {
  //  A read that failed is not an absent set:  treating it as absent would
  //  let an irreversible submission go out on a read that never happened.
  await withServer({ ...READY, setsFail: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /rejected the key/.test(stderr),
      `the failed read was not reported as one:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched after a failed read");
  });
});

test("a review submission bound to another version is not submitted", async () => {
  await withServer({ ...READY, boundTo: "some-other-version" }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /is not bound to version-1/.test(stderr),
      `the refusal did not say the submission was bound elsewhere:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the wrong version's submission was patched");
  });
});

test("a version whose version string does not match the build is not submitted", async () => {
  //  The version still carries the previous build's version string, so App
  //  Store Connect would refuse to pair it with the new build.
  await withServer({ ...READY, versionString: "1.0.240" }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /the version says 1\.0\.240 and the build says 1\.0\.243/.test(stderr),
      `the refusal did not name both versions:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched even though the version did not match");
  });
});

test("a ready version is submitted, and only the report is on stdout", async () => {
  await withServer(READY, async (base, patched) => {
    const { code, stdout, stderr } = await submit(base);
    assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
    //  A wrapper parses stdout as JSON, so the report has to be the only
    //  thing there.
    const report = JSON.parse(stdout.trim());
    assert.equal(report.ok, true, `the submission did not report success:\n${stdout}`);
    assert.equal(report.reviewSubmission, SUBMISSION_ID);
    assert.equal(report.platform, "IOS");
    assert.equal(patched.length, 1, "the submission was not patched");
    const attributes = patched[0].body?.data?.attributes;
    assert.equal(attributes?.submitted, true, "the submission was not marked submitted");
    assert.equal(attributes?.platform, "IOS", "the platform was not set");
  });
});

test("the platform can be chosen, and a bad one is refused", async () => {
  await withServer(READY, async (base, patched) => {
    const { code, stdout } = await submit(base, [SUBMISSION_ID, "MAC_OS"]);
    assert.equal(code, 0, "the macOS platform was not accepted");
    const report = JSON.parse(stdout.trim());
    assert.equal(report.platform, "MAC_OS");
    assert.equal(patched[0].body?.data?.attributes?.platform, "MAC_OS");
  });
  await withServer(READY, async (base) => {
    const { code, stderr } = await submit(base, [SUBMISSION_ID, "WINDOWS"]);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(/not a review platform/.test(stderr), `the refusal did not say what was wrong:\n${stderr}`);
  });
});
