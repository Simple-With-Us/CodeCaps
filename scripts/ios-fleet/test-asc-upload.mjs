// asc-api.mjs upload-screenshots cleans up after itself and keeps quiet.
//
// A screenshot set holds ten entries, so a reservation that is left open by a
// failed upload is not cosmetic: it sits in the set forever and pushes the real
// screenshots out of it.  And the body of an App Store Connect error is
// whatever the service chose to say, so echoing it can put a header or a token
// into a shell history or a CI log.
//
// These tests run the real script against a local HTTP server with a synthetic
// key, so the failure paths are exercised without touching App Store Connect
// and without a real secret anywhere.  No network, no fleet-secrets.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { generateKeyPairSync } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "asc-api.mjs");
const root = mkdtempSync(join(tmpdir(), "asc-upload-test-"));

// A synthetic EC key: the script signs a JWT with it and the server here never
// verifies the signature.
//  A synthetic EC key.  The client takes it from the environment, because a
//  path on disk is not an approved secret source:  the shell layer that owns
//  the credential hands it over in ASC_KEY_P8.
const keyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });

// A stub PNG: the script only reads the IHDR width and height out of bytes
// 16..23 to decide which screenshot set the file belongs to, and never looks
// at the signature, so the rest of the file is not needed.
const pngPath = join(root, "shot.png");
const ihdr = Buffer.alloc(24);
ihdr.writeUInt32BE(1320, 16);
ihdr.writeUInt32BE(2868, 20);
writeFileSync(pngPath, ihdr);

// The same stub at one of Apple's Mac sizes, all of which are 16:10.
const macPath = join(root, "mac.png");
const macIhdr = Buffer.alloc(24);
macIhdr.writeUInt32BE(1440, 16);
macIhdr.writeUInt32BE(900, 20);
writeFileSync(macPath, macIhdr);

// A stub at the 13-inch iPad size and one at the 12.9-inch size.  Apple's
// table says the 13-inch display takes 2064 x 2752 and 2048 x 2732, and the
// 12.9-inch display takes only 2048 x 2732, so both iPad sizes land in the
// 13-inch set, the one the submit gate requires.
const ipad13Path = join(root, "ipad13.png");
const ipad13Ihdr = Buffer.alloc(24);
ipad13Ihdr.writeUInt32BE(2064, 16);
ipad13Ihdr.writeUInt32BE(2752, 20);
writeFileSync(ipad13Path, ipad13Ihdr);

const ipad129Path = join(root, "ipad129.png");
const ipad129Ihdr = Buffer.alloc(24);
ipad129Ihdr.writeUInt32BE(2048, 16);
ipad129Ihdr.writeUInt32BE(2732, 20);
writeFileSync(ipad129Path, ipad129Ihdr);

// A string the server puts in a body that the script must never echo.
const SECRET_MARKER = "leaked-token-marker-do-not-echo";

const SCREENSHOT_ID = "shot-abc-123";
const SET_ID = "set-xyz-789";

