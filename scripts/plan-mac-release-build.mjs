#!/usr/bin/env node
// Plans the ONE build number and the marketing version of a macOS release.
//
// Owner 2026-11-04: the macOS app shipped "1.0.312 (312)" while the iOS
// companion shipped "0.1.0 (202611030314)".  The 1.0.<commit_count> scheme was
// the retired one (AFC-517 / CT-2444 replaced it on the iOS side on
// 2026-10-24), and it made the two apps of one product show two different
// version shapes.  The macOS release now uses the SAME scheme as the iOS one:
//
//   CFBundleShortVersionString = the app's fixed marketing version, read from
//       scripts/ios-fleet/apps.json (apps.codecaps.fixedMarketingVersion), so
//       the two apps cannot drift apart.
//   CFBundleVersion            = one shared MERGE-TIMESTAMP build:  max(S, M+1),
//       where S is the committer date of the commit being built (HEAD) in
//       America/Chicago as YYYYMMDDHHMM, and M is the highest build already
//       published for the macOS app.
//
// S is computed by exactly the rule the iOS ship uses
// (scripts/ios-fleet/ship-testflight.sh merge_stamp), so both apps of one
// merge land on the same number whenever the stamp is the highest, and never
// on a number the other side has already used.
//
// M is read from the macOS app's OWN live Sparkle appcast, which is the only
// place a macOS build number is ever published.  The paired iOS app's builds
// live in App Store Connect, and the iOS side of the shared counter counts
// them together with this app's, so the counter still moves as one.
//
// Usage:
//   node scripts/plan-mac-release-build.mjs            # prints the build number
//   node scripts/plan-mac-release-build.mjs --marketing-version
//   node scripts/plan-mac-release-build.mjs --feed-url <https url>
//
// Fails closed: an unreadable appcast, a missing marketing version or a
// malformed commit date stop the release rather than let it publish a build
// number that does not move forward.  A build number that goes backwards
// strands every installed copy on the old build (see docs/AUTO-UPDATE.md).

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { nextFloorBuild } from "./ios-fleet/shared-build.mjs";

const ROOT_DIR = dirname(dirname(fileURLToPath(import.meta.url)));
const APPS_JSON = join(ROOT_DIR, "scripts", "ios-fleet", "apps.json");
const APP_KEY = "codecaps";
const FEED_TIMEOUT_MS = 30_000;
const MAX_FEED_BYTES = 5_000_000;
const MAX_REDIRECTS = 5;

/**
 * The merge stamp S of HEAD: the committer date of the commit being built,
 * in America/Chicago, as YYYYMMDDHHMM.
 *
 * The shell rule is used verbatim (`TZ=America/Chicago git show -s
 * --format=%cd --date=format-local:%Y%m%d%H%M HEAD`) rather than a JavaScript
 * date conversion, because the iOS ship computes S the same way and the two
 * must agree to the minute.  Throws when HEAD has no readable date.
 */
export function mergeStamp(repoRoot = ROOT_DIR) {
  let stamp = "";
  try {
    stamp = execFileSync(
      "git",
      ["show", "-s", "--format=%cd", "--date=format-local:%Y%m%d%H%M", "HEAD"],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: { ...process.env, TZ: "America/Chicago" },
        stdio: ["ignore", "pipe", "ignore"],
      },
    ).trim();
  } catch {
    throw new Error("could not read the committer date of HEAD");
  }
  if (!/^[1-9][0-9]{11}$/.test(stamp)) {
    throw new Error(`HEAD has no usable committer date (got ${JSON.stringify(stamp)})`);
  }
  return stamp;
}

/**
 * Every build number the appcast names, in the order they appear.
 *
 * A Sparkle appcast carries `<sparkle:version>` for each item.  The macOS
 * app publishes one item per release, so the appcast is the app's whole
 * published history for this purpose.  A version that is not a plain integer
 * is skipped rather than parsed: it is not a number this planner can compare.
 */
export function publishedBuilds(appcast) {
  const found = [];
  const re = /<sparkle:version>\s*([0-9]+)\s*<\/sparkle:version>/g;
  let match;
  while ((match = re.exec(String(appcast ?? ""))) !== null) {
    found.push(match[1]);
  }
  return found;
}

/**
 * The app's fixed marketing version, read from the same file the iOS ship
 * reads it from, so the two apps cannot drift apart.
 */
export function marketingVersion(appsJsonPath = APPS_JSON, appKey = APP_KEY) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(appsJsonPath, "utf8"));
  } catch {
    throw new Error(`could not read ${appsJsonPath}`);
  }
  const value = parsed?.apps?.[appKey]?.fixedMarketingVersion;
  if (typeof value !== "string" || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(value.trim())) {
    throw new Error(`apps.${appKey}.fixedMarketingVersion is missing or malformed`);
  }
  return value.trim();
}

/** The live appcast URL the release floors its build number on. */
export function feedUrl(appsJsonPath = APPS_JSON, appKey = APP_KEY) {
  const parsed = JSON.parse(readFileSync(appsJsonPath, "utf8"));
  const url = parsed?.apps?.[appKey]?.pairedBuildFeed;
  if (typeof url !== "string" || !url.startsWith("https://")) {
    throw new Error(`apps.${appKey}.pairedBuildFeed is missing or not an https URL`);
  }
  return url.trim();
}

/**
 * The plan: the next build number above every build the app has published,
 * and the merge stamp of the commit being built.
 */
export function planBuild({mergeStamp: stamp, publishedBuilds: builds}) {
  return nextFloorBuild({mergeStamp: stamp, builds});
}

/**
 * The appcast, fetched over https only.
 *
 * The release feed is a GitHub "latest release" download URL, which answers
 * with a redirect to the asset, so the redirect is followed by hand:  every
 * hop has to be https, the number of hops is bounded, and the body is
 * time- and size-bounded.  A feed that cannot be read stops the release
 * rather than let it plan a build number from nothing.
 */
async function fetchAppcast(url, fetchImpl = fetch) {
  let current = url;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
    if (!current.startsWith("https://")) {
      throw new Error(`the appcast URL ${current} is not https`);
    }
    const response = await fetchImpl(current, {
      redirect: "manual",
      signal: AbortSignal.timeout(FEED_TIMEOUT_MS),
    });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error(`the appcast at ${current} redirected without a location`);
      current = new URL(location, current).toString();
      continue;
    }
    if (!response.ok) {
      throw new Error(`the appcast at ${current} answered ${response.status}`);
    }
    const text = await response.text();
    if (text.length > MAX_FEED_BYTES) {
      throw new Error(`the appcast at ${current} is larger than ${MAX_FEED_BYTES} bytes`);
    }
    return text;
  }
  throw new Error(`the appcast at ${url} redirected more than ${MAX_REDIRECTS} times`);
}

async function main(argv) {
  const wantsMarketing = argv.includes("--marketing-version");
  let overrideFeed = "";
  const feedIndex = argv.indexOf("--feed-url");
  if (feedIndex >= 0) {
    overrideFeed = String(argv[feedIndex + 1] ?? "");
    if (!overrideFeed.startsWith("https://")) {
      throw new Error("--feed-url must be an https URL");
    }
  }

  if (wantsMarketing) {
    process.stdout.write(`${marketingVersion()}\n`);
    return;
  }

  const stamp = mergeStamp();
  const url = overrideFeed || feedUrl();
  const appcast = await fetchAppcast(url);
  const builds = publishedBuilds(appcast);
  const { build } = planBuild({mergeStamp: stamp, publishedBuilds: builds});
  process.stdout.write(`${build}\n`);
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`[plan-mac-release-build] ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  });
}
