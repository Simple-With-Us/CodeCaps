/**
 * version-plan.test.mjs - unit tests for the fleet's version-numbering rules.
 *
 * Pure:  no network, no credentials, no App Store Connect.  The data in the
 * "real Congress.Trade" case is the live App Store Connect state measured
 * 2026-10-24 (AFC-517 / CT-2444):
 *
 *   App Store versions : 1.0.235
 *   TestFlight trains  : 1.0.235 [202610110355]
 *                        1.0.236 [202610180036]
 *                        1.0.2353 [2353]   <- drift train (build "2353")
 *                        1.0.2358 [2358]   <- drift train (build "2358")
 *
 * so the next marketing version is 1.0.237 -- the drift trains must not push
 * it to 1.0.2359.
 */
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  buildFloor,
  isDriftTrain,
  latestMarketingPatch,
  ownPatch,
  parsePatch,
  planCodeCapsVersion,
  planVersion,
  nextMarketingPatch,
  publishedMarketingFloor
} from "./version-plan.mjs";

const plannerCli = join(dirname(fileURLToPath(import.meta.url)), "plan-codecaps-version.mjs");
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../..");

const CONGRESS_APP_STORE_VERSIONS = ["1.0.235"];
const CONGRESS_TRAINS = [
  { version: "1.0.235", builds: ["202610110355"] },
  { version: "1.0.236", builds: ["202610180036"] },
  { version: "1.0.2353", builds: ["2353"] },
  { version: "1.0.2358", builds: ["2358"] }
];

test("parsePatch reads the patch of a version on a train", () => {
  assert.equal(parsePatch("1.0.236", "1.0"), 236);
  assert.equal(parsePatch("1.0.2358", "1.0"), 2358);
  assert.equal(parsePatch("2.0.5", "2.0"), 5);
});

test("parsePatch rejects a version that is not <prefix>.<digits>", () => {
  assert.equal(parsePatch("1.0", "1.0"), null);
  assert.equal(parsePatch("1.01.5", "1.0"), null);
  assert.equal(parsePatch("2.0.5", "1.0"), null);
  assert.equal(parsePatch("1.0.236.1", "1.0"), null);
  assert.equal(parsePatch("", "1.0"), null);
  assert.equal(parsePatch("1.0.abc", "1.0"), null);
});

test("parsePatch escapes the prefix", () => {
  // "1.0" must not match "120" or "1x0".
  assert.equal(parsePatch("120.5", "1.0"), null);
  assert.equal(parsePatch("1x0.5", "1.0"), null);
  assert.equal(parsePatch("1.0.5", "1.0"), 5);
});

test("ownPatch reads the patch of a version on its own train", () => {
  assert.equal(ownPatch("1.0.236"), 236);
  assert.equal(ownPatch("2.0.5"), 5);
  assert.equal(ownPatch("1.0"), null);
  assert.equal(ownPatch("nonsense"), null);
});

test("isDriftTrain spots a train that holds the build named after its patch", () => {
  assert.equal(isDriftTrain("1.0.2358", ["2358"], "1.0"), true);
  assert.equal(isDriftTrain("1.0.2353", ["2353", "202610180036"], "1.0"), true);
  // A UTC-stamped build is not the patch number:  not a drift train.
  assert.equal(isDriftTrain("1.0.236", ["202610180036"], "1.0"), false);
  // A train with no patch has no drift to speak of.
  assert.equal(isDriftTrain("1.0", ["1"], "1.0"), false);
  assert.equal(isDriftTrain("2.0.5", ["5"], "1.0"), false);
});

test("latestMarketingPatch ignores drift trains (real Congress.Trade data)", () => {
  const patch = latestMarketingPatch({
    prefix: "1.0",
    appStoreVersions: CONGRESS_APP_STORE_VERSIONS,
    trains: CONGRESS_TRAINS
  });
  // 1.0.2358 and 1.0.2353 are drift trains, so 236 wins.
  assert.equal(patch, 236);
});