// Run asc-api.mjs upload-screenshots against a local server and collect what
// happened.  `behaviour` picks which step, if any, fails.
function upload(behaviour, file = pngPath, displayType = "auto") {
  return new Promise((resolve) => {
    const calls = [];
    const createdSets = [];
    // The pre-signed upload URL Apple hands out is absolute, so the port has to
    // be known before a reservation is written -- and the port is only known
    // once the server is listening.
    let apiBase = "";
    const server = createServer(async (req, res) => {
      const body = await new Promise((resolve2) => {
        let acc = "";
        req.on("data", (chunk) => { acc += chunk; });
        req.on("end", () => resolve2(acc));
      });
      calls.push({ method: req.method, url: req.url });

      const json = (status, payload) => {
        const text = JSON.stringify(payload);
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(text);
      };

      // The set already exists, so the run goes straight to the reservation.
      if (req.url.endsWith("/appScreenshotSets") && req.method === "GET") {
        return json(200, { data: [{
          id: SET_ID,
          type: "appScreenshotSets",
          attributes: { screenshotDisplayType: "APP_IPHONE_67" }
        }] });
      }
      if (req.url === "/v1/appScreenshotSets" && req.method === "POST") {
        //  A set for a display type the server does not have yet.
        let wanted;
        try {
          const parsed = JSON.parse(body || "{}");
          if (
            parsed === null ||
            typeof parsed !== "object" ||
            Array.isArray(parsed) ||
            parsed.data === null ||
            typeof parsed.data !== "object" ||
            Array.isArray(parsed.data) ||
            parsed.data.attributes === null ||
            typeof parsed.data.attributes !== "object" ||
            Array.isArray(parsed.data.attributes) ||
            typeof parsed.data.attributes.screenshotDisplayType !== "string" ||
            parsed.data.attributes.screenshotDisplayType.trim().length === 0
          ) {
            return json(400, { errors: [{ status: "400", code: "INVALID_REQUEST" }] });
          }
          wanted = parsed.data.attributes.screenshotDisplayType;
        } catch {
          return json(400, { errors: [{ status: "400", code: "INVALID_REQUEST" }] });
        }
        //  The response echoes `wanted`, so echoing it back cannot tell a
        //  correct size-to-display-type mapping from a wrong one.  Record what
        //  was actually asked for so a test can assert on it directly.
        createdSets.push(wanted);
        return json(201, { data: {
          id: `set-${wanted}`,
          type: "appScreenshotSets",
          attributes: { screenshotDisplayType: wanted }
        } });
      }
      if (req.url === "/v1/appScreenshots" && req.method === "POST") {
        return json(201, {
          data: {
            id: SCREENSHOT_ID,
            type: "appScreenshots",
            attributes: { uploadOperations: [{
              method: "PUT",
              url: `${apiBase}/upload-target`,
              length: 24,
              requestHeaders: [{ name: "Content-Type", value: "image/png" }]
            }] }
          }
        });
      }
      if (req.url === "/upload-target") {
        if (behaviour.putFails) {
          res.writeHead(500, { "Content-Type": "text/plain" });
          return res.end(`upstream said: ${SECRET_MARKER}`);
        }
        res.writeHead(200);
        return res.end();
      }
      if (req.url === `/v1/appScreenshots/${SCREENSHOT_ID}` && req.method === "PATCH") {
        if (behaviour.commitFails) {
          return json(409, { errors: [{
            status: "409",
            code: "STATE_ERROR",
            title: "The asset is not in a committable state.",
            detail: `internal reference ${SECRET_MARKER}`
          }] });
        }
        return json(200, { data: {
          id: SCREENSHOT_ID,
          type: "appScreenshots",
          attributes: { assetDeliveryState: { state: "COMPLETE", errors: [] } }
        } });
      }
      if (req.url === `/v1/appScreenshots/${SCREENSHOT_ID}` && req.method === "DELETE") {
        res.writeHead(204);
        return res.end();
      }
      res.writeHead(404, { "Content-Type": "text/plain" });
      return res.end(SECRET_MARKER);
    });

    server.listen(0, "127.0.0.1", () => {
      apiBase = `http://127.0.0.1:${server.address().port}`;
      const child = spawn("node", [script, "upload-screenshots", "loc-1", displayType, file], {
        env: {
          ...process.env,
          ASC_API_BASE: apiBase,
          ASC_KEY_ID: "SYNTHETICKEYID1",
          ASC_ISSUER_ID: "synthetic-issuer",
          ASC_KEY_P8: keyPem
        },
        stdio: ["ignore", "pipe", "pipe"]
      });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (d) => { stdout += d; });
      child.stderr.on("data", (d) => { stderr += d; });
      child.on("close", (code) => {
        server.close(() => resolve({ code, stdout, stderr, calls, createdSets }));
      });
    });
  });
}

const deletesFor = (calls) => calls
  .filter((c) => c.method === "DELETE" && c.url === `/v1/appScreenshots/${SCREENSHOT_ID}`)
  .length;

