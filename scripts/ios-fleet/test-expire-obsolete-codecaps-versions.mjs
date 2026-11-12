import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "expire-obsolete-codecaps-versions.mjs");
const privateKey = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });

function run(base, bundle = "com.simplewithus.codecaps.ios", action = "--apply") {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [script, bundle, "0.1.0", action], {
      env: {
        ...process.env,
        ASC_KEY_ID: "SYNTHETICKEYID1",
        ASC_ISSUER_ID: "synthetic-issuer",
        ASC_KEY_P8: privateKey,
        APPLE_API_KEY_ID: "",
        APPLE_API_ISSUER_ID: "",
        APPLE_API_KEY_P8_BASE64: "",
        ASC_API_BASE: base,
        NO_PROXY: "127.0.0.1,localhost",
        no_proxy: "127.0.0.1,localhost"
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => { stdout += data; });
    child.stderr.on("data", (data) => { stderr += data; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

async function withASC(state, action) {
  const requests = [];
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    requests.push({ method: request.method, path: url.pathname });
    const send = (status, payload) => {
      response.writeHead(status, { "Content-Type": "application/json" });
      response.end(payload === undefined ? "" : JSON.stringify(payload));
    };
    if (url.pathname === "/v1/apps") {
      send(200, { data: [{ id: "codecaps-ios", type: "apps", attributes: { bundleId: "com.simplewithus.codecaps.ios" } }] });
      return;
    }
    if (url.pathname === "/v1/apps/codecaps-ios/appStoreVersions" && request.method === "GET") {
      send(200, { data: state.versions.map((version) => ({
        id: version.id,
        type: "appStoreVersions",
        attributes: { versionString: version.version, appStoreState: version.state, platform: "IOS" }
      })) });
      return;
    }
    if (url.pathname === "/v1/apps/codecaps-ios/reviewSubmissions" && request.method === "GET") {
      send(200, { data: state.submissions.map((submission) => ({
        id: submission.id,
        type: "reviewSubmissions",
        attributes: { state: submission.state }
      })) });
      return;
    }
    const reviewItems = /^\/v1\/reviewSubmissions\/([^/]+)\/items$/.exec(url.pathname);
    if (reviewItems && request.method === "GET") {
      const submission = state.submissions.find((item) => item.id === reviewItems[1]);
      send(200, { data: (submission?.items || []).map((item) => ({
        id: item.id,
        type: "reviewSubmissionItems",
        attributes: { state: item.state },
        ...(item.versionId ? { relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: item.versionId } } } } : {})
      })) });
      return;
    }
    if (url.pathname === "/v1/builds" && request.method === "GET") {
      send(200, {
        data: state.builds.map((build) => ({
          id: build.id,
          type: "builds",
          attributes: { version: build.build, expired: build.expired },
          relationships: { preReleaseVersion: { data: { type: "preReleaseVersions", id: build.trainId } } }
        })),
        included: state.trains.map((train) => ({
          id: train.id,
          type: "preReleaseVersions",
          attributes: { version: train.version, platform: "IOS" }
        }))
      });
      return;
    }
    const build = /^\/v1\/builds\/([^/]+)$/.exec(url.pathname);
    if (build && request.method === "PATCH") {
      let body = "";
      for await (const chunk of request) body += chunk;
      const update = JSON.parse(body);
      const row = state.builds.find((item) => item.id === build[1]);
      row.expired = update.data.attributes.expired;
      send(200, { data: { id: row.id, type: "builds", attributes: { expired: row.expired } } });
      return;
    }
    const version = /^\/v1\/appStoreVersions\/([^/]+)$/.exec(url.pathname);
    if (version && request.method === "DELETE") {
      state.versions = state.versions.filter((item) => item.id !== version[1]);
      send(204);
      return;
    }
    const reviewItem = /^\/v1\/reviewSubmissionItems\/([^/]+)$/.exec(url.pathname);
    if (reviewItem && request.method === "DELETE") {
      for (const submission of state.submissions) {
        const item = submission.items.find((entry) => entry.id === reviewItem[1]);
        if (item?.versionId) {
          const appVersion = state.versions.find((entry) => entry.id === item.versionId);
          if (appVersion) appVersion.state = "DEVELOPER_REJECTED";
        }
        submission.items = submission.items.filter((entry) => entry.id !== reviewItem[1]);
      }
      send(204);
      return;
    }
    send(404, { errors: [{ title: `unhandled ${request.method} ${url.pathname}` }] });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const result = await action(`http://127.0.0.1:${server.address().port}`, state, requests);
  await new Promise((resolve) => server.close(resolve));
  return result;
}

function fixture() {
  return {
    versions: [
      { id: "version-010", version: "0.1.0", state: "PREPARE_FOR_SUBMISSION" },
      { id: "version-old", version: "1.0.235", state: "PREPARE_FOR_SUBMISSION" },
      { id: "version-review", version: "1.0.236", state: "WAITING_FOR_REVIEW" }
    ],
    submissions: [{
      id: "submission-old",
      state: "WAITING_FOR_REVIEW",
      items: [
        { id: "review-item-old", versionId: "version-review", state: "READY_FOR_REVIEW" },
        { id: "review-item-other", state: "READY_FOR_REVIEW" }
      ]
    }],
    trains: [
      { id: "train-010", version: "0.1.0" },
      { id: "train-old", version: "1.0.235" }
    ],
    builds: [
      { id: "build-010", build: "202611030900", trainId: "train-010", expired: false },
      { id: "build-old-active", build: "352", trainId: "train-old", expired: false },
      { id: "build-old-expired", build: "353", trainId: "train-old", expired: true }
    ]
  };
}

test("dry run reports only non-0.1.0 targets and changes nothing", async () => {
  const state = fixture();
  const result = await withASC(state, async (base) => run(base, undefined, "--dry-run"));
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).buildsToExpire.length, 1);
  assert.deepEqual(JSON.parse(result.stdout).appStoreVersionsToDelete, [{ version: "1.0.235", state: "PREPARE_FOR_SUBMISSION" }]);
  assert.deepEqual(JSON.parse(result.stdout).reviewItemsToRemove, [{
    version: "1.0.236", versionState: "WAITING_FOR_REVIEW", submissionState: "WAITING_FOR_REVIEW", itemState: "READY_FOR_REVIEW"
  }]);
  assert.equal(state.builds[1].expired, false);
  assert.equal(state.versions.length, 3);
  assert.equal(state.submissions[0].items.length, 2);
});

