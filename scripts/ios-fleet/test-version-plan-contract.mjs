/**
 * test-version-plan-contract.mjs - the version-numbering contract between
 * the module and the code that actually ships (AFC-517).
 *
 * version-plan.mjs is the pure, readable copy of the fleet's version rules
 * and version-plan.test.mjs tests it.  That was not enough:  the rules the
 * ship applies live in the client (asc-api.mjs) and in the ship script
 * (ship-testflight.sh), and the module and the ship had already drifted --
 * the module computed "highest patch used + 1" while the client computed the
 * next FREE patch -- so the contract test could not see it.
 *
 * These tests drive the REAL client against a stub App Store Connect (the
 * ASC_API_BASE stub harness test-asc-client.mjs already uses) and hold the
 * module to what the client answers.  No network, no credentials, no real
 * secret:  the key is a synthetic key pair generated here.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { buildFloor, nextMarketingPatch, planVersion } from "./version-plan.mjs";
import { nextSharedBuild } from "./shared-build.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "asc-api.mjs");

const keyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });

const BUNDLE = "com.example.contract";
const APP_ID = "app-1";

/** Run the client against a stub server and collect what it said. */
function run(args, base, env = {}) {
  return new Promise((resolve) => {
    const child = spawn("node", [script, ...args], {
      env: {
        ...process.env,
        ASC_KEY_ID: "SYNTHETICKEYID1",
        ASC_ISSUER_ID: "synthetic-issuer",
        ASC_KEY_P8: keyPem,
        //  The credential sources are cleared so an ambient key on the
        //  machine running the suite cannot decide which credential a test
        //  gets.
        ASC_KEY_PATH: "",
        APPLE_API_KEY_ID: "",
        APPLE_API_ISSUER_ID: "",
        APPLE_API_KEY_P8_BASE64: "",
        ASC_API_BASE: base,
        //  The stub is loopback:  never let an ambient proxy redirect the
        //  client's request away from it.
        NO_PROXY: "127.0.0.1,localhost",
        no_proxy: "127.0.0.1,localhost",
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

/**
 * A stub App Store Connect.
 *
 * `trains` is the state of the app:  { id, version, builds } per TestFlight
 * train.  `appStoreVersions` is the App Store side.  The stub records every
 * request it served, so a test can count them.
 */
async function withStub(state, fn) {
  const requests = [];
  //  An optional paired app for the shared-counter union test:  state.paired
  //  is { bundle, appId, trains }.  Without it the stub answers one app, as
  //  before.
  const paired = state.paired || null;
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    requests.push(url.pathname + url.search);
    const send = (payload) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(payload));
    };

    if (url.pathname === "/v1/apps") {
      const wantedBundle = url.searchParams.get("filter[bundleId]");
      if (paired && wantedBundle === paired.bundle) {
        send({ data: [{ id: paired.appId, type: "apps", attributes: { bundleId: paired.bundle } }] });
        return;
      }
      send({ data: [{ id: APP_ID, type: "apps", attributes: { bundleId: BUNDLE } }] });
      return;
    }
    if (url.pathname === `/v1/apps/${APP_ID}/appStoreVersions`) {
      send({
        data: (state.appStoreVersions || []).map((version) => ({
          id: `store-${version}`,
          type: "appStoreVersions",
          attributes: { versionString: version }
        }))
      });
      return;
    }
    if (url.pathname === "/v1/preReleaseVersions") {
      const data = [];
      const included = [];
      for (const train of state.trains || []) {
        const ids = train.builds.map((_, i) => `build-${train.id}-${i}`);
        const relIds = ids;
        //  The inline window shows only part of a cut-short train's builds:
        //  that is the case the client has to complete.
        const inline = train.cutShort ? relIds.slice(0, 1) : relIds;
        for (const id of inline) {
          included.push({
            type: "builds",
            id,
            attributes: { version: train.builds[ids.indexOf(id)] }
          });
        }
        data.push({
          id: train.id,
          type: "preReleaseVersions",
          attributes: { version: train.version, platform: "IOS" },
          relationships: {
            app: { data: { type: "apps", id: APP_ID } },
            builds: {
              data: relIds.map((id) => ({ type: "builds", id })),
              meta: { paging: { total: train.builds.length } }
            }
          }
        });
      }
      send({ data, included, links: {} });
      return;
    }
    if (url.pathname === "/v1/builds") {
      const wanted = url.searchParams.get("filter[preReleaseVersion.version]");
      const platform = url.searchParams.get("filter[preReleaseVersion.platform]");
      const wantedApp = url.searchParams.get("filter[app]");
      let trains = state.trains || [];
      if (paired) {
        if (wantedApp === paired.appId) trains = paired.trains || [];
        else if (wantedApp && wantedApp !== APP_ID) trains = [];
      }
      const rows = [];
      for (const train of trains) {
        if (wanted && wanted !== train.version) continue;
        //  A train without a platform is an iOS train:  only the shared-build
        //  fixture names a platform, so older fixtures keep meaning iOS.
        if (platform && (train.platform || "IOS") !== platform) continue;
        for (const [i, version] of train.builds.entries()) {
          const row = {
            id: `build-${train.id}-${i}`,
            type: "builds",
            attributes: { version }
          };
          //  A stub that drops the relationship models a service that does
          //  not answer it:  the builds are there, but they cannot be
          //  attributed to a train.
          if (!state.dropRelationship) {
            row.relationships = {
              preReleaseVersion: { data: { type: "preReleaseVersions", id: train.id } }
            };
          }
          rows.push(row);
        }
      }
      send({ data: rows, links: {} });
      return;
    }
    //  The per-train endpoint the client used to call once per cut-short
    //  train.  It is here so a test can see it is NOT called.
    const perTrain = /^\/v1\/preReleaseVersions\/([^/]+)\/builds$/.exec(url.pathname);
    if (perTrain) {
      const train = (state.trains || []).find((t) => t.id === perTrain[1]);
      send({
        data: (train ? train.builds : []).map((version, i) => ({
          id: `build-${train ? train.id : "?"}-${i}`,
          type: "builds",
          attributes: { version }
        })),
        links: {}
      });
      return;
    }
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ errors: [{ title: "not found", detail: url.pathname }] }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn({ base, requests });
  } finally {
    server.close();
  }
}

test("the client and the module plan the same marketing version (AFC-517)", async () => {
  //  The fixture is the drift-skip case:  1.0.236 and 1.0.237 are drift
  //  trains (a <prefix>.N train holding the build named after its patch),
  //  so the next FREE patch is 1.0.238 and not 1.0.236.
  const state = {
    appStoreVersions: ["1.0.235"],
    trains: [
      { id: "t1", version: "1.0.235", builds: ["202610110355", "202610110356"], cutShort: true },
      { id: "t2", version: "1.0.236", builds: ["236", "23601"], cutShort: true },
      { id: "t3", version: "1.0.237", builds: ["237", "2400"], cutShort: true }
    ]
  };
  const expectedNextFree = nextMarketingPatch({
    prefix: "1.0",
    appStoreVersions: state.appStoreVersions,
    trains: state.trains
  });
  assert.equal(expectedNextFree, 238, "the fixture is not the drift-skip case it claims to be");

  await withStub(state, async ({ base }) => {
    const result = await run(["latest-marketing-patch", BUNDLE, "1.0", "IOS"], base);
    assert.equal(result.code, 0, `the client failed:\n${result.stderr}`);
    const printed = Number(result.stdout.trim());
    //  The client prints the next free patch MINUS ONE, so the caller's P + 1
    //  lands on the next free patch.
    assert.equal(printed, expectedNextFree - 1, `the client printed ${printed}`);

    //  The whole chain:  the number the client prints is the number the ship
    //  script feeds the module, and the marketing version that comes out is
    //  the next free patch.  The drift train on 1.0.236 must not be planned
    //  again.
    const plan = planVersion({ prefix: "1.0", ascPatch: printed, commitCount: 10, floor: 0 });
    assert.equal(
      plan.marketing,
      `1.0.${expectedNextFree}`,
      `the ship would plan ${plan.marketing} from the client's ${printed}`
    );
  });
});

test("a cut-short train is completed without one request per train (AFC-517)", async () => {
  //  Every train here is cut short:  the inline build window holds a few of
  //  its builds, so the client has to read the rest.  It used to read each
  //  train on its own -- one request per cut-short train, which is thousands
  //  of requests on a heavily trained app.
  const trains = [];
  for (let i = 0; i < 11; i++) {
    trains.push({
      id: `t${i}`,
      version: `1.0.${300 + i}`,
      builds: [`${300 + i}01`, `${300 + i}02`, `${300 + i}03`],
      cutShort: true
    });
  }
  //  A drift train among them:  it holds the build named after its patch, so
  //  it must not push the next patch forward.
  trains.push({ id: "tdrift", version: "1.0.311", builds: ["311", "31101", "31102"], cutShort: true });
  const state = { appStoreVersions: ["1.0.235"], trains };

  const expectedNextFree = nextMarketingPatch({
    prefix: "1.0",
    appStoreVersions: state.appStoreVersions,
    trains: state.trains.map((t) => ({ version: t.version, builds: t.builds }))
  });

  await withStub(state, async ({ base, requests }) => {
    const result = await run(["latest-marketing-patch", BUNDLE, "1.0", "IOS"], base);
    assert.equal(result.code, 0, `the client failed:\n${result.stderr}`);
    const printed = Number(result.stdout.trim());
    assert.equal(
      printed,
      expectedNextFree - 1,
      `the client printed ${printed}, the next free patch is ${expectedNextFree}`
    );

    const perTrain = requests.filter((r) => /^\/v1\/preReleaseVersions\/[^/]+\/builds/.test(r));
    assert.equal(
      perTrain.length,
      0,
      `the client read ${perTrain.length} train(s) one by one: ${perTrain.join(", ")}`
    );
    const appWide = requests.filter(
      (r) => r.startsWith("/v1/builds?") && r.includes("filter[preReleaseVersion.platform]") && !r.includes("preReleaseVersion.version")
    );
    assert.equal(
      appWide.length,
      1,
      `the whole app was not read in one query (${appWide.length} app-wide builds queries)`
    );
  });
});

test("a build that cannot be attributed to its train falls back to reading the train (AFC-517)", async () => {
  //  The app-wide query groups the builds by the train they belong to, which
  //  needs the build's preReleaseVersion relationship.  When the service does
  //  not answer it, the builds cannot be attributed, and a train that looks
  //  emptier than it is can be a drift train -- which would plan a patch that
  //  already exists.  So the client falls back to reading the train on its
  //  own and gets the right answer either way.
  const state = {
    appStoreVersions: ["1.0.235"],
    dropRelationship: true,
    trains: [
      { id: "t1", version: "1.0.235", builds: ["202610110355", "202610110356"], cutShort: true },
      { id: "t2", version: "1.0.236", builds: ["236", "23601"], cutShort: true },
      { id: "t3", version: "1.0.237", builds: ["237", "2400"], cutShort: true }
    ]
  };
  const expectedNextFree = nextMarketingPatch({
    prefix: "1.0",
    appStoreVersions: state.appStoreVersions,
    trains: state.trains
  });
  assert.equal(expectedNextFree, 238, "the fixture is not the drift-skip case it claims to be");

  await withStub(state, async ({ base, requests }) => {
    const result = await run(["latest-marketing-patch", BUNDLE, "1.0", "IOS"], base);
    assert.equal(result.code, 0, `the client failed:\n${result.stderr}`);
    const printed = Number(result.stdout.trim());
    assert.equal(
      printed,
      expectedNextFree - 1,
      `the client printed ${printed}, the next free patch is ${expectedNextFree}`
    );
    const perTrain = requests.filter((r) => /^\/v1\/preReleaseVersions\/[^/]+\/builds/.test(r));
    assert.ok(
      perTrain.length > 0,
      "the client trusted an app-wide answer it could not attribute to any train"
    );
  });
});

test("the client and the module agree on the build floor (AFC-517)", async () => {
  const state = {
    appStoreVersions: ["1.0.235"],
    trains: [
      { id: "t1", version: "1.0.235", builds: ["202610110355"] },
      { id: "t2", version: "1.0.236", builds: ["236"] }
    ]
  };
  await withStub(state, async ({ base }) => {
    const result = await run(["build-floor", BUNDLE, "1.0.236", "IOS"], base);
    assert.equal(result.code, 0, `the client failed:\n${result.stderr}`);
    const floor = Number(result.stdout.trim());
    const expected = buildFloor({
      trainBuilds: state.trains[1].builds,
      appBuilds: state.trains.flatMap((t) => t.builds),
      platform: "IOS"
    });
    assert.equal(floor, expected, `the client answered ${floor}, the module says ${expected}`);
  });
});

test("a rejected key is named by key id and source, with nothing from the key (AFC-517)", async () => {
  //  The refusal has to say WHICH credential was refused, using only
  //  nonsecret labels:  the key id and the source it was resolved from.  No
  //  fragment of the key body may appear, masked or not.
  const server = createServer((req, res) => {
    res.writeHead(401, { "Content-Type": "text/plain" });
    res.end("unauthorized");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let result;
  try {
    result = await run(["latest-marketing-patch", BUNDLE, "1.0", "IOS"], base);
  } finally {
    server.close();
  }
  //  Exit 4 is the shell's "a rejected credential" code.
  assert.equal(result.code, 4, `expected the rejected-credential exit, got ${result.code}:\n${result.stderr}`);
  const material = keyPem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  assert.ok(
    result.stderr.includes("key id SYNTHETICKEYID1, key source "),
    `the rejection did not name the key id and source:\n${result.stderr}`
  );
  assert.ok(!/key in play/.test(result.stderr), `the rejection still carries a key preview:\n${result.stderr}`);
  for (let i = 0; i + 8 <= material.length; i++) {
    assert.ok(
      !result.stderr.includes(material.slice(i, i + 8)),
      `an eight-character fragment of the key body reached the diagnostic at offset ${i}`
    );
  }
  assert.ok(!result.stderr.includes(`…${material.slice(-4)}`), "the key body's last four characters reached the diagnostic");
});

test("the client and the module agree on the next shared build", async () => {
  //  The iOS train holds a four-digit build and a timestamp build the counter
  //  ignores; the macOS train holds one four-digit build.  The floor on the
  //  command line sits above both, so it decides the answer.
  const iosBuilds = ["1004", "202610110355"];
  const macBuilds = ["1007"];
  const state = {
    trains: [
      { id: "t-ios", version: "1.0.1", builds: iosBuilds },
      { id: "t-mac", version: "1.0.1", builds: macBuilds, platform: "MAC_OS" }
    ]
  };
  const expected = nextSharedBuild({ iosBuilds, macBuilds, extraFloors: [1009], complete: true }).build;
  assert.equal(expected, "1010", `the fixture does not let the floor decide: ${expected}`);

  await withStub(state, async ({ base, requests }) => {
    const result = await run(["next-shared-build", BUNDLE, "1009"], base);
    assert.equal(result.code, 0, `the client failed:\n${result.stderr}`);
    assert.equal(
      result.stdout.trim(),
      expected,
      `the client printed ${result.stdout.trim()}, the module says ${expected}`
    );

    //  One inventory read per platform:  the iOS timestamp build is filtered
    //  by the counter, not by a narrower query.
    const iosQueries = requests.filter(
      (r) => r.startsWith("/v1/builds?") && r.includes("filter[preReleaseVersion.platform]=IOS")
    );
    const macQueries = requests.filter(
      (r) => r.startsWith("/v1/builds?") && r.includes("filter[preReleaseVersion.platform]=MAC_OS")
    );
    assert.equal(
      iosQueries.length,
      1,
      `expected one iOS builds query, saw ${iosQueries.length}: ${iosQueries.join(", ")}`
    );
    assert.equal(
      macQueries.length,
      1,
      `expected one macOS builds query, saw ${macQueries.length}: ${macQueries.join(", ")}`
    );
  });
});

test("next-shared-build unions IOS and MAC_OS across both paired apps", async () => {
  //  Each of the four inventories holds a distinct build.  The paired app's
  //  iOS build is the highest, so the answer proves IOS(paired) joined:
  //  without it the max would be the paired macOS build and next 1401.
  const PAIRED_BUNDLE = "com.example.paired";
  const PAIRED_APP = "app-2";
  const state = {
    trains: [
      { id: "t-main-ios", version: "1.0.1", builds: ["1100"], platform: "IOS" },
      { id: "t-main-mac", version: "1.0.1", builds: ["1200"], platform: "MAC_OS" }
    ],
    paired: {
      bundle: PAIRED_BUNDLE,
      appId: PAIRED_APP,
      trains: [
        { id: "t-pair-ios", version: "1.0.1", builds: ["1500"], platform: "IOS" },
        { id: "t-pair-mac", version: "1.0.1", builds: ["1400"], platform: "MAC_OS" }
      ]
    }
  };
  const expected = nextSharedBuild({
    iosBuilds: ["1100", "1500"],
    macBuilds: ["1200", "1400"],
    extraFloors: [],
    complete: true
  }).build;
  assert.equal(expected, "1501", `the fixture does not let paired iOS decide: ${expected}`);

  await withStub(state, async ({ base, requests }) => {
    const result = await run(["next-shared-build", BUNDLE, PAIRED_BUNDLE], base);
    assert.equal(result.code, 0, `the client failed:\n${result.stderr}`);
    assert.equal(
      result.stdout.trim(),
      expected,
      `the client printed ${result.stdout.trim()}, the union says ${expected}`
    );
    //  Two apps times two platforms:  IOS(app) + IOS(paired),
    //  MAC_OS(app) + MAC_OS(paired).
    const buildsQueries = requests.filter((r) => r.startsWith("/v1/builds?"));
    assert.equal(
      buildsQueries.length,
      4,
      `expected four builds queries (two apps x two platforms), saw ${buildsQueries.length}: ${buildsQueries.join(", ")}`
    );
    for (const appId of [APP_ID, PAIRED_APP]) {
      for (const platform of ["IOS", "MAC_OS"]) {
        assert.ok(
          buildsQueries.some((r) => r.includes(`filter[app]=${appId}`) && r.includes(`filter[preReleaseVersion.platform]=${platform}`)),
          `no builds query for app ${appId} platform ${platform}: ${buildsQueries.join(", ")}`
        );
      }
    }
  });

  //  The mirror case:  the paired macOS build is the highest, so the answer
  //  proves MAC_OS(paired) joined too.
  const state2 = {
    trains: [
      { id: "t-main-ios", version: "1.0.1", builds: ["1100"], platform: "IOS" },
      { id: "t-main-mac", version: "1.0.1", builds: ["1200"], platform: "MAC_OS" }
    ],
    paired: {
      bundle: PAIRED_BUNDLE,
      appId: PAIRED_APP,
      trains: [
        { id: "t-pair-ios", version: "1.0.1", builds: ["1150"], platform: "IOS" },
        { id: "t-pair-mac", version: "1.0.1", builds: ["1600"], platform: "MAC_OS" }
      ]
    }
  };
  const expected2 = nextSharedBuild({
    iosBuilds: ["1100", "1150"],
    macBuilds: ["1200", "1600"],
    extraFloors: [],
    complete: true
  }).build;
  assert.equal(expected2, "1601", `the fixture does not let paired macOS decide: ${expected2}`);
  await withStub(state2, async ({ base }) => {
    const result = await run(["next-shared-build", BUNDLE, PAIRED_BUNDLE], base);
    assert.equal(result.code, 0, `the client failed:\n${result.stderr}`);
    assert.equal(
      result.stdout.trim(),
      expected2,
      `the client printed ${result.stdout.trim()}, the union says ${expected2}`
    );
  });
});

test("next-shared-build reads its inventories concurrently and fails closed past the page cap", async () => {
  //  The independent inventories are fetched with Promise.all, not serial
  //  awaits.  Pinned so a later edit cannot serialize them again.
  const { readFileSync } = await import("node:fs");
  const clientText = readFileSync(script, "utf8");
  const sharedSection = clientText.slice(clientText.indexOf('method === "next-shared-build"'));
  assert.ok(
    sharedSection.includes("Promise.all"),
    "next-shared-build does not fetch its inventories with Promise.all"
  );

  //  Past the 100-page cap the client fails closed (exit 2 with a message)
  //  instead of truncating the inventory and planning from a partial max.
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const send = (payload) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(payload));
    };
    if (url.pathname === "/v1/apps") {
      send({ data: [{ id: APP_ID, type: "apps", attributes: { bundleId: BUNDLE } }] });
      return;
    }
    if (url.pathname === "/v1/builds") {
      const page = Number(url.searchParams.get("page") || "0");
      const next = `http://127.0.0.1:${server.address().port}/v1/builds?filter[app]=${APP_ID}&filter[preReleaseVersion.platform]=IOS&limit=200&page=${page + 1}`;
      send({
        data: [{ id: `build-p${page}`, type: "builds", attributes: { version: "1000" } }],
        links: { next }
      });
      return;
    }
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ errors: [{ title: "not found" }] }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let result;
  try {
    result = await run(["next-shared-build", BUNDLE], base);
  } finally {
    server.close();
  }
  assert.equal(result.code, 2, `expected exit 2 past the page cap, got ${result.code}:\n${result.stderr}`);
  assert.ok(
    /incomplete pagination|more than 100 pages/.test(result.stderr),
    `the cap failure named no reason:\n${result.stderr}`
  );
  assert.equal(result.stdout.trim(), "", "a capped inventory must print no build");
});