test("latestMarketingPatch counts App Store versions that no train carries", () => {
  const patch = latestMarketingPatch({
    prefix: "1.0",
    appStoreVersions: ["1.0.240"],
    trains: [{ version: "1.0.2358", builds: ["2358"] }]
  });
  assert.equal(patch, 240);
});

test("latestMarketingPatch returns 0 for an empty train", () => {
  assert.equal(latestMarketingPatch({ prefix: "1.0", appStoreVersions: [], trains: [] }), 0);
});

test("publishedMarketingFloor includes versions in drift trains", () => {
  assert.equal(publishedMarketingFloor({
    prefix: "1.0",
    appStoreVersions: ["1.0.264"],
    trains: [
      { version: "1.0.280", builds: ["280"] },
      { version: "1.0.285", builds: ["285"] }
    ]
  }), 285);
});

test("buildFloor keeps the old UTC stamp inside the target train", () => {
  const floor = buildFloor({
    trainBuilds: ["202610180036"],
    appBuilds: [],
    platform: "IOS"
  });
  assert.equal(floor, 202610180036);
});

test("buildFloor ignores huge app builds on iOS but not on macOS", () => {
  const appBuilds = ["2353", "2358", "202610180036"];
  assert.equal(buildFloor({ trainBuilds: [], appBuilds, platform: "IOS" }), 2358);
  assert.equal(buildFloor({ trainBuilds: [], appBuilds, platform: "MAC_OS" }), 202610180036);
});

test("buildFloor ignores dotted and non-numeric build values", () => {
  const floor = buildFloor({
    trainBuilds: ["1.0.5", "abc", ""],
    appBuilds: ["42", "1.0.9", "x"],
    platform: "IOS"
  });
  assert.equal(floor, 42);
});

test("planVersion picks the next patch on the train (real Congress.Trade data)", () => {
  // ascPatch is what production feeds planVersion:  nextMarketingPatch - 1.
  // The client prints exactly that number, so the module and the ship plan
  // the same marketing version.
  const ascPatch = nextMarketingPatch({
    prefix: "1.0",
    appStoreVersions: CONGRESS_APP_STORE_VERSIONS,
    trains: CONGRESS_TRAINS
  }) - 1;
  assert.equal(ascPatch, 236);

  const floor = buildFloor({
    trainBuilds: [],                       // the new train is empty
    appBuilds: ["2353", "2358", "202610180036"],
    platform: "IOS"
  });
  assert.equal(floor, 2358);

  const plan = planVersion({
    prefix: "1.0",
    ascPatch,
    commitCount: 2360,
    floor
  });
  assert.equal(plan.marketing, "1.0.237");
  assert.equal(plan.build, "2360");
});

test("planVersion raises the build above the floor of the forced train", () => {
  const floor = buildFloor({
    trainBuilds: ["202610180036"],
    appBuilds: [],
    platform: "IOS"
  });
  assert.equal(floor, 202610180036);

  const plan = planVersion({
    prefix: "1.0",
    ascPatch: 236,
    forcedVersion: "1.0.236",
    commitCount: 2360,
    floor
  });
  assert.equal(plan.marketing, "1.0.236");
  assert.equal(plan.build, "202610180037");
});

test("planVersion never ships 1.0.N (N)", () => {
  // The commit count happens to be the patch number of the next marketing
  // version:  the build moves one up so the pair cannot read "1.0.237 (237)".
  const plan = planVersion({
    prefix: "1.0",
    ascPatch: 236,
    commitCount: 237,
    floor: 0
  });
  assert.equal(plan.marketing, "1.0.237");
  assert.equal(plan.build, "238");

  // Same rule for an explicit --version.
  const forced = planVersion({
    prefix: "1.0",
    ascPatch: 236,
    forcedVersion: "1.0.236",
    commitCount: 236,
    floor: 0
  });
  assert.equal(forced.marketing, "1.0.236");
  assert.equal(forced.build, "237");
});

