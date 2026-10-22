// The submit-review command refuses to submit a version that is not ready.
//
// Submitting is the one call in this client that cannot be undone, so the
// things that have to be true first are checked rather than discovered from
// Apple's refusal.  These tests drive the real command against a local
// server:  no network, no fleet-secrets, no real secret.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { generateKeyPairSync } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "asc-api.mjs");
const root = mkdtempSync(join(tmpdir(), "asc-submit-test-"));

//  A synthetic EC key.  The client takes it from the environment, because a
//  path on disk is not an approved secret source:  the shell layer that owns
//  the credential hands it over in ASC_KEY_P8.
const keyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });

const VERSION_ID = "version-1";
const APP_ID = "app-1";
const SUBMISSION_ID = "sub-1";

// A server that answers the endpoints the command walks.
//
// `options` says what the server should report:
//   iphoneScreens / ipadScreens: the count in each display type's set.
//     ipadScreens is the 13-inch set, APP_IPAD_PRO_3GEN_129, which is the
//     profile App Store Connect requires.
//   ipad129Screens: the count in the 12.9-inch set, APP_IPAD_PRO_129.  The
//     set is only served when this is given, so a server that does not name
//     it is a version that carries no 12.9-inch screenshot at all.
//   desktopScreens: the count in the macOS display type's set; the set is
//     only served when this is given, so a server that does not name it is a
//     version that carries no desktop screenshot at all
//   setsFail: the screenshot-set read answers 401
//   preReleaseFails: the build read answers 401
//   preReleaseMissing: the build read names no pre-release version, so the
//     document carries no `included` member
//   boundTo: the version the review submission's item names;  left out, the
//     submission has no items at all, which is the state a fresh account is
//     in and the one the command has to bind
//   bindFails: the binding call answers 409 and names the blockers
//   bindAuthFailsOnce: the first binding call answers 401, the way a rejected
//     credential does, and the calls after it succeed
//   submitFails: the submit answers 409 and names the blockers
//   noSubmissions: the app has no review submission at all
//   secondSubmission: the app has a second draft submission, so a run that
//     does not stop at a rejected credential has somewhere to go
//   submissionHasNoPlatform: the draft submission carries no platform at all
//   submissionPlatform: the platform the named submission answers with
//   platformPatchFails: the platform change is refused, which happens after
//     the version was already bound
//   platformPatchIgnored: the platform change is accepted but the read still
//     answers with the platform the submission started with, so the change
//     did not take
//   platformReadBackMissing: the read of a draft answers with no platform at
//     all
//   createHidesPlatform: the created submission comes back with no platform
//   bindFailsPlain: the binding is refused and names no blockers
//   itemsFail: the read of the submission's items fails
//   platform: the platform the submission answers with
function serve(options) {
  const patched = [];
  const bound = [];
  const created = [];
  //  The order the writes came in, so a test can see which one came first.
  const order = [];
  //  The platform each submission carries.  A platform that was set on it is
  //  remembered, so the read after the change answers with it.
  const platforms = new Map();
  //  The platform a read of a submission answers with.  A server that
  //  ignores a platform patch keeps answering with the platform the
  //  submission started with, and a server that has no platform at all
  //  answers with none:  both are states the client's read-back guard has to
  //  catch, so the mock can play them.
  const platformOf = (id) => {
    if (options.platformReadBackMissing) return null;
    if (options.platformPatchIgnored) return options.submissionPlatform || "IOS";
    return platforms.get(id) || options.submissionPlatform || "IOS";
  };
  //  A submission that has been marked submitted reads back as one, and a
  //  draft reads back as a draft.  The read before the submit and the read
  //  after it are the same call, so what changed in between is what tells
  //  them apart.
  const sent = new Set();
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => { raw += chunk; });
    req.on("end", () => {
      const json = (status, payload) => {
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(JSON.stringify(payload));
      };
      const url = req.url.split("?")[0];

      //  How many screenshots each display type's set holds.  A set carries
      //  no count of its own:  App Store Connect does not expose one, so the
      //  count is read from the screenshots the set holds.
      const shotCounts = {
        "set-1": options.iphoneScreens,
        "set-2": options.ipadScreens
      };
      if (options.ipad129Screens !== undefined) shotCounts["set-4"] = options.ipad129Screens;
      if (options.desktopScreens !== undefined) shotCounts["set-3"] = options.desktopScreens;

      if (req.method === "PATCH" && url.startsWith("/v1/reviewSubmissions/")) {
        //  The body is untrusted input, so it is parsed in a try block and
        //  validated before anything is stored.  The shape is checked by
        //  hand, because the script has no dependencies to lean on.
        let parsed = null;
        try {
          parsed = raw ? JSON.parse(raw) : null;
        } catch {
          return json(400, { errors: [{ title: "the body is not JSON" }] });
        }
        const isPlain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
        if (!isPlain(parsed) || !isPlain(parsed.data) || !isPlain(parsed.data.attributes)) {
          return json(400, { errors: [{ title: "the body does not name a submission with attributes" }] });
        }
        const id = parsed.data.id;
        if (typeof id !== "string" || id.length === 0) {
          return json(400, { errors: [{ title: "the body does not name a submission" }] });
        }
        const attributes = parsed.data.attributes;
        if (attributes.submitted !== undefined && typeof attributes.submitted !== "boolean") {
          return json(400, { errors: [{ title: "submitted is not a boolean" }] });
        }
        if (attributes.platform !== undefined &&
            (typeof attributes.platform !== "string" || attributes.platform.length === 0)) {
          return json(400, { errors: [{ title: "platform is not a platform" }] });
        }
        //  Only the normalized values are kept:  the id, the submitted flag
        //  and the platform, and nothing else the request carried.
        const submitted = attributes.submitted === true;
        const platform = typeof attributes.platform === "string" ? attributes.platform : null;
        patched.push({
          url,
          body: {
            data: {
              type: "reviewSubmissions",
              id,
              attributes: { ...(submitted ? { submitted: true } : {}), ...(platform ? { platform } : {}) }
            }
          }
        });
        order.push(submitted ? "submit" : "platform");
        if (submitted) {
          sent.add(id);
        }
        if (platform !== null) {
          platforms.set(id, platform);
        }
        if (!submitted && platform !== null && options.platformPatchFails) {
          //  The refusal of the platform change.
          return json(409, { errors: [{
            status: "409",
            code: "STATE_ERROR.ENTITY_STATE_INVALID",
            title: "the platform could not be set on the review submission."
          }] });
        }
        if (submitted && (options.submitFails || options.submitFailsPlain)) {
          if (options.submitFailsPlain) {
            //  A refusal that names no blockers at all.
            return json(409, { errors: [{
              status: "409",
              code: "STATE_ERROR.ENTITY_STATE_INVALID",
              title: "appStoreVersions with id 'version-1' is not in valid state."
            }] });
          }
          //  The refusal the live service answers with when the version is
          //  not ready:  the blockers are named, one entry per resource.
          return json(409, { errors: [{
            status: "409",
            code: "STATE_ERROR.ENTITY_STATE_INVALID",
            title: "appStoreVersions with id 'version-1' is not in valid state.",
            detail: "This resource cannot be reviewed, please check associated errors to see why.",
            meta: {
              associatedErrors: {
                "/v1/appStoreVersionLocalizations/loc-1/placements": [{
                  status: "409",
                  code: "STATE_ERROR.SCREENSHOT_REQUIRED.IPAD_13_PROFILE",
                  title: "App screenshot missing (IPAD_13_PROFILE).",
                  detail: "A screenshot for one of the following types is required but was not provided: IPAD_13_PROFILE"
                }],
                "/v1/appDataUsages/": [{
                  status: "409",
                  code: "STATE_ERROR.APP_DATA_USAGES_REQUIRED",
                  title: "Answers to what data your app collects and how it's used are needed.",
                  detail: "You must have published answers to your app's data usages."
                }]
              }
            }
          }] });
        }
        const patchedPlatform = platformOf(id);
        const patchedAttributes = {
          state: submitted ? "WAITING_FOR_REVIEW" : "READY_FOR_REVIEW",
          submittedDate: submitted ? "2026-10-20T00:00:00Z" : null
        };
        if (patchedPlatform !== null) patchedAttributes.platform = patchedPlatform;
        return json(200, {
          data: {
            type: "reviewSubmissions",
            id,
            attributes: patchedAttributes
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
        //  A set carries NO count of its own:  App Store Connect does not
        //  expose one, so the count is read from the screenshots the set
        //  holds.  The mock used to invent a screenshotCount attribute, and
        //  the invented field is exactly what made the production read come
        //  back empty.
        const sets = [
          { id: "set-1", attributes: { screenshotDisplayType: "APP_IPHONE_67" } },
          { id: "set-2", attributes: { screenshotDisplayType: "APP_IPAD_PRO_3GEN_129" } }
        ];
        if (options.ipad129Screens !== undefined) {
          sets.push({ id: "set-4", attributes: { screenshotDisplayType: "APP_IPAD_PRO_129" } });
        }
        if (options.desktopScreens !== undefined) {
          sets.push({ id: "set-3", attributes: { screenshotDisplayType: "APP_DESKTOP" } });
        }
        return json(200, { data: sets });
      }
      const shots = url.match(/^\/v1\/appScreenshotSets\/([^/]+)\/appScreenshots$/);
      if (shots) {
        if (options.shotsFail) {
          return json(401, { errors: [{ title: "unauthorized" }] });
        }
        const count = shotCounts[shots[1]] === undefined ? 0 : shotCounts[shots[1]];
        return json(200, {
          data: Array.from({ length: count }, (_unused, i) => ({
            type: "appScreenshots",
            id: `shot-${shots[1]}-${i}`,
            attributes: { fileSize: 1000 }
          }))
        });
      }
      if (url === `/v1/appStoreVersions/${VERSION_ID}/build`) {
        return json(200, { data: { type: "builds", id: "build-1", attributes: { version: "243" } } });
      }
      if (url === `/v1/builds/build-1`) {
        if (options.preReleaseFails) {
          return json(401, { errors: [{ title: "unauthorized" }] });
        }
        if (options.preReleaseMissing) {
          //  A build that names no pre-release version, so the document
          //  carries no `included` member at all.
          return json(200, {
            data: { type: "builds", id: "build-1", attributes: { version: "243" } }
          });
        }
        if (options.preReleaseWithoutVersion) {
          //  The include is there, but it carries no version string, so the
          //  comparison still cannot be made.
          return json(200, {
            data: {
              type: "builds",
              id: "build-1",
              attributes: { version: "243" },
              relationships: { preReleaseVersion: { data: { type: "preReleaseVersions", id: "pre-1" } } }
            },
            included: [{ type: "preReleaseVersions", id: "pre-1", attributes: {} }]
          });
        }
        if (options.preReleaseWithoutInclude) {
          //  The build names a pre-release version, but the read returns no
          //  include for it, so the marketing version cannot be read.
          return json(200, {
            data: {
              type: "builds",
              id: "build-1",
              attributes: { version: "243" },
              relationships: { preReleaseVersion: { data: { type: "preReleaseVersions", id: "pre-1" } } }
            }
          });
        }
        return json(200, {
          data: {
            type: "builds",
            id: "build-1",
            attributes: { version: "243" },
            relationships: { preReleaseVersion: { data: { type: "preReleaseVersions", id: "pre-1" } } }
          },
          //  The pre-release version carries `version`, and the live API
          //  answers with no `versionString` on that resource at all.  A
          //  `versionString` here would be a different field, and the
          //  command must not read it:  `versionString` belongs to an
          //  appStoreVersion.
          included: [{
            type: "preReleaseVersions",
            id: "pre-1",
            attributes: { version: "1.0.243", versionString: "9.9.9", platform: "IOS" }
          }]
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
        if (options.noSubmissions) {
          return json(200, { data: [] });
        }
        const draft = (id) => {
          const attributes = { state: "READY_FOR_REVIEW", submittedDate: null };
          //  A service that answers a draft with no platform at all:  the
          //  client has to set the platform and read it back.
          if (!options.submissionHasNoPlatform && !options.platformReadBackMissing) {
            attributes.platform = options.submissionPlatform || "IOS";
          }
          return { id, type: "reviewSubmissions", attributes };
        };
        const data = [draft(SUBMISSION_ID)];
        if (options.secondSubmission) {
          data.push(draft("sub-2"));
        }
        return json(200, { data });
      }
      if (req.method === "POST" && url === "/v1/reviewSubmissions") {
        //  The body is untrusted input, so it is parsed in a try block and
        //  validated before anything is stored.  A body that is not JSON, or
        //  that names no platform and no app, is refused with a 400 instead
        //  of throwing out of the handler.
        let parsed = null;
        try {
          parsed = raw ? JSON.parse(raw) : null;
        } catch {
          return json(400, { errors: [{ title: "the body is not JSON" }] });
        }
        const data = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed.data : null;
        const attributes = data && typeof data === "object" && !Array.isArray(data) ? data.attributes : null;
        const platform = attributes && typeof attributes === "object" && !Array.isArray(attributes)
          ? attributes.platform
          : null;
        const appId = data?.relationships?.app?.data?.id;
        if (typeof platform !== "string" || platform.length === 0 ||
            typeof appId !== "string" || appId.length === 0) {
          return json(400, { errors: [{ title: "the body does not name a platform and an app" }] });
        }
        //  Only the validated object is stored.
        created.push({
          data: {
            type: "reviewSubmissions",
            attributes: { platform },
            relationships: { app: { data: { type: "apps", id: appId } } }
          }
        });
        //  The created submission carries the platform it was made with.
        platforms.set("sub-new", platform);
        const createdAttributes = { state: "READY_FOR_REVIEW", submittedDate: null };
        //  A create response that does not echo the platform is a response
        //  the client cannot take the platform from.
        if (!options.createHidesPlatform) createdAttributes.platform = platform;
        return json(201, { data: {
          type: "reviewSubmissions",
          id: "sub-new",
          attributes: createdAttributes
        } });
      }
      if (req.method === "POST" && url === "/v1/reviewSubmissionItems") {
        //  The body is untrusted input, so it is parsed in a try block and
        //  validated before anything is stored.  A body that is not JSON, or
        //  that does not name a review submission and a version, is refused
        //  with a 400 instead of throwing out of the handler.
        let parsed = null;
        try {
          parsed = raw ? JSON.parse(raw) : null;
        } catch {
          return json(400, { errors: [{ title: "the body is not JSON" }] });
        }
        const data = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed.data : null;
        const relationships = data && typeof data === "object" && !Array.isArray(data) ? data.relationships : null;
        const submissionId = relationships?.reviewSubmission?.data?.id;
        const versionId = relationships?.appStoreVersion?.data?.id;
        if (typeof submissionId !== "string" || submissionId.length === 0 ||
            typeof versionId !== "string" || versionId.length === 0) {
          return json(400, { errors: [{ title: "the body does not name a review submission and a version" }] });
        }
        //  Only the validated object is stored.
        bound.push({
          data: {
            type: "reviewSubmissionItems",
            relationships: {
              reviewSubmission: { data: { type: "reviewSubmissions", id: submissionId } },
              appStoreVersion: { data: { type: "appStoreVersions", id: versionId } }
            }
          }
        });
        order.push("bind");
        if (options.bindAuthFailsOnce && bound.length === 1) {
          //  The refusal a rejected credential gets.  The calls after this
          //  one include the submit, which cannot be undone.
          return json(401, { errors: [{
            status: "401",
            code: "NOT_AUTHORIZED",
            title: "Authentication credentials are missing or invalid."
          }] });
        }
        if (options.bindFailsPlain) {
          //  A refusal that names no blockers at all.
          return json(409, { errors: [{
            status: "409",
            code: "STATE_ERROR.ENTITY_STATE_INVALID",
            title: "appStoreVersions with id 'version-1' is not in valid state."
          }] });
        }
        if (options.bindFails) {
          //  The refusal the live service answers with when the version is
          //  not ready:  the blockers are named, one entry per resource.
          return json(409, { errors: [{
            status: "409",
            code: "STATE_ERROR.ENTITY_STATE_INVALID",
            title: "appStoreVersions with id 'version-1' is not in valid state.",
            detail: "This resource cannot be reviewed, please check associated errors to see why.",
            meta: {
              associatedErrors: {
                "/v1/appStoreVersionLocalizations/loc-1/placements": [{
                  status: "409",
                  code: "STATE_ERROR.SCREENSHOT_REQUIRED.IPAD_13_PROFILE",
                  title: "App screenshot missing (IPAD_13_PROFILE).",
                  detail: "A screenshot for one of the following types is required but was not provided: IPAD_13_PROFILE"
                }],
                "/v1/appDataUsages/": [{
                  status: "409",
                  code: "STATE_ERROR.APP_DATA_USAGES_REQUIRED",
                  title: "Answers to what data your app collects and how it's used are needed.",
                  detail: "You must have published answers to your app's data usages."
                }]
              }
            }
          }] });
        }
        return json(201, { data: { type: "reviewSubmissionItems", id: "item-1" } });
      }
      if (req.method === "GET" && /^\/v1\/reviewSubmissions\/[^/]+\/items$/.test(url)) {
        if (options.itemsFail) {
          //  A read that fails:  the run never gets as far as a submit.
          return json(500, { errors: [{
            status: "500",
            code: "INTERNAL_ERROR",
            title: "the items could not be read."
          }] });
        }
        if (options.boundTo === undefined) {
          //  A submission with no items:  the version is bound to nothing.
          return json(200, { data: [] });
        }
        //  The item's own id is the item's id.  The version is named in the
        //  relationship, and reading the item's id as the version's would
        //  never match.
        return json(200, { data: [{
          type: "reviewSubmissionItems",
          id: "item-1",
          relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: options.boundTo } } }
        }] });
      }
      if (req.method === "GET" && /^\/v1\/reviewSubmissions\/[^/]+$/.test(url)) {
        //  The read back after the submit, so the report can say what the
        //  submission's state actually is.
        const id = url.split("/").pop();
        if (sent.has(id)) {
          return json(200, {
            data: {
              type: "reviewSubmissions",
              id,
              attributes: { state: "WAITING_FOR_REVIEW", submittedDate: "2026-10-20T00:00:00Z" }
            }
          });
        }
        //  The read before the submission is touched:  a draft, with the
        //  platform it carries.  A server that has no platform at all
        //  answers with none, and the client has to catch that.
        const draftPlatform = platformOf(id);
        const draftAttributes = { state: "READY_FOR_REVIEW", submittedDate: null };
        if (draftPlatform !== null) draftAttributes.platform = draftPlatform;
        return json(200, {
          data: {
            type: "reviewSubmissions",
            id,
            attributes: draftAttributes
          }
        });
      }
      return json(404, { errors: [{ title: "not found" }] });
    });
  });
  return { server, patched, bound, created, order };
}

