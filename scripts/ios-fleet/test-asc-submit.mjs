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
//   iphoneScreens / ipadScreens: the count in each display type's set
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
//   noSubmissions: the app has no review submission at all
//   submissionPlatform: the platform the named submission answers with
//   platform: the platform the submission answers with
function serve(options) {
  const patched = [];
  const bound = [];
  const created = [];
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

      if (req.method === "PATCH" && url.startsWith("/v1/reviewSubmissions/")) {
        const body = JSON.parse(raw || "{}");
        patched.push({ url, body });
        if (body?.data?.attributes?.submitted === true) {
          sent.add(body.data.id);
        }
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
        const sets = [
          {
            id: "set-1",
            attributes: { screenshotDisplayType: "APP_IPHONE_67", screenshotCount: options.iphoneScreens }
          },
          {
            id: "set-2",
            attributes: { screenshotDisplayType: "APP_IPAD_PRO_129", screenshotCount: options.ipadScreens }
          }
        ];
        if (options.desktopScreens !== undefined) {
          sets.push({
            id: "set-3",
            attributes: { screenshotDisplayType: "APP_DESKTOP", screenshotCount: options.desktopScreens }
          });
        }
        return json(200, { data: sets });
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
        return json(200, { data: [{
          id: SUBMISSION_ID,
          type: "reviewSubmissions",
          attributes: { platform: "IOS", state: "READY_FOR_REVIEW", submittedDate: null }
        }] });
      }
      if (req.method === "POST" && url === "/v1/reviewSubmissions") {
        created.push(JSON.parse(raw || "{}"));
        return json(201, { data: {
          type: "reviewSubmissions",
          id: "sub-new",
          attributes: { platform: "IOS", state: "READY_FOR_REVIEW", submittedDate: null }
        } });
      }
      if (req.method === "POST" && url === "/v1/reviewSubmissionItems") {
        bound.push(JSON.parse(raw || "{}"));
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
        //  platform it carries.
        return json(200, {
          data: {
            type: "reviewSubmissions",
            id,
            attributes: {
              platform: options.submissionPlatform || "IOS",
              state: "READY_FOR_REVIEW",
              submittedDate: null
            }
          }
        });
      }
      return json(404, { errors: [{ title: "not found" }] });
    });
  });
  return { server, patched, bound, created };
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
  const { server, patched, bound, created } = serve(options);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn(base, patched, bound, created);
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