test("planVersion keeps the macOS floor (build numbers grow across trains)", () => {
  const floor = buildFloor({
    trainBuilds: [],
    appBuilds: ["2358", "202610180036"],
    platform: "MAC_OS"
  });
  assert.equal(floor, 202610180036);

  const plan = planVersion({
    prefix: "1.0",
    ascPatch: 236,
    commitCount: 2360,
    floor
  });
  assert.equal(plan.marketing, "1.0.237");
  assert.equal(plan.build, "202610180037");
});

test("planVersion honours an exact --build override", () => {
  const plan = planVersion({
    prefix: "1.0",
    ascPatch: 236,
    forcedBuild: "999",
    commitCount: 2360,
    floor: 202610180036
  });
  assert.equal(plan.marketing, "1.0.237");
  assert.equal(plan.build, "999");
});

test("planVersion honours an exact --version override", () => {
  const plan = planVersion({
    prefix: "1.0",
    ascPatch: 236,
    forcedVersion: "2.0.5",
    commitCount: 2360,
    floor: 0
  });
  assert.equal(plan.marketing, "2.0.5");
  assert.equal(plan.build, "2360");
});

test("planVersion with no App Store Connect state plans 1.0.1", () => {
  const plan = planVersion({ prefix: "1.0", ascPatch: 0, commitCount: 7, floor: 0 });
  assert.equal(plan.marketing, "1.0.1");
  assert.equal(plan.build, "7");
});

test("nextMarketingPatch skips a patch a drift train already holds (Kody, AFC-517)", () => {
  const trains = [
    { version: "1.0.235", builds: ["202610110355"] },
    { version: "1.0.236", builds: ["236"] },        // drift train on the next patch
    { version: "1.0.237", builds: ["237", "2400"] } // drift train we already shipped into
  ];
  assert.equal(latestMarketingPatch({ prefix: "1.0", appStoreVersions: ["1.0.235"], trains }), 235);
  assert.equal(nextMarketingPatch({ prefix: "1.0", appStoreVersions: ["1.0.235"], trains }), 238);
});

test("planVersion lands on the next free patch past a drift train (Kody, AFC-517)", () => {
  const trains = [
    { version: "1.0.235", builds: ["202610110355"] },
    { version: "1.0.236", builds: ["236"] },        // drift train on the next patch
    { version: "1.0.237", builds: ["237", "2400"] } // drift train we already shipped into
  ];
  // The value production feeds in (what latest-marketing-patch prints).
  const ascPatch = nextMarketingPatch({ prefix: "1.0", appStoreVersions: ["1.0.235"], trains }) - 1;
  assert.equal(ascPatch, 237);
  const plan = planVersion({ prefix: "1.0", ascPatch, commitCount: 2500, floor: 2400 });
  assert.equal(plan.marketing, "1.0.238");
  assert.equal(plan.build, "2500");
  // Feeding latestMarketingPatch instead would plan 1.0.236, the drift train's patch.
  // That is why the contract is nextMarketingPatch - 1.
  assert.equal(latestMarketingPatch({ prefix: "1.0", appStoreVersions: ["1.0.235"], trains }), 235);
});

test("planVersion plans the same marketing version as nextMarketingPatch (Kody, AFC-517)", () => {
  // The module and the ship have to agree on EVERY train, not only on the
  // ones where the drift skip does not bite:  the client prints
  // nextMarketingPatch - 1 and the module adds one back, so the marketing
  // version is the next free patch.
  const cases = [
    { appStoreVersions: [], trains: [] },
    { appStoreVersions: ["1.0.235"], trains: [] },
    {
      appStoreVersions: ["1.0.235"],
      trains: [
        { version: "1.0.235", builds: ["202610110355"] },
        { version: "1.0.236", builds: ["202610180036"] },
        { version: "1.0.2353", builds: ["2353"] },
        { version: "1.0.2358", builds: ["2358"] }
      ]
    },
    {
      appStoreVersions: ["1.0.235"],
      trains: [
        { version: "1.0.235", builds: ["202610110355"] },
        { version: "1.0.236", builds: ["236"] },
        { version: "1.0.237", builds: ["237", "2400"] }
      ]
    }
  ];
  for (const state of cases) {
    const nextFree = nextMarketingPatch({ prefix: "1.0", ...state });
    const plan = planVersion({ prefix: "1.0", ascPatch: nextFree - 1, commitCount: 10, floor: 0 });
    assert.equal(
      plan.marketing,
      `1.0.${nextFree}`,
      `the module planned ${plan.marketing} but the next free patch is 1.0.${nextFree}`
    );
  }
});