function submit(base, args = []) {
  return new Promise((resolve) => {
    const child = spawn("node", [script, "submit-review", VERSION_ID, ...args], {
      //  The child is given the values it needs and nothing else:  a wholesale
      //  copy of the parent environment would hand every credential on this
      //  machine to the command under test.
      env: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        ASC_API_BASE: base,
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
}

async function withServer(options, fn) {
  const { server, patched, bound, created, order } = serve(options);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn(base, patched, bound, created, order);
  } finally {
    server.close();
  }
}

const READY = { iphoneScreens: 3, ipadScreens: 3, boundTo: VERSION_ID };

test("the screenshot count is read from the screenshots, not from the set", async () => {
  //  A set carries no count of its own:  App Store Connect does not expose
  //  one.  The count is read from the screenshots the set holds, and the
  //  breakdown it produces names the display type with its count.
  await withServer(READY, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 0, `expected the submission to go out, got ${code}: ${stderr}`);
    assert.match(
      stderr,
      /screenshots by display type: APP_IPAD_PRO_3GEN_129 3, APP_IPHONE_67 3/,
      `the breakdown did not carry the real counts:\n${stderr}`
    );
  });
});

test("a screenshot read that fails stops the run instead of counting nothing", async () => {
  //  A set that could not be read is a failure, not an empty set:  treating
  //  it as empty would let an irreversible submission go out on a read that
  //  never happened.
  await withServer({ ...READY, shotsFail: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.equal(patched.length, 0, "the submission was patched even though the screenshots could not be read");
  });
});

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

test("the 12.9-inch iPad set does not stand in for the 13-inch one", async () => {
  //  The two iPad display types are one device family, so a version carrying
  //  only the 12.9-inch set satisfies a family count.  App Store Connect
  //  still refuses it, with STATE_ERROR.SCREENSHOT_REQUIRED.IPAD_13_PROFILE,
  //  and the refusal has to happen before the submission goes out.
  await withServer(
    { ...READY, ipadScreens: 0, ipad129Screens: 3 },
    async (base, patched) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.ok(
        /no screenshot for the required display type APP_IPAD_PRO_3GEN_129/.test(stderr),
        `the refusal did not name the missing display type:\n${stderr}`
      );
      assert.equal(patched.length, 0, "the submission was patched without a 13-inch iPad screenshot");
    }
  );
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
  //  One submission carries one version, so a submission that already holds
  //  another version cannot be given this one.  It is left alone rather than
  //  submitted, because submitting it would send the wrong build to review.
  await withServer({ ...READY, boundTo: "some-other-version" }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /is bound to some-other-version/.test(stderr),
      `the refusal did not say the submission was bound elsewhere:\n${stderr}`
    );
    assert.ok(
      /holds another version/.test(stderr),
      `the refusal did not say what has to be cleared:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the wrong version's submission was patched");
  });
});

test("a submission with no items is bound to the version and submitted", async () => {
  //  This is the state a clean account is in:  the version is bound to
  //  nothing, and the command has to make the binding itself.  The items
  //  relationship cannot be written, so the binding is a review submission
  //  item of its own.
  await withServer({ ...READY, boundTo: undefined }, async (base, patched, bound) => {
    const { code, stdout, stderr } = await submit(base);
    assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
    assert.equal(bound.length, 1, "the version was not bound to a review submission");
    const relationships = bound[0].data?.relationships;
    assert.equal(relationships?.reviewSubmission?.data?.id, SUBMISSION_ID);
    assert.equal(relationships?.appStoreVersion?.data?.id, VERSION_ID);
    assert.equal(patched.length, 1, "the submission was not patched");
    assert.equal(patched[0].body?.data?.attributes?.submitted, true);
    const report = JSON.parse(stdout.trim());
    assert.equal(report.reviewSubmission, SUBMISSION_ID);
  });
});

test("the binding refusal reports the blockers App Store Connect named", async () => {
  //  The refusal on the binding call carries the list of what is not ready,
  //  one entry per resource.  It is the most useful thing the command can
  //  print, so it is reported rather than swallowed.
  await withServer({ ...READY, boundTo: undefined, bindFails: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /STATE_ERROR\.SCREENSHOT_REQUIRED\.IPAD_13_PROFILE/.test(stderr),
      `the refusal did not name the missing screenshot:\n${stderr}`
    );
    assert.ok(
      /STATE_ERROR\.APP_DATA_USAGES_REQUIRED/.test(stderr),
      `the refusal did not name the missing privacy answers:\n${stderr}`
    );
    assert.ok(
      /\/v1\/appDataUsages\//.test(stderr),
      `the refusal did not name the resource that is not ready:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched even though the version was not ready");
  });
});