test("apply expires old builds, withdraws the old submission, and preserves every 0.1.0 build", async () => {
  const state = fixture();
  const result = await withASC(state, async (base) => run(base));
  assert.equal(result.code, 0, result.stderr);
  assert.equal(state.builds.find((item) => item.id === "build-010").expired, false);
  assert.equal(state.builds.find((item) => item.id === "build-old-active").expired, true);
  assert.equal(state.builds.find((item) => item.id === "build-old-expired").expired, true);
  assert.deepEqual(state.versions.map((item) => item.version), ["0.1.0"]);
  assert.deepEqual(JSON.parse(result.stdout).deletedAppStoreVersions.sort(), ["1.0.235", "1.0.236"]);
  assert.deepEqual(JSON.parse(result.stdout).removedFromReview, [{ version: "1.0.236", submissionState: "WAITING_FOR_REVIEW" }]);
  assert.deepEqual(state.submissions[0].items.map((item) => item.id), ["review-item-other"]);
});

test("a released old App Store version is reported and never deleted", async () => {
  const state = fixture();
  state.versions.push({ id: "released-old", version: "0.0.9", state: "READY_FOR_DISTRIBUTION" });
  const result = await withASC(state, async (base) => run(base));
  assert.equal(result.code, 3);
  assert.ok(state.versions.some((item) => item.id === "released-old"));
  assert.ok(!state.versions.some((item) => item.id === "version-old"));
});

test("the command refuses another app bundle", async () => {
  const state = fixture();
  const result = await withASC(state, async (base) => run(base, "com.example.other"));
  assert.equal(result.code, 2);
  assert.equal(state.versions.length, 3);
});