test("nextMarketingPatch is latest + 1 when nothing is in the way", () => {
  assert.equal(
    nextMarketingPatch({
      prefix: "1.0",
      appStoreVersions: ["1.0.235"],
      trains: [{ version: "1.0.236", builds: ["202610180036"] }, { version: "1.0.2358", builds: ["2358"] }]
    }),
    237
  );
});

test("planVersion refuses a forced build that recreates 1.0.N (N) (Kody, AFC-517)", () => {
  assert.throws(() => planVersion({ prefix: "1.0", ascPatch: 236, forcedBuild: "237", commitCount: 10, floor: 0 }));
  assert.throws(() => planVersion({ prefix: "1.0", forcedVersion: "1.0.236", forcedBuild: "236", commitCount: 10, floor: 0 }));
  assert.deepEqual(
    planVersion({ prefix: "1.0", ascPatch: 236, forcedBuild: "999", commitCount: 10, floor: 0 }),
    { marketing: "1.0.237", build: "999" }
  );
});

test("CodeCaps uses one canonical commit count for marketing and build metadata", () => {
  assert.deepEqual(
    planCodeCapsVersion({ commitCount: 291, marketingFloor: 290, buildFloor: 290 }),
    { marketing: "1.0.291", build: "291" }
  );
});

test("CodeCaps stops when a published marketing or build floor would break shared numbering", () => {
  assert.throws(
    () => planCodeCapsVersion({ commitCount: 291, marketingFloor: 291, buildFloor: 290 }),
    /shared release number must be resolved/
  );
  assert.throws(
    () => planCodeCapsVersion({ commitCount: 291, marketingFloor: 290, buildFloor: 291 }),
    /shared release number must be resolved/
  );
});

test("CodeCaps accepts only explicit overrides equal to the canonical release", () => {
  assert.deepEqual(
    planCodeCapsVersion({ commitCount: 291, marketingFloor: 290, buildFloor: 290, forcedVersion: "1.0.291", forcedBuild: "291" }),
    { marketing: "1.0.291", build: "291" }
  );
  assert.throws(
    () => planCodeCapsVersion({ commitCount: 291, marketingFloor: 290, buildFloor: 290, forcedVersion: "1.0.292" }),
    /canonical shared version/
  );
  assert.throws(
    () => planCodeCapsVersion({ commitCount: 291, marketingFloor: 290, buildFloor: 290, forcedBuild: "292" }),
    /canonical shared build/
  );
  assert.throws(
    () => planCodeCapsVersion({ commitCount: 291, marketingFloor: "unknown", buildFloor: 290 }),
    /cannot verify the published marketing floor/
  );
});

test("CodeCaps platform-only release advances the shared sequence without rebuilding its companion", () => {
  const platformUpdate = planCodeCapsVersion({
    commitCount: 292,
    marketingFloor: 291,
    buildFloor: 291
  });
  assert.deepEqual(platformUpdate, { marketing: "1.0.292", build: "292" });
  // The unbuilt platform remains on its existing 1.0.291/291 metadata; this
  // planner resolves the current platform only and does not schedule a rebuild.
});

test("CodeCaps same-release Mac and iOS builds share the same canonical pair", () => {
  const ios = planCodeCapsVersion({ commitCount: 293, marketingFloor: 292, buildFloor: 291 });
  const mac = planCodeCapsVersion({ commitCount: 293, marketingFloor: 292, buildFloor: 292 });
  assert.deepEqual(mac, ios);
  assert.deepEqual(ios, { marketing: "1.0.293", build: "293" });
});