test("a review submission is created when the app has none", async () => {
  await withServer({ ...READY, noSubmissions: true, boundTo: undefined }, async (base, patched, bound, created) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
    assert.equal(created.length, 1, "no review submission was created");
    assert.equal(created[0].data?.attributes?.platform, "IOS");
    assert.equal(created[0].data?.relationships?.app?.data?.id, APP_ID);
    assert.equal(bound.length, 1, "the version was not bound to the new submission");
    assert.equal(patched.length, 1, "the submission was not patched");
  });
});

test("a build whose pre-release version has no include stops the submission", async () => {
  //  The build names a pre-release version and the read returns no include
  //  for it, so the comparison that pairs the version with the build did not
  //  happen.  Letting the submission through would skip it.
  await withServer({ ...READY, preReleaseWithoutInclude: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /returns no include for it/.test(stderr),
      `the refusal did not say what was unreadable:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched without a comparable build");
  });
});

test("a build whose marketing version cannot be read stops the submission", async () => {
  //  The include is there but carries no version string, so the comparison
  //  is still impossible and the submission must not go out.
  await withServer({ ...READY, preReleaseWithoutVersion: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /marketing version could not be read/.test(stderr),
      `the refusal did not say what was unreadable:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched without a comparable build");
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

test("a failed build read stops the submission", async () => {
  //  The build read carries the version-string comparison.  A read that
  //  failed is not a build with no pre-release version:  submitting on it
  //  would send the build to review without the check that would have caught
  //  a mismatched version.
  await withServer({ ...READY, preReleaseFails: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /submit-review: .*rejected the key/.test(stderr),
      `the failed read was not reported as one:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the submission was patched after a failed build read");
  });
});

test("a build with no pre-release version is submitted", async () => {
  //  JSON:API leaves `included` out when the document has no included
  //  resources, so a build with no pre-release version must not be refused
  //  for the absence of a comparison it could not have made.
  await withServer({ ...READY, preReleaseMissing: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
    assert.equal(patched.length, 1, "the submission was not patched");
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
    //  The one call that cannot be undone carries the one attribute that has
    //  been proven in production, and nothing else.  The platform was already
    //  on the submission.
    assert.equal(attributes?.platform, undefined, "the irreversible call carried more than the submit");
  });
});

test("a rejected credential stops the run at the binding", async () => {
  //  A 401 on the binding is not a recoverable error:  the calls after it
  //  include the submit, which cannot be undone, so the run has to stop with
  //  the credential App Store Connect has already refused.
  await withServer({ ...READY, boundTo: undefined, bindAuthFailsOnce: true, secondSubmission: true },
    async (base, patched, bound) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.match(stderr, /rejected the key/, `the rejection was not reported:\n${stderr}`);
      assert.equal(bound.length, 1, "the run went on to the next candidate with a rejected credential");
      assert.equal(patched.length, 0, "a submission was sent with a rejected credential");
    });
});

test("a submission that holds another version is never patched", async () => {
  //  The platform is set on the candidate that is actually going to be
  //  submitted, so a submission that is left alone is not mutated either.
  await withServer({ ...READY, boundTo: "some-other-version", desktopScreens: 3 },
    async (base, patched) => {
      const { code, stderr } = await submit(base, [SUBMISSION_ID, "MAC_OS"]);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.match(stderr, /holds another version/, `the refusal did not say what has to be cleared:\n${stderr}`);
      assert.equal(patched.length, 0, "a submission that was skipped was patched");
    });
});

test("a named submission for another platform is refused when no platform was asked for", async () => {
  //  The default platform is this command's, not the operator's, so a
  //  submission somebody prepared for another platform is never rewritten to
  //  the default and submitted.
  await withServer({ ...READY, submissionPlatform: "MAC_OS" }, async (base, patched, bound) => {
    const { code, stderr } = await submit(base, [SUBMISSION_ID]);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.match(stderr, /is for MAC_OS/, `the refusal did not name the platform:\n${stderr}`);
    assert.equal(patched.length, 0, "the submission was rewritten to the default platform");
    assert.equal(bound.length, 0, "the version was bound before the refusal");
  });
});

test("the submit refusal reports the blockers App Store Connect named", async () => {
  //  The refusal on the submit carries the same blockers the binding refusal
  //  carries.  Reporting that no submission is bound would be false:  this
  //  run bound the version itself.
  await withServer({ ...READY, boundTo: undefined, submitFails: true }, async (base, patched) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /STATE_ERROR\.SCREENSHOT_REQUIRED\.IPAD_13_PROFILE/.test(stderr),
      `the refusal did not name the missing screenshot:\n${stderr}`
    );
    assert.ok(
      /STATE_ERROR\.APP_DATA_USAGES_REQUIRED/.test(stderr),
      `the refusal did not name the missing privacy answers:\n${stderr}`
    );
    assert.doesNotMatch(
      stderr,
      /no review submission is bound to this version/,
      `the refusal said the version was unbound:\n${stderr}`
    );
    assert.equal(patched.length, 1, "the submit was not attempted");
  });
});

test("a submit refusal without blockers says that App Store Connect refused it", async () => {
  //  The run bound the version itself, so saying that no submission is bound
  //  to it would be false.
  await withServer({ ...READY, boundTo: undefined, submitFailsPlain: true }, async (base) => {
    const { code, stderr } = await submit(base);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /App Store Connect refused the submission/.test(stderr),
      `the refusal did not say what App Store Connect answered:\n${stderr}`
    );
    assert.doesNotMatch(
      stderr,
      /no review submission is bound to this version/,
      `the refusal said the version was unbound:\n${stderr}`
    );
  });
});

test("an auto-discovered submission with no platform is given the platform before it is submitted", async () => {
  //  A submission whose platform attribute is absent would go to review with
  //  no platform at all, because the platform is never applied on that path.
  //  It is set, and read back, before the irreversible call.
  await withServer({ ...READY, submissionHasNoPlatform: true }, async (base, patched) => {
    const { code, stdout, stderr } = await submit(base);
    assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
    assert.equal(patched.length, 2, `expected a platform patch and a submit patch, got ${patched.length}`);
    assert.equal(patched[0].body?.data?.attributes?.platform, "IOS");
    assert.equal(patched[0].body?.data?.attributes?.submitted, undefined);
    assert.equal(patched[1].body?.data?.attributes?.submitted, true);
    const report = JSON.parse(stdout.trim());
    assert.equal(report.reviewSubmission, SUBMISSION_ID);
  });
});

test("the mock refuses a binding body that names no submission and no version", async () => {
  //  The mock is a trust boundary too:  an inbound body is validated before
  //  it is stored, and a malformed one is refused with a 400 instead of
  //  throwing out of the handler.
  const { server, bound } = serve({ ...READY });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  //  The request carries a timeout, so a handler that throws instead of
  //  answering is a failed assertion and not a hung test.
  const post = (body) => new Promise((resolve) => {
    const request = fetch(`${base}/v1/reviewSubmissionItems`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      signal: AbortSignal.timeout(2000)
    });
    request.then((response) => resolve(response.status)).catch(() => resolve(0));
  });
  try {
    assert.equal(await post("{not json"), 400, "a body that is not JSON was accepted");
    assert.equal(await post(JSON.stringify({ data: { relationships: {} } })), 400,
      "a body with no ids was accepted");
    assert.equal(await post(JSON.stringify({
      data: { relationships: { reviewSubmission: { data: { id: 7 } }, appStoreVersion: { data: { id: "" } } } }
    })), 400, "a body with ids that are not strings was accepted");
    assert.equal(bound.length, 0, "a refused body was stored");
    assert.equal(await post(JSON.stringify({
      data: {
        relationships: {
          reviewSubmission: { data: { id: SUBMISSION_ID } },
          appStoreVersion: { data: { id: VERSION_ID } }
        }
      }
    })), 201, "a valid body was refused");
    assert.equal(bound.length, 1, "the validated body was not stored");
    assert.equal(bound[0].data.relationships.reviewSubmission.data.id, SUBMISSION_ID);
  } finally {
    server.close();
  }
});

test("the platform can be chosen, and a bad one is refused", async () => {
  //  A macOS version carries desktop screenshots, so it is submitted against
  //  a server that serves them rather than the iPhone and iPad sets.
  await withServer({ ...READY, iphoneScreens: 0, ipadScreens: 0, desktopScreens: 3 }, async (base, patched) => {
    const { code, stdout, stderr } = await submit(base, [SUBMISSION_ID, "MAC_OS"]);
    assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
    const report = JSON.parse(stdout.trim());
    assert.equal(report.platform, "MAC_OS");
    //  A named submission that carries another platform has it set first, on
    //  a call that can be undone, so the irreversible one carries only the
    //  submit.
    assert.equal(patched.length, 2, `expected a platform patch and a submit patch, got ${patched.length}`);
    assert.equal(patched[0].body?.data?.attributes?.platform, "MAC_OS");
    assert.equal(patched[0].body?.data?.attributes?.submitted, undefined);
    assert.equal(patched[1].body?.data?.attributes?.submitted, true);
    assert.equal(patched[1].body?.data?.attributes?.platform, undefined);
  });
  await withServer(READY, async (base, patched) => {
    //  The iPhone and iPad sets a macOS version does not carry are not
    //  enough for it, and submitting it anyway is the failure to catch.
    const { code, stderr } = await submit(base, [SUBMISSION_ID, "MAC_OS"]);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(
      /no screenshot for desktop/.test(stderr),
      `the refusal did not say what was missing:\n${stderr}`
    );
    assert.equal(patched.length, 0, "the macOS submission was patched with no desktop screenshot");
  });
  await withServer(READY, async (base) => {
    const { code, stderr } = await submit(base, [SUBMISSION_ID, "WINDOWS"]);
    assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
    assert.ok(/not a review platform/.test(stderr), `the refusal did not say what was wrong:\n${stderr}`);
  });
});

test("a refused submit binds the version once and stops the run", async () => {
  //  The submit was refused after the version was bound to a submission.  A
  //  second candidate would be bound to the same version, and one version
  //  lives on one submission:  the binding cannot be undone from the tool,
  //  so the run stops at the refusal instead of binding a second time.
  await withServer({ ...READY, boundTo: undefined, submitFails: true, secondSubmission: true },
    async (base, patched, bound) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.equal(bound.length, 1, "the version was bound to more than one submission");
      assert.ok(
        /is bound to review submission/.test(stderr),
        `the run did not say that the version is bound:\n${stderr}`
      );
    });
});

test("a run that never submitted says that the version was never bound", async () => {
  //  The binding was refused and no submit was sent, so saying that App
  //  Store Connect refused a submission would be false:  none was sent.
  await withServer({ ...READY, boundTo: undefined, bindFailsPlain: true },
    async (base, patched, bound) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.ok(
        /the version was never bound to a submission/.test(stderr),
        `the run did not say that nothing was bound:\n${stderr}`
      );
      assert.doesNotMatch(
        stderr,
        /App Store Connect refused the submission/,
        `the run said a submission was refused when none was sent:\n${stderr}`
      );
      assert.equal(patched.length, 0, "the submission was patched even though the binding was refused");
    });
});

test("a failed items read says that the version was never bound", async () => {
  //  The items could not be read, so the run never reached a binding and
  //  never reached a submit.
  await withServer({ ...READY, itemsFail: true },
    async (base, patched, bound) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.ok(
        /the version was never bound to a submission/.test(stderr),
        `the run did not say that nothing was bound:\n${stderr}`
      );
      assert.doesNotMatch(
        stderr,
        /App Store Connect refused the submission/,
        `the run said a submission was refused when none was sent:\n${stderr}`
      );
      assert.equal(bound.length, 0, "the version was bound even though the items could not be read");
    });
});

test("a refused platform change leaves the version unbound", async () => {
  //  The platform is proven before the binding, so a platform that cannot be
  //  set stops the run with the version on no submission at all:  there is
  //  nothing for the operator to clear by hand.
  await withServer({ ...READY, boundTo: undefined, submissionHasNoPlatform: true, platformPatchFails: true },
    async (base, patched, bound) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.match(stderr, /the platform could not be set/, `the refusal did not name the platform:\n${stderr}`);
      assert.match(stderr, /the version was not bound/, `the refusal did not say nothing was bound:\n${stderr}`);
      assert.equal(bound.length, 0, "the version was bound even though the platform could not be set");
      assert.equal(patched.length, 1, "the submit was sent even though the platform could not be set");
      assert.equal(patched[0].body?.data?.attributes?.submitted, undefined);
    });
});

test("the platform is proven before the version is bound", async () => {
  //  The order matters:  the binding cannot be undone, so the platform is
  //  set and read back first.
  await withServer({ ...READY, boundTo: undefined, submissionHasNoPlatform: true },
    async (base, patched, bound, created, order) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
      assert.deepEqual(order, ["platform", "bind", "submit"], "the platform was not proven before the binding");
      assert.equal(bound.length, 1, "the version was not bound");
    });
});

test("a draft with no platform stops the submit", async () => {
  //  The read back after the platform change answers with no platform at
  //  all, so the platform could not be proven and the submit does not go
  //  out.
  await withServer({ ...READY, boundTo: undefined, platformReadBackMissing: true },
    async (base, patched, bound) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.match(
        stderr,
        /the platform on sub-1 is unreadable, not IOS/,
        `the refusal did not name the platform:\n${stderr}`
      );
      assert.equal(bound.length, 0, "the version was bound even though the platform was not proven");
      assert.equal(patched.length, 1, "the submit was sent even though the platform was not proven");
      assert.equal(patched[0].body?.data?.attributes?.submitted, undefined);
    });
});

test("a platform that did not take stops the submit", async () => {
  //  The service accepted the platform change and then answered with the
  //  platform the submission had before, so the change did not take and the
  //  submit does not go out.
  await withServer({ ...READY, boundTo: undefined, submissionPlatform: "MAC_OS", platformPatchIgnored: true },
    async (base, patched, bound) => {
      const { code, stderr } = await submit(base, [SUBMISSION_ID, "IOS"]);
      assert.equal(code, 2, `expected a refusal, got ${code}: ${stderr}`);
      assert.match(
        stderr,
        /the platform on sub-1 is MAC_OS, not IOS/,
        `the refusal did not name the platform:\n${stderr}`
      );
      assert.equal(bound.length, 0, "the version was bound even though the platform did not take");
      assert.equal(patched.length, 1, "the submit was sent even though the platform did not take");
      assert.equal(patched[0].body?.data?.attributes?.submitted, undefined);
    });
});

test("a created submission with no platform in the response is set before the submit", async () => {
  //  The create response did not echo a platform.  Recording the platform
  //  that was asked for would make the platform check pass, and the
  //  submission would go to review with a platform that was never proven.
  await withServer({ ...READY, noSubmissions: true, boundTo: undefined, createHidesPlatform: true },
    async (base, patched, bound, created) => {
      const { code, stderr } = await submit(base);
      assert.equal(code, 0, `expected a clean run, got ${code}: ${stderr}`);
      assert.equal(created.length, 1, "no review submission was created");
      assert.equal(bound.length, 1, "the version was not bound to the new submission");
      assert.equal(patched.length, 2, `expected a platform patch and a submit patch, got ${patched.length}`);
      assert.equal(patched[0].body?.data?.attributes?.platform, "IOS");
      assert.equal(patched[0].body?.data?.attributes?.submitted, undefined);
      assert.equal(patched[1].body?.data?.attributes?.submitted, true);
    });
});

test("the mock refuses a patch body that is not a submission", async () => {
  //  The mock is a trust boundary too:  an inbound body is validated before
  //  it is stored, and a malformed one is refused with a 400 instead of
  //  throwing out of the handler.
  const { server } = serve({ ...READY });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const patch = (body) => new Promise((resolve) => {
    const request = fetch(`${base}/v1/reviewSubmissions/sub-1`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body,
      signal: AbortSignal.timeout(2000)
    });
    request.then((response) => resolve(response.status)).catch(() => resolve(0));
  });
  try {
    assert.equal(await patch("{not json"), 400, "a body that is not JSON was accepted");
    assert.equal(await patch(JSON.stringify({ data: { id: "sub-1" } })), 400,
      "a body without attributes was accepted");
    assert.equal(await patch(JSON.stringify({ data: { attributes: { platform: "IOS" } } })), 400,
      "a body without an id was accepted");
    assert.equal(await patch(JSON.stringify({ data: { id: "", attributes: {} } })), 400,
      "a body with an empty id was accepted");
    assert.equal(await patch(JSON.stringify({ data: { id: "sub-1", attributes: { submitted: "yes" } } })), 400,
      "a body with a submitted flag that is not a boolean was accepted");
    assert.equal(await patch(JSON.stringify({ data: { id: "sub-1", attributes: { platform: "" } } })), 400,
      "a body with an empty platform was accepted");
    assert.equal(await patch(JSON.stringify([1, 2, 3])), 400, "a body that is not an object was accepted");
  } finally {
    server.close();
  }
});

test("the mock refuses a create body that names no platform and no app", async () => {
  //  The mock is a trust boundary too:  an inbound body is validated before
  //  it is stored, and a malformed one is refused with a 400 instead of
  //  throwing out of the handler.
  const { server, created } = serve({ ...READY });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (body) => new Promise((resolve) => {
    const request = fetch(`${base}/v1/reviewSubmissions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      signal: AbortSignal.timeout(2000)
    });
    request.then((response) => resolve(response.status)).catch(() => resolve(0));
  });
  try {
    assert.equal(await post("{not json"), 400, "a body that is not JSON was accepted");
    assert.equal(await post(JSON.stringify({ data: { attributes: {} } })), 400,
      "a body without a platform was accepted");
    assert.equal(await post(JSON.stringify({ data: { attributes: { platform: "IOS" } } })), 400,
      "a body without an app was accepted");
    assert.equal(await post(JSON.stringify({ data: { attributes: { platform: "IOS" },
      relationships: { app: { data: { id: "" } } } } })), 400,
      "a body with an empty app id was accepted");
    assert.equal(created.length, 0, "a refused body was stored");
  } finally {
    server.close();
  }
});