// The delete is only worth anything if the caller learns whether it landed, so
// the script has to wait for the response rather than fire the request and exit.
// A DELETE that is merely *sent* still shows up at the server, which makes the
// request count the wrong thing to assert on: the reported outcome is the part
// that distinguishes a cleaned-up reservation from a silent orphan.
const reportsDropped = (stderr) => stderr.includes(`dropped the reservation ${SCREENSHOT_ID}`);

test("a Mac screenshot goes to the desktop set", async () => {
  //  Apple's Mac sizes are all 16:10, and they belong to the desktop set.
  //  Without them in the map the upload would refuse a file it should
  //  accept.  The exit code alone cannot tell the desktop set from a wrong
  //  one, because the mock answers with whatever display type it was asked
  //  for, so the created set is asserted on directly.
  const { code, stderr, createdSets } = await upload({}, macPath);
  assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
  assert.deepEqual(
    createdSets, ["APP_DESKTOP"],
    `the Mac size was mapped to the wrong set: ${JSON.stringify(createdSets)}`
  );
});

test("the 13-inch iPad size goes to the 13-inch set", async () => {
  //  2064 x 2752 is the resolution of the iPad Pro of the 3rd generation and
  //  everything after it, the 13-inch M4 and M5 included, so it belongs to
  //  APP_IPAD_PRO_3GEN_129.  Putting it in APP_IPAD_PRO_129 is a spec
  //  mismatch, and App Store Connect answers SPEC_MISMATCH on every image
  //  in the set and leaves them all FAILED.
  const { code, stderr, createdSets } = await upload({}, ipad13Path);
  assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
  assert.deepEqual(
    createdSets, ["APP_IPAD_PRO_3GEN_129"],
    `the 13-inch iPad size was mapped to the wrong set: ${JSON.stringify(createdSets)}`
  );
});

test("the 12.9-inch iPad size goes to the required 13-inch set", async () => {
  //  2048 x 2732 is the only size the legacy 12.9-inch display accepts, and
  //  the 13-inch display accepts it as well.  The 13-inch set is the profile
  //  App Store Connect requires, and the capture falls back to 12.9-inch
  //  simulators when no 13-inch one is installed, so an automatic mapping
  //  that sent this size to the legacy set would leave the required set
  //  empty and the submission refused.  The legacy set stays reachable by
  //  naming APP_IPAD_PRO_129 explicitly instead of "auto".
  const { code, stderr, createdSets } = await upload({}, ipad129Path);
  assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
  assert.deepEqual(
    createdSets, ["APP_IPAD_PRO_3GEN_129"],
    `the 12.9-inch iPad size was mapped to the wrong set: ${JSON.stringify(createdSets)}`
  );
});

test("the legacy 12.9-inch set stays reachable by naming its display type", async () => {
  //  The auto map sends 2048 x 2732 to the required 13-inch set, and Apple
  //  accepts that size in both iPad sets, so an explicit APP_IPAD_PRO_129
  //  upload of the same size is valid - without it the legacy set could
  //  never be populated.
  const { code, stderr, createdSets } = await upload({}, ipad129Path, "APP_IPAD_PRO_129");
  assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
  assert.deepEqual(
    createdSets, ["APP_IPAD_PRO_129"],
    `the explicit legacy display type was not honored: ${JSON.stringify(createdSets)}`
  );
});

test("an unknown display type is refused before anything is sent", async () => {
  //  This guard is the only thing keeping an arbitrary string out of the
  //  screenshotDisplayType Apple is asked to create.
  const { code, stderr, calls, createdSets } = await upload({}, pngPath, "APP_IPAD_PRO_129_TYPO");
  assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
  assert.ok(
    /is not a display type this script knows/.test(stderr),
    `the refusal did not name the unknown display type:\n${stderr}`
  );
  assert.deepEqual(calls, [], "the script talked to App Store Connect with an unknown display type");
  assert.deepEqual(createdSets, [], "a screenshot set was created for an unknown display type");
});