test("CodeCaps delayed companion build keeps the original release identity", () => {
  const firstPlatform = planCodeCapsVersion({ commitCount: 294, marketingFloor: 293, buildFloor: 293 });
  // The second platform is built later from the same release commit. Its own
  // published floor is independent, so it still receives the release's N.
  const delayedCompanion = planCodeCapsVersion({ commitCount: 294, marketingFloor: 292, buildFloor: 292 });
  assert.deepEqual(delayedCompanion, firstPlatform);
  assert.deepEqual(delayedCompanion, { marketing: "1.0.294", build: "294" });
});

test("CodeCaps planner CLI returns the canonical pair and refuses release overrides", () => {
  const canonical = spawnSync(process.execPath, [plannerCli, "291", "290", "289", "1.0.291", "291"], {
    encoding: "utf8"
  });
  assert.equal(canonical.status, 0, canonical.stderr);
  assert.equal(canonical.stdout, "1.0.291\t291\n");

  const rollback = spawnSync(process.execPath, [plannerCli, "291", "291", "0", "", ""], {
    encoding: "utf8"
  });
  assert.equal(rollback.status, 2);
  assert.match(rollback.stderr, /published marketing floor 291/);
});

test("shared Mac and iOS release helper emits only 1.0.N from full history", () => {
  const helperPath = join(repoRoot, "script/release-version.sh");
  const helper = readFileSync(helperPath, "utf8");
  const macBuild = readFileSync(join(repoRoot, "script/build_and_run.sh"), "utf8");
  assert.match(macBuild, /source "\$ROOT_DIR\/script\/release-version\.sh"/);
  assert.match(macBuild, /short_version\(\)[\s\S]*?codecaps_short_version "\$ROOT_DIR" "\$VERSION_FILE"/);
  assert.match(macBuild, /bundle_version\(\)[\s\S]*?codecaps_commit_count "\$ROOT_DIR"/);
  assert.match(helper, /git -C "\$repo_root" rev-parse --is-shallow-repository/);
  assert.match(helper, /git -C "\$repo_root" rev-list --count HEAD/);

  const temp = mkdtempSync(join(tmpdir(), "codecaps-release-version-test-"));
  const full = join(temp, "full");
  const empty = join(temp, "empty");
  const shallow = join(temp, "shallow");
  const versionFile = join(full, "VERSION");
  const count = (repo) => spawnSync("bash", ["-c", 'source "$1" && codecaps_commit_count "$2"', "test", helperPath, repo], { encoding: "utf8" });
  const marketing = (repo, file) => spawnSync("bash", ["-c", 'source "$1" && codecaps_short_version "$2" "$3"', "test", helperPath, repo, file], { encoding: "utf8" });
  try {
    execFileSync("git", ["init", "--quiet", "--initial-branch=main", full]);
    execFileSync("git", ["-C", full, "-c", "user.name=CodeCaps Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "release fixture"]);
    writeFileSync(versionFile, "1.0\n");
    assert.equal(count(full).stdout, "1\n");
    assert.equal(marketing(full, versionFile).stdout, "1.0.1\n");
    writeFileSync(versionFile, "2.0\n");
    const wrongTrain = marketing(full, versionFile);
    assert.notEqual(wrongTrain.status, 0);
    assert.match(wrongTrain.stderr, /canonical 1\.0\.N marketing train/);

    execFileSync("git", ["init", "--quiet", "--initial-branch=main", empty]);
    const noHead = count(empty);
    assert.notEqual(noHead.status, 0);
    assert.match(noHead.stderr, /refusing to guess a CodeCaps release number/);

    execFileSync("git", ["clone", "--quiet", "--depth=1", `file://${full}`, shallow]);
    const partialHistory = count(shallow);
    assert.notEqual(partialHistory.status, 0);
    assert.match(partialHistory.stderr, /shallow git history/);
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
});
