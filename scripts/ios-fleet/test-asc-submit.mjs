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

// A server that answers the endpoints the command walks, with whatever
// number of screenshots the test wants to claim the version carries.
function serve(screenshots, marketing) {
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
        return json(200, { data: [
          { id: "set-1", attributes: { screenshotDisplayType: "APP_IPHONE_67", screenshotCount: 3 } },
          { id: "set-2", attributes: { screenshotDisplayType: "APP_IPAD_PRO_129", screenshotCount: screenshots - 3 } }
        ] });
      }
      if (url === `/v1/appStoreVersions/${VERSION_ID}/build`) {
        return json(200, { data: { type: "builds", id: "build-1", attributes: { version: "241" } } });
      }
      if (url === `/v1/builds/build-1`) {
        return json(200, {
          data: {
            type: "builds",
            id: "build-1",
            attributes: { version: "241" },
            relationships: { preReleaseVersion: { data: { type: "preReleaseVersions", id: "pre-1" } } }
          },
          included: [{ type: "preReleaseVersions", id: "pre-1", attributes: { versionString: marketing } }]
        });
      }
      if (url === `/v1/appStoreVersions/${VERSION_ID}`) {
        return json(200, { data: {
          type: "appStoreVersions",
          id: VERSION_ID,
          attributes: { versionString: "1.0.241", appStoreState: "PREPARE_FOR_SUBMISSION" },
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
      return json(404, { errors: [{ title: "not found" }] });
    });
  });
  return { server, patched };
}

function submit(base) {
  return new Promise((resolve) => {
    const child = spawn("node", [script, "submit-review", VERSION_ID], {
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

async function withServer(screenshots, fn, marketing = "1.0.241") {
  const { server, patched } = serve(screenshots, marketing);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn(base, patched);
  } finally {
    server.close();
  }
}

test("a version with no screenshots is not submitted", async () => {
  await withServer(0, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /needs at least six screenshots/.test(stderr),
      `the refusal did not say what was missing:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched even though the version was not ready");
  });
});

test("a version whose version string does not match the build is not submitted", async () => {
  //  App Store Connect pairs a build with a version by their marketing
  //  version, so a version still carrying the previous build's string is
  //  refused.  The command has to say which value is right.
  await withServer(6, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /the version says 1\.0\.241 and the build says 1\.0\.240/.test(stderr),
      `the refusal did not name both versions:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched even though the version did not match");
  }, "1.0.240");
});

test("a version that is ready is submitted", async () => {
  await withServer(6, async (base, patched) => {
    const { code, stdout, stderr } = await submit(base);
    assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
    const report = JSON.parse(stdout.trim().split("\n").pop());
    assert.equal(report.ok, true, `the submission did not report success:\n${stdout}`);
    assert.equal(report.reviewSubmission, SUBMISSION_ID);
    assert.equal(patched.length, 1, "the submission was not patched");
    const attributes = patched[0].body?.data?.attributes;
    assert.equal(attributes?.submitted, true, "the submission was not marked submitted");
    assert.equal(attributes?.platform, "IOS", "the platform was not set");
  });
});