test("an inherited member name is refused like any unknown display type", async () => {
  //  "constructor" resolves through Object.prototype on a plain table, so
  //  an inherited lookup would pass the guard and crash with a TypeError
  //  and exit code 1 instead of refusing with exit code 2.
  const { code, stderr, createdSets } = await upload({}, pngPath, "constructor");
  assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
  assert.ok(
    /is not a display type this script knows/.test(stderr),
    `the refusal did not name the inherited member:\n${stderr}`
  );
  assert.deepEqual(createdSets, [], "a screenshot set was created for an inherited member name");
});

test("an explicit display type refuses a size it does not accept", async () => {
  //  A 2064 x 2752 capture can never go in the legacy 12.9-inch set:
  //  Apple calls that a spec mismatch and fails every image in the set.
  const { code, stderr } = await upload({}, ipad13Path, "APP_IPAD_PRO_129");
  assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
  assert.ok(
    /APP_IPAD_PRO_129 does not accept/.test(stderr),
    `the refusal did not name the display type and the size:\n${stderr}`
  );
});

test("a successful upload commits the reservation and leaves nothing open", async () => {
  const { code, stderr, calls } = await upload({ putFails: false, commitFails: false });
  assert.equal(code, 0, `expected a clean exit, got ${code}: ${stderr}`);
  assert.ok(
    calls.some((c) => c.method === "PATCH" && c.url === `/v1/appScreenshots/${SCREENSHOT_ID}`),
    "the commit call was never made"
  );
  assert.equal(deletesFor(calls), 0, "a committed reservation must not be deleted");
});

test("a failed upload drops the reservation instead of leaving it in the set", async () => {
  const { code, stderr, calls } = await upload({ putFails: true, commitFails: false });
  assert.equal(code, 2, "a failed upload has to exit non-zero");
  assert.equal(
    deletesFor(calls), 1,
    "the open reservation was never dropped, so it would sit in the ten-entry set forever"
  );
  assert.ok(
    reportsDropped(stderr),
    `the script exited without reporting that the reservation went away:\n${stderr}`
  );
});

test("a failed commit drops the reservation", async () => {
  const { code, stderr, calls } = await upload({ putFails: false, commitFails: true });
  assert.equal(code, 2, "a failed commit has to exit non-zero");
  assert.equal(deletesFor(calls), 1, "the uncommitted reservation was never dropped");
  assert.ok(
    reportsDropped(stderr),
    `the script exited without reporting that the reservation went away:\n${stderr}`
  );
});

test("no response body is echoed, on any failure", async () => {
  for (const behaviour of [
    { putFails: true, commitFails: false },
    { putFails: false, commitFails: true }
  ]) {
    const { stdout, stderr } = await upload(behaviour);
    const printed = stdout + stderr;
    assert.ok(
      !printed.includes(SECRET_MARKER),
      `the raw response body was echoed to the caller:\n${printed}`
    );
  }
});

test("a rejected key is named, never previewed", async () => {
  // The server answers 401 to everything; the script must not echo the body,
  // and it must not print any part of a key either.
  const base = await new Promise((resolve) => {
    const server = createServer((req, res) => {
      res.writeHead(401, { "Content-Type": "text/plain" });
      res.end(`unauthorized: ${SECRET_MARKER}`);
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
  const apiBase = `http://127.0.0.1:${base.address().port}`;
  const result = await new Promise((resolve) => {
    const child = spawn("node", [script, "upload-screenshots", "loc-1", "auto", pngPath], {
      env: {
        ...process.env,
        ASC_API_BASE: apiBase,
        ASC_KEY_ID: "SYNTHETICKEYID1",
        ASC_ISSUER_ID: "synthetic-issuer",
        ASC_KEY_P8: keyPem
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
  base.close();
  assert.equal(result.code, 2, "a rejected key has to exit non-zero");
  assert.ok(!result.stderr.includes(SECRET_MARKER), "the 401 body was echoed");
  assert.ok(
    /ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_P8/.test(result.stderr),
    `the failure should name the variables to check, got: ${result.stderr}`
  );
});