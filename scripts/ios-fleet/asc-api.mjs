#!/usr/bin/env node
/**
 * Minimal App Store Connect API client. No dependencies beyond Node's
 * built-in crypto (ES256 JWT signing) and fetch (Node 18+).
 *
 * Auth: resolves credentials from the first source that is present
 * (never prints values):
 *   1. APPLE_API_KEY_ID / APPLE_API_ISSUER_ID / APPLE_API_KEY_P8_BASE64
 *      (hosted ios-ship / Infisical; p8 is base64)
 *   2. ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 in the environment
 *   3. Fleet-OPS prod /asc through fleet-secrets
 *
 * A caller-supplied file is NOT a credential source (Kody rule 42, PR #271):
 * the private key is a secret, and the approved sources are the process
 * environment, a captured `fleet-secrets get NAME` and bootstrap-only Keychain
 * credentials.  The shell layer that owns the credential reads a staged key
 * file and hands the key over in the environment, so ASC_KEY_PATH never
 * reaches this client as a path to read.
 *
 * Usage:
 *   node asc-api.mjs GET /v1/apps
 *   node asc-api.mjs GET "/v1/apps?filter[bundleId]=trade.socratic.app"
 *   node asc-api.mjs PATCH /v1/betaAppReviewDetails/<id> '{"data":{...}}'
 *   node asc-api.mjs latest-build-seq <bundleId> <prefix> [platform] [appleId]
 *
 * Prints the raw JSON response to stdout. Caller is responsible for not
 * echoing anything secret-shaped from the response (ASC responses don't
 * carry credentials, only app metadata, so this is safe to print as-is).
 */
import { existsSync, readFileSync, writeFileSync, mkdtempSync, rmSync, chmodSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash, createSign } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { normalizePrivateKey } from "./asc-key.mjs";

// A failure that already knows what to say.
//
// A guard deep in the call stack cannot return from main(), so it throws this
// instead.  The handler at the bottom of the file prints the message on its
// own, without a stack trace, and keeps the exit code the failure set.
class NamedFailure extends Error {}

// The fleet's masked key preview:  the first eight and the last four
// characters, so a key can be identified without any of it being published.
//
// This is the owner's rule of 2026-07-16 and the same shape the other fleet
// apps use (maskApiKeyPreview, buildKeyPreview).  It exists because there is
// otherwise no way to tell which of several keys is the one in play, and
// pasting a value to find out is never the answer.
//
// The preview is taken from the key material rather than from the PEM
// envelope:  every .p8 opens "-----BEGIN" and ends "-----END PRIVATE KEY-----\n",
// so previewing the envelope prints the same eight and four characters for
// every key and identifies none of them.  The text is trimmed first, because
// the key as stored ends with a newline and a preview carrying one splits the
// diagnostic into two lines, of which ship-testflight.sh keeps only the first.
function maskKeyPreview(value) {
  if (typeof value !== "string") {
    return "(too short to preview)";
  }
  const material = value.replace(/-----[^-]+-----/g, "").trim();
  if (material.length < 12) {
    return "(too short to preview)";
  }
  return `${material.slice(0, 8)}…${material.slice(-4)}`;
}

// The device families a version has to carry a screenshot in.
//
// App Store Connect wants a screenshot for every device family the app runs
// on, and the iOS app runs on iPhone and iPad.  The requirement is counted
// per family rather than per display type because either iPhone size and
// either iPad size satisfies it, and a total across both is not enough:  three
// iPhone images and an empty iPad set would pass a total of six and still be
// refused.
const REQUIRED_SCREENSHOT_FAMILIES = ["iphone", "ipad"];

//  The same requirement for a macOS version, which carries desktop
//  screenshots and no iPhone or iPad set at all.  A macOS submission asked
//  for the iOS families would never be ready.
const REQUIRED_SCREENSHOT_FAMILIES_MAC = ["desktop"];

// Which device family a screenshot display type belongs to.
const DISPLAY_TYPE_FAMILY = {
  APP_IPHONE_67: "iphone",
  APP_IPHONE_65: "iphone",
  APP_IPAD_PRO_129: "ipad",
  APP_IPAD_PRO_3GEN_129: "ipad",
  APP_DESKTOP: "desktop"
};

// The specific display types an iOS version has to carry, by name.
//
// Counting the iPad family is not enough, because the two iPad types are one
// family and only one of them is the 13-inch profile.  A version carrying
// only the 12.9-inch set passes a family count and is still refused by App
// Store Connect with STATE_ERROR.SCREENSHOT_REQUIRED.IPAD_13_PROFILE, which
// is the refusal this check exists to catch before the submission goes out.
//
// The 6.9-inch iPhone is named for the same reason:  its refusal is
// STATE_ERROR.SCREENSHOT_REQUIRED.IPHONE_DYNAMIC_ISLAND, and a version
// carrying only the 6.5-inch set is short of it.
const REQUIRED_SCREENSHOT_DISPLAY_TYPES_IOS = ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"];

// The App Store Connect host.
const PRODUCTION_API_BASE = "https://api.appstoreconnect.apple.com";

// Resolve the host every call is made against.
//
// A test points this at a local server so the failure paths can be exercised
// without touching the real service.  Only a loopback override is honoured:
// every call carries an Authorization header holding a JWT signed with the
// real ASC private key, so a stray environment variable must not be able to
// redirect that token to another host.
//
// The production host is accepted explicitly, because a job that pins the host
// it would otherwise use is not a redirect anywhere new.  The value is used as
// a prefix for paths that already begin with "/", so a trailing slash is
// stripped to keep the separator from doubling.
//
// The check runs inside main(), which has a catch handler, so a bad value is
// reported as a named failure instead of an uncaught exception at module
// scope.
function resolveApiBase() {
  const override = process.env.ASC_API_BASE;
  if (!override) return PRODUCTION_API_BASE;
  const trimmed = override.replace(/\/+$/, "");
  if (trimmed === PRODUCTION_API_BASE) return PRODUCTION_API_BASE;
  if (!/^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/.test(override)) {
    console.error("asc-api: ASC_API_BASE must be the production host or a loopback address");
    return null;
  }
  return trimmed;
}

function base64url(input) {
  return Buffer.from(input).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ---------------------------------------------------------------------------
// CREDENTIAL RESOLUTION
// ---------------------------------------------------------------------------
// WHY THIS READS THE ENVIRONMENT, NOT A FILE (fixed 2026-10-02, AFC-359):
// .github/workflows/ios-ship.yml runs on a GitHub-hosted macos-latest runner,
// which has no home-directory secrets folder at all.  The credential reaches that
// runner as THREE ENVIRONMENT VARIABLES -- APPLE_API_KEY_ID,
// APPLE_API_ISSUER_ID and APPLE_API_KEY_P8_BASE64 -- exported into $GITHUB_ENV
// by .github/actions/infisical-secrets.  Reading only the file meant the key
// material could be present and correct while the client still refused to
// authenticate, and because asc_latest_seq() in ship-testflight.sh discarded
// this script's stderr, the resulting rc=2 was undiagnosable from the run log.
//
// APPLE_API_KEY_P8_BASE64 is base64, so it is decoded into a 0600 file inside a
// 0700 temp directory and unlinked on exit.  Values are never printed; only the
// source and the key-id LENGTH are logged.
const TEMP_KEY_DIRS = [];

function cleanupTempKeys() {
  while (TEMP_KEY_DIRS.length) {
    const dir = TEMP_KEY_DIRS.pop();
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}
process.on("exit", cleanupTempKeys);

// Accepts either a raw PEM (some callers store the .p8 body verbatim) or the
// base64 encoding GitHub Actions + Infisical use. Returns null when the input
// cannot be turned into a PEM, so the caller can fail with a real reason.
function decodeP8(b64) {
  const cleaned = String(b64 || "").trim();
  if (!cleaned) return null;
  if (cleaned.includes("-----BEGIN ")) return cleaned.endsWith("\n") ? cleaned : `${cleaned}\n`;
  let pem;
  try {
    pem = Buffer.from(cleaned, "base64").toString("utf8");
  } catch {
    return null;
  }
  return pem.includes("-----BEGIN ") ? pem : null;
}

function materializeP8(pem) {
  const dir = mkdtempSync(join(tmpdir(), "asc-key-"));
  try { chmodSync(dir, 0o700); } catch { /* best effort */ }
  const p = join(dir, "AuthKey.p8");
  writeFileSync(p, pem, { mode: 0o600 });
  TEMP_KEY_DIRS.push(dir);
  return p;
}

// Infisical Fleet-OPS through `fleet-secrets get` (AFC-359).  "" when absent.
// FLEET_SECRETS_BIN, then FLEET_SECRETS (what ship-testflight.sh reads and what
// the test suites set), override the default binary.  Values stay in memory.
function fleetSecretsGet(name, folder) {
  const bin = process.env.FLEET_SECRETS_BIN || process.env.FLEET_SECRETS || join(homedir(), ".local", "bin", "fleet-secrets");
  try {
    return execFileSync(bin, ["get", name, "--path", folder], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 30000
    }).replace(/\n$/, "");
  } catch {
    return "";
  }
}

// Normalizes a PEM private key and refuses anything that is not one.
//
// The check matters because the key arrives in the environment, and it ends up
// in the masked preview that a refused request prints.  A preview is only safe
// when the material behind it really is a private key.  The parse check lives
// in asc-key.mjs, which the shell layer uses as well, so both sides of the
// handoff accept exactly the same keys.
//
// Returns { keyId, issuerId, privateKeyPem, source } or { error } or { error: null }.
//
// The order is the rule: the environment beats the network, and a file is not
// a source at all.  A path on disk is not an approved secret source, so
// ASC_KEY_PATH is never read here; the shell layer that owns the credential
// reads a staged key and hands it over in the environment.
function resolveCredential() {
  const envKeyId = String(process.env.ASC_KEY_ID || "").trim();
  const envIssuer = String(process.env.ASC_ISSUER_ID || "").trim();
  const envKeyPem = String(process.env.ASC_KEY_P8 || "").trim();

  // 1) The APPLE_API_* trio the ship workflow exports from Infisical.  The
  //    key itself is in the environment, so it wins over every other source.
  const keyId = String(process.env.APPLE_API_KEY_ID || "").trim();
  const issuerId = String(process.env.APPLE_API_ISSUER_ID || "").trim();
  if (keyId && issuerId && process.env.APPLE_API_KEY_P8_BASE64) {
    const pem = decodeP8(process.env.APPLE_API_KEY_P8_BASE64);
    if (!pem) return { error: "APPLE_API_KEY_P8_BASE64 is set but did not decode to a PEM private key" };
    materializeP8(pem);
    return { keyId, issuerId, privateKeyPem: pem, source: "APPLE_API_* environment (base64 p8)" };
  }

  // 2) The same secret as a plain environment variable.  This is the form
  //    fleet-secrets hands out, and the form the shell layer uses when it
  //    hands a staged key to this client.
  if (envKeyId && envIssuer && envKeyPem) {
    const pem = normalizePrivateKey(envKeyPem);
    if (!pem) return { error: "ASC_KEY_P8 is set but is not a PEM private key" };
    return { keyId: envKeyId, issuerId: envIssuer, privateKeyPem: pem, source: "ASC_KEY_P8 environment" };
  }

  // 3) No file is read here (AFC-359, and Kody rule 42 on PR #271).  A path on
  //    disk is not an approved secret source, so ASC_KEY_PATH is not a
  //    credential source here:  the shell layer that owns the credential reads
  //    a staged key and exports it as ASC_KEY_P8.  Step 4 reads Infisical
  //    directly, so a local operator needs nothing exported at all.

  // 4) Infisical Fleet-OPS /asc: key id and issuer (unless the environment already
  //    has them) and the PEM as ASC_KEY_P8 when the key id is the /asc one;  another
  //    key id falls back to AUTHKEY_<KEY_ID> in /authkey-<key id lower case>-p8.
  //    Kept in memory, never written to disk.
  const infKeyId = envKeyId || fleetSecretsGet("ASC_KEY_ID", "/asc").trim();
  // The /asc issuer belongs to the /asc key.  Pairing it with another key's .p8
  // would sign a token for one key against another's issuer, so a non-/asc key
  // id fails closed unless the environment supplies its own issuer.
  const infIssuer = envIssuer || (infKeyId === fleetSecretsGet("ASC_KEY_ID", "/asc").trim() ? fleetSecretsGet("ASC_ISSUER_ID", "/asc").trim() : "");
  if (/^[A-Za-z0-9]+$/.test(infKeyId) && infIssuer) {
    let pem = "";
    if (infKeyId === fleetSecretsGet("ASC_KEY_ID", "/asc").trim()) pem = fleetSecretsGet("ASC_KEY_P8", "/asc");
    if (!pem) pem = fleetSecretsGet(`AUTHKEY_${infKeyId}`, `/authkey-${infKeyId.toLowerCase()}-p8`);
    if (pem) {
      if (!pem.endsWith("\n")) pem += "\n";
      return { keyId: infKeyId, issuerId: infIssuer, privateKeyPem: pem, source: "Infisical /asc" };
    }
  }

  return { error: null };
}

function signJwt({ keyId, issuerId, privateKeyPem }) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = { iss: issuerId, iat: now, exp: now + 1190, aud: "appstoreconnect-v1" };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signer = createSign("SHA256");
  signer.update(signingInput);
  signer.end();
  // ASC requires the JOSE (r||s) signature encoding, not DER.
  const signature = signer.sign({ key: privateKeyPem, dsaEncoding: "ieee-p1363" });
  const encodedSig = signature.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `${signingInput}.${encodedSig}`;
}

// ---------------------------------------------------------------------------
// TestFlight "What to Test" (betaBuildLocalizations.whatsNew)
// ---------------------------------------------------------------------------
// Every build of every fleet app shipped with this EMPTY (24 builds checked
// 2026-08-13; `GET /v1/builds/<id>/betaBuildLocalizations` returns `data: []`,
// i.e. the en-US row is ABSENT, not blank -- so this must CREATE, not only
// PATCH). /Users/jay/apps/AGENT-SYNC.md "App Versioning & TestFlight Build
// Policy" defines a mandatory template that nothing implemented.
//
// PUBLISHING SAFETY. This is the only step in the ship pipeline that writes
// owner-facing copy every TestFlight tester reads, generated from commit
// subjects nobody reviewed. So it is OPT-IN:
//   IOS_TF_RELEASE_NOTES=1      upload the rendered notes to App Store Connect
//   IOS_TF_RELEASE_NOTES=0      disabled entirely (render nothing)
//   unset / anything else       DRY RENDER: print the exact body, write nothing
// The default is the dry render, so the owner can read the real output of real
// ships before a single character reaches a tester. Flipping it to 1 is the
// owner's call, not an agent's.
//
// A hard deny-list assertion runs on the FULLY RENDERED body: if any internal
// agent name survives, the upload is skipped entirely rather than publishing a
// violation (AGENT-SYNC forbids agent names in release notes). Offending
// bullets are dropped whole -- never word-deleted in place, which yields
// mangled copy like "Fix:  lane".
const AGENT_NAMES = "grok|claude|monet|codex|antigravity|cursor|kimi|fable|gemini|deepseek|opus|sonnet|haiku";
// Bracketed agent markers, stripped ANYWHERE in the subject -- not only at
// position 0. The fleet's actual convention puts the tag at the END, e.g.
// "fix(ios): set App Category to Finance (#1030) [AG] (#1264)". Measured
// 2026-08-13: Congress.Trade has 48 subjects carrying a NON-leading [AG] and
// ZERO leading ones (Socratic.Trade: 2 and 2). An earlier version of this file
// stripped only /^\[[A-Za-z]+\]/ and left "AG" out of the deny-list below on
// the stated assumption that the strip covered it. It did not: every one of
// those 48 subjects would have published "[AG]" straight to TestFlight, which
// AGENT-SYNC's STRICT no-agent-names rule names explicitly.
const AGENT_MARKER = new RegExp(`\\[\\s*(?:ag|${AGENT_NAMES})\\s*\\]`, "gi");
// Bare "AG" stays OUT of the word-boundary deny-list -- as a naked token it
// fires on ordinary English and on tickers. The bracketed form is unambiguous,
// so the final rendered-body assertion tests for that form specifically.
const AGENT_NAME_DENY = new RegExp(`(?:\\b(?:${AGENT_NAMES})\\b|\\[\\s*ag\\s*\\])`, "i");

function centralTimestamp(now = new Date()) {
  // AGENT-SYNC template: "Wed, Aug 12, 2026 at 1:15am" -- the owner's clock
  // (America/Chicago, so DST is automatic), 12-hour, lower-case am or pm, and
  // NO timezone abbreviation.  Intl yields "1:15 PM" with a space or a narrow
  // no-break space (U+202F) before the meridiem, so fold both into "1:15pm".
  const d = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago",
    weekday: "short", month: "short", day: "numeric", year: "numeric"
  }).format(now);
  const t = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago",
    hour: "numeric", minute: "2-digit", hour12: true
  }).format(now).replace(/\s*([AP])M$/i, (_m, x) => `${x.toLowerCase()}m`);
  return `${d} at ${t}`;
}

function gitSubjects(repoRoot, prevSha) {
  // Returns { subjects, note }. Never throws: notes must not fail a ship.
  const run = (args) => execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 30000
  }).trim();
  try {
    if (prevSha) {
      let reachable = true;
      try { run(["merge-base", "--is-ancestor", prevSha, "HEAD"]); }
      catch { reachable = false; }
      if (!reachable) {
        // Shallow clone, force-push, or a squash-merge orphan. One deepen attempt.
        try { run(["fetch", "--deepen=200"]); } catch { /* offline is fine */ }
        try { run(["merge-base", "--is-ancestor", prevSha, "HEAD"]); reachable = true; }
        catch { reachable = false; }
      }
      if (reachable) {
        const out = run(["log", "--no-merges", "--format=%s", `${prevSha}..HEAD`]);
        return { subjects: out ? out.split("\n") : [], note: "" };
      }
      return {
        subjects: [run(["log", "-1", "--format=%s"])],
        note: `previous ship sha ${prevSha.slice(0, 10)} unreachable from HEAD; using HEAD subject only`
      };
    }
    return { subjects: [run(["log", "-1", "--format=%s"])], note: "no previous ship recorded; using HEAD subject only" };
  } catch (err) {
    return { subjects: [], note: `git unavailable (${err && err.message ? err.message.split("\n")[0] : err})` };
  }
}

function buildReleaseNotes({ marketing, displayName, title, subjects, iosPathPrefix, repoRoot, prevSha }) {
  // PR numbers are harvested only from bullets that SURVIVE filtering, so the
  // header line and the body describe the same set of changes.
  const prByBullet = new Map();
  const bullets = [];
  const seen = new Set();

  for (const raw of subjects) {
    let s = String(raw || "").trim();
    if (!s) continue;
    // 1. structured agent markers first, so a bracketed tag never survives as
    //    prose. AGENT_MARKER is global and unanchored because the fleet writes
    //    the tag at the END far more often than at the start.
    s = s.replace(AGENT_MARKER, " ")
         .replace(/^\[[A-Za-z]+\]\s*/, "")
         .replace(/\bAgent:\s*\S+\b/gi, "")
         .replace(/\bCo-Authored-By:.*$/gi, "");
    // 2. conventional-commit prefix
    s = s.replace(/^(feat|fix|chore|docs|refactor|perf|test|build|ci|style|revert)(\([^)]*\))?!?:\s*/i, "");
    // 3. harvest + strip the trailing PR ref; the numbers go in the header line
    const pr = s.match(/\s*\(#(\d+)\)\s*$/);
    let prNum = "";
    if (pr) {
      prNum = pr[1];
      s = s.replace(/\s*\(#\d+\)\s*$/, "");
    }
    s = s.replace(/\s+/g, " ").trim();
    if (!s) continue;
    // 4. noise
    if (/^(merge|bump|wip|revert)\b/i.test(s)) continue;
    if (s.length < 12) continue;
    // 5. agent names -> drop the whole bullet
    if (AGENT_NAME_DENY.test(s)) continue;
    s = s.charAt(0).toUpperCase() + s.slice(1);
    const key = s.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    if (prNum) prByBullet.set(s, prNum);
    bullets.push(s);
  }

  let kept = bullets;
  if (bullets.length > 10) {
    // Over the cap: prefer commits that touched this app's iOS tree, then backfill.
    let iosFirst = [];
    if (iosPathPrefix && repoRoot && prevSha) {
      try {
        const touched = execFileSync("git", [
          "-C", repoRoot, "log", "--no-merges", "--format=%s", `${prevSha}..HEAD`, "--", iosPathPrefix
        ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 30000 })
          .trim().toLowerCase();
        iosFirst = bullets.filter((b) => touched.includes(b.slice(0, 20).toLowerCase()));
      } catch { /* tie-break only */ }
    }
    kept = [...iosFirst, ...bullets.filter((b) => !iosFirst.includes(b))].slice(0, 10);
  }
  if (kept.length === 0) kept = ["Maintenance and reliability updates"];

  const LIMIT = 4000;
  const heading = `[${marketing || "unversioned"}] ${title || `${displayName || "App"} Update`}`;

  const render = (keptBullets) => {
    const prNumbers = [];
    for (const b of keptBullets) {
      const n = prByBullet.get(b);
      if (n && !prNumbers.includes(n)) prNumbers.push(n);
    }
    let released = `Released: ${centralTimestamp()}`;
    if (prNumbers.length === 1) released += ` · PR #${prNumbers[0]}`;
    else if (prNumbers.length > 1 && prNumbers.length <= 5) {
      released += ` · PRs ${prNumbers.map((n) => `#${n}`).join(", ")}`;
    } else if (prNumbers.length > 5) {
      released += ` · PRs ${prNumbers.slice(0, 5).map((n) => `#${n}`).join(", ")} +${prNumbers.length - 5} more`;
    }
    return `${heading}\n${released}\n\nWhat's New:\n`;
  };

  const header = render(kept);
  const lines = [];
  let used = header.length;
  for (const b of kept) {
    const line = `- ${b}`;
    if (used + line.length + 1 > LIMIT) break;   // truncate at a bullet boundary
    lines.push(line);
    used += line.length + 1;
  }
  if (lines.length === 0) lines.push("- Maintenance and reliability updates");
  return `${header}${lines.join("\n")}`;
}

// ---------------------------------------------------------------------------
// TestFlight tester groups (shared by ensure-standing-testers and ensure-tf-ready)
// ---------------------------------------------------------------------------
// WHY THIS EXISTS (found 2026-10-09, GH #1018): moving a fleet iOS app to a new
// bundle ID means a NEW App Store Connect app record, and a new record starts
// with no TestFlight groups at all.  The ship uploaded 14 VALID builds to
// app.botfleet.ios and every run was green, while the owner saw nothing: the
// legacy record had an internal group ("BotFleet Testers", all builds) and the
// new one had none, so no internal tester existed, and the external group's
// testers were never invited because no build had cleared Beta App Review.
// Internal testers are App Store Connect users; they need no review and get
// every build the moment it finishes processing, so the internal group is the
// path that must always exist.
//
// These helpers take the caller's `api(method, path, jsonBody)` so a test can
// drive them with a fake and so main() keeps one authenticated client.
export const INTERNAL_GROUP_NAME = "Internal Testers";

// A resource row is { id: <string>, attributes: <object>, ... }.  This client is
// dependency-free on purpose (the hosted ios-ship workflow runs it with plain
// `node` before any `pnpm install`, so `import "zod"` fails with
// ERR_MODULE_NOT_FOUND and breaks every ship; a test pins that), so the shape is
// checked by hand.  `String(x) === x` is true only for a string primitive, and the
// toString tag is "[object Object]" only for a plain object, so a malformed row is
// dropped here instead of crashing a caller that reads row.id or row.attributes.
const isAscRow = (row) =>
  Boolean(row) && String(row.id) === row.id && Object.prototype.toString.call(row.attributes) === "[object Object]";

const ascRows = (res) => (res && res.ok && Array.isArray(res.parsed?.data) ? res.parsed.data.filter(isAscRow) : []);

const ASC_ORIGIN = "https://api.appstoreconnect.apple.com/";
const ASC_MAX_PAGES = 50;

// Every row of a collection, following links.next.  Never returns a partial list
// as if it were whole: a failed page, a next link that leaves App Store Connect
// (the bearer token must not follow it), or more than ASC_MAX_PAGES pages all
// answer { ok: false }, and callers treat that as "unreadable".
export async function ascAllRows({ api, url }) {
  const rows = [];
  let next = url;
  for (let page = 0; page < ASC_MAX_PAGES && next; page++) {
    const res = await api("GET", next);
    if (!res.ok) return { ok: false, error: ascErrorText(res), rows: [] };
    rows.push(...ascRows(res));
    next = res.parsed?.links?.next || "";
    if (next && !next.startsWith(ASC_ORIGIN) && !next.startsWith("/")) {
      return { ok: false, error: "next link leaves App Store Connect", rows: [] };
    }
  }
  if (next) return { ok: false, error: `more than ${ASC_MAX_PAGES} pages`, rows: [] };
  return { ok: true, rows };
}

export function ascErrorText(res) {
  const e = (res?.parsed?.errors || [])[0] || {};
  return `HTTP ${res?.status} ${e.code || ""} ${e.detail || e.title || ""}`.trim();
}

export function maskEmail(email) {
  const [user, domain] = String(email).split("@");
  return `${String(user).slice(0, 1)}***@${domain}`;
}

// Put one email into one beta group.  Returns { ok, existing, res }.
//
// Tester records are PER APP on Apple's side: filter[email] on its own returns
// every record that email has across the team's apps, and adding another app's
// record to this app's group answers 409 STATE_ERROR "Tester(s) cannot be
// assigned" (seen live on 2026-10-09 for the owner's own address).  So:
//   - createFirst (the internal group path): POST /v1/betaTesters with the group
//     relationship.  For an existing address on THIS app Apple answers with that
//     app's own record, and for an App Store Connect user it makes an internal
//     tester.  Falls back to the lookup below if the create is refused.
//   - lookup: prefer a record already tied to this app (filter[apps]), then any
//     record with the address, then create.  filter[email] is an exact match, so
//     a tester stored with different letter case is missed and the create
//     answers 409; the case-insensitive search over the app's testers recovers it.
export async function addTesterToGroup({ api, appId, groupId, email, createFirst = false }) {
  const wanted = String(email).toLowerCase();
  const create = () => api("POST", "/v1/betaTesters", JSON.stringify({
    data: {
      type: "betaTesters",
      attributes: { email },
      relationships: { betaGroups: { data: [{ type: "betaGroups", id: groupId }] } }
    }
  }));
  if (createFirst) {
    const made = await create();
    if (made.ok) return { ok: true, existing: false, res: made };
  }
  const sameEmail = (t) => String(t.attributes?.email || "").toLowerCase() === wanted;
  let existing = ascRows(await api("GET", `/v1/betaTesters?filter[email]=${encodeURIComponent(email)}&filter[apps]=${appId}&limit=5`)).find(sameEmail);
  if (!existing) {
    existing = ascRows(await api("GET", `/v1/betaTesters?filter[email]=${encodeURIComponent(email)}&limit=5`)).find(sameEmail);
  }
  const addExisting = (tester) => api("POST", `/v1/betaGroups/${groupId}/relationships/betaTesters`,
    JSON.stringify({ data: [{ type: "betaTesters", id: tester.id }] }));
  const recoverFromCrossApp = async () => {
    const appTesters = await ascAllRows({ api, url: `/v1/betaTesters?filter[apps]=${appId}&limit=200&fields[betaTesters]=email` });
    const appScoped = appTesters.rows.find(sameEmail);
    if (!appScoped) return null;
    existing = appScoped;
    return addExisting(appScoped);
  };
  let res;
  if (existing) {
    res = await addExisting(existing);
    if (res.status === 409) {
      // The record we found is for another app; Apple refused to assign it.
      // Try the app-scoped lookup before giving up.
      const recovered = await recoverFromCrossApp();
      if (recovered) res = recovered;
    }
  } else {
    res = await create();
    if (res.status === 409) {
      const recovered = await recoverFromCrossApp();
      if (recovered) res = recovered;
    }
  }
  return { ok: Boolean(res.ok || res.status === 204), existing: Boolean(existing), res };
}

// How many testers can install every build of the app without Beta App Review:
// the members of internal groups that have access to all builds.  Never throws;
// { ok:false } means the count could not be read, which is not the same as zero.
export async function countInternalTesters({ api, appId }) {
  const groupsRes = await api("GET", `/v1/apps/${appId}/betaGroups?limit=200&fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds`);
  if (!groupsRes.ok) return { ok: false, error: ascErrorText(groupsRes), groups: 0, testers: 0 };
  const groups = ascRows(groupsRes).filter(
    (g) => g.attributes?.isInternalGroup === true && g.attributes?.hasAccessToAllBuilds === true
  );
  // One Set across ALL groups: a tester in two all-builds groups is one person.
  const seen = new Set();
  for (const g of groups) {
    const members = await ascAllRows({ api, url: `/v1/betaGroups/${g.id}/betaTesters?limit=200&fields[betaTesters]=email` });
    if (!members.ok) return { ok: false, error: members.error, groups: groups.length, testers: seen.size };
    for (const t of members.rows) seen.add(String(t.attributes?.email || "").toLowerCase());
  }
  return { ok: true, groups: groups.length, testers: seen.size };
}

// Make sure the app has an internal group with access to all builds, and that
// every standing email that is an App Store Connect user is in it.  Idempotent,
// ADD-ONLY (never removes a tester or a group), prints emails masked.  An
// existing all-builds internal group is reused whatever its name.  Emails that
// are not ASC users stay external-only: Apple refuses them in an internal group.
// Returns { groupId, created, added, alreadyIn, external, testers, warnings }.
export async function ensureInternalTesterGroup({ api, appId, emails, log, warn }) {
  const out = { groupId: null, created: false, added: 0, alreadyIn: 0, external: 0, testers: 0, warnings: 0 };
  const fail = (msg) => { out.warnings += 1; warn(msg); return out; };

  const groupsRes = await api("GET", `/v1/apps/${appId}/betaGroups?limit=200&fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds`);
  if (!groupsRes.ok) return fail(`internal group list failed (${ascErrorText(groupsRes)})`);
  let group = ascRows(groupsRes).find(
    (g) => g.attributes?.isInternalGroup === true && g.attributes?.hasAccessToAllBuilds === true
  );
  if (group) {
    log(`reusing internal group "${group.attributes?.name}" id=${group.id}`);
  } else {
    const created = await api("POST", "/v1/betaGroups", JSON.stringify({
      data: {
        type: "betaGroups",
        attributes: { name: INTERNAL_GROUP_NAME, isInternalGroup: true, hasAccessToAllBuilds: true, feedbackEnabled: true },
        relationships: { app: { data: { type: "apps", id: appId } } }
      }
    }));
    if (!created.ok) {
      return fail(`could not create internal group "${INTERNAL_GROUP_NAME}" (${ascErrorText(created)}); create it by hand in App Store Connect > TestFlight > Internal Testing`);
    }
    group = created.parsed.data;
    out.created = true;
    log(`created internal group "${INTERNAL_GROUP_NAME}" id=${group.id} (all builds)`);
  }
  out.groupId = group.id;

  // Internal testers must be App Store Connect users.  Read the team's users to
  // know which standing emails qualify; when the list is unreadable, try them
  // all and let Apple answer.  Paginate so teams with >200 users are not silently
  // truncated (GH #1018: the internal group must hold every ASC standing email).
  // A failure on ANY page (or an oversized list) makes the list incomplete, so it
  // reads as unreadable (try every standing email), never as "everyone else is
  // not a user".
  const users = await ascAllRows({ api, url: "/v1/users?limit=200&fields[users]=username" });
  const usersReadable = users.ok;
  const ascUsers = new Set(users.rows.map((u) => String(u.attributes?.username || "").toLowerCase()));
  if (!usersReadable) log(`could not read App Store Connect users; trying every standing email`);

  const members = await ascAllRows({ api, url: `/v1/betaGroups/${group.id}/betaTesters?limit=200&fields[betaTesters]=email` });
  if (!members.ok) return fail(`could not list testers in internal group (${members.error}); not re-adding anyone`);
  const inGroup = new Set(members.rows.map((t) => String(t.attributes?.email || "").toLowerCase()));

  for (const email of emails) {
    const key = email.toLowerCase();
    if (inGroup.has(key)) {
      out.alreadyIn += 1;
      log(`${maskEmail(email)} already in internal group`);
      continue;
    }
    if (usersReadable && !ascUsers.has(key)) {
      out.external += 1;
      log(`${maskEmail(email)} is not an App Store Connect user; external group only`);
      continue;
    }
    const added = await addTesterToGroup({ api, appId, groupId: group.id, email, createFirst: true });
    if (added.ok) {
      out.added += 1;
      inGroup.add(key);
      log(`added ${maskEmail(email)} to internal group`);
    } else {
      fail(`could not add ${maskEmail(email)} to internal group (${ascErrorText(added.res)})`);
    }
  }
  out.testers = inGroup.size;
  if (out.testers === 0) {
    fail("the internal group has no tester: none of the standing emails is an App Store Connect user, so nobody can install builds without Beta App Review.  Add an App Store Connect user to ASC_STANDING_TESTERS or to TestFlight > Internal Testing by hand");
  }
  return out;
}

async function setWhatToTest({ api, buildId, appId, marketing }) {
  const mode = process.env.IOS_TF_RELEASE_NOTES;
  if (mode === "0") {
    console.error("release-notes: disabled (IOS_TF_RELEASE_NOTES=0)");
    return;
  }
  const repoRoot = process.env.IOS_TF_NOTES_REPO || "";
  const prevSha = process.env.IOS_TF_NOTES_PREV_SHA || "";
  const displayName = process.env.IOS_TF_NOTES_APP || "";
  const title = process.env.IOS_TF_RELEASE_TITLE || "";
  const iosPathPrefix = process.env.IOS_TF_NOTES_IOS_PREFIX || "";
  if (!repoRoot) {
    console.error("release-notes: IOS_TF_NOTES_REPO not set; skipping");
    return;
  }

  const { subjects, note } = gitSubjects(repoRoot, prevSha);
  if (note) console.error(`release-notes: ${note}`);
  const bodyText = buildReleaseNotes({
    marketing, displayName, title, subjects, iosPathPrefix, repoRoot, prevSha
  });

  console.error("release-notes: rendered body follows");
  for (const line of bodyText.split("\n")) console.error(`release-notes:   ${line}`);

  // Final assertion on the FULLY RENDERED body. Skip the upload rather than
  // publish a violation; never fail the ship over it.
  if (AGENT_NAME_DENY.test(bodyText)) {
    console.error("release-notes: ERROR - an internal agent name survived into the rendered body; NOT uploading");
    return;
  }

  if (mode !== "1") {
    console.error("release-notes: DRY RENDER only (set IOS_TF_RELEASE_NOTES=1 to publish this to TestFlight)");
    return;
  }

  const existing = await api("GET", `/v1/builds/${buildId}/betaBuildLocalizations`);
  if (!existing.ok) {
    console.error(`release-notes: could not read localizations (HTTP ${existing.status}); skipping`);
    return;
  }
  const enUs = (existing.parsed.data || []).find((x) => x.attributes?.locale === "en-US");
  if (enUs) {
    const res = await api("PATCH", `/v1/betaBuildLocalizations/${enUs.id}`, JSON.stringify({
      data: { type: "betaBuildLocalizations", id: enUs.id, attributes: { whatsNew: bodyText } }
    }));
    console.error(res.ok
      ? `release-notes: updated en-US What to Test (${bodyText.length} chars)`
      : `release-notes: PATCH failed HTTP ${res.status}`);
    return;
  }
  // No row exists yet -- CREATE it. This POST shape was NOT verified against a
  // live write (no ASC write was performed while implementing this); treat the
  // first real run as the verification, and read the printed HTTP status.
  let res = await api("POST", "/v1/betaBuildLocalizations", JSON.stringify({
    data: {
      type: "betaBuildLocalizations",
      attributes: { locale: "en-US", whatsNew: bodyText },
      relationships: { build: { data: { type: "builds", id: buildId } } }
    }
  }));
  if (!res.ok && appId) {
    // Some apps are not localized to en-US; fall back to a locale the app has.
    const locales = await api("GET", `/v1/apps/${appId}/betaAppLocalizations`);
    const alt = (locales.parsed?.data || [])[0]?.attributes?.locale;
    if (alt && alt !== "en-US") {
      console.error(`release-notes: en-US rejected (HTTP ${res.status}); retrying with ${alt}`);
      res = await api("POST", "/v1/betaBuildLocalizations", JSON.stringify({
        data: {
          type: "betaBuildLocalizations",
          attributes: { locale: alt, whatsNew: bodyText },
          relationships: { build: { data: { type: "builds", id: buildId } } }
        }
      }));
    }
  }
  console.error(res.ok
    ? `release-notes: created What to Test (${bodyText.length} chars)`
    : `release-notes: POST failed HTTP ${res.status}`);
}

async function main() {
  const apiBase = resolveApiBase();
  if (!apiBase) {
    process.exitCode = 2;
    return;
  }
  const cred = resolveCredential();
  if (cred.error) {
    console.error(`asc-auth: ${cred.error}`);
    process.exit(1);
  }
  if (!cred.privateKeyPem) {
    console.error(
      "asc-auth: no App Store Connect credential found. Tried, in order:\n" +
      "  1) APPLE_API_KEY_ID / APPLE_API_ISSUER_ID / APPLE_API_KEY_P8_BASE64 in the environment\n" +
      "  2) ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 in the environment\n" +
      "  3) Fleet-OPS prod /asc through fleet-secrets\n" +
      "  A path in ASC_KEY_PATH is not a credential source:  the shell layer that owns the\n" +
      "  credential hands the key over in ASC_KEY_P8"
    );
    process.exit(1);
  }
  console.error(`asc-auth: using ${cred.source} (key id length ${cred.keyId.length})`);
  // The key id and the private key stay in scope for the whole of main(), so
  // the diagnostic helper can name the credential that was refused.
  const { keyId, issuerId, privateKeyPem } = cred;
  const token = signJwt({ keyId, issuerId, privateKeyPem });

  const [method, path, body, arg4, arg5] = process.argv.slice(2);
  if (!method || !path) {
    console.error("Usage: node asc-api.mjs <METHOD> <PATH> [JSON_BODY]");
    console.error("       node asc-api.mjs ensure-tf-ready <bundleId> <buildVersion> [marketingVersion] [appleId]");
    console.error("       node asc-api.mjs ensure-appstore-profiles <path-to-appstore-profiles.json>");
    console.error("       node asc-api.mjs ensure-standing-testers <appleId> [buildVersion]   (emails from ASC_STANDING_TESTERS)");
    console.error("       node asc-api.mjs latest-build-seq <bundleId> <prefix> [platform] [appleId]");
    console.error("       node asc-api.mjs upload-screenshots <localizationId> <displayType|auto> <file...>");
    console.error("       node asc-api.mjs submit-review <versionId> [reviewSubmissionId] [platform]");
    // The exit code is set rather than the process ended, so a diagnostic
    // written to a pipe is flushed instead of dropped.
    process.exitCode = 1;
    return;
  }

  // How long a single App Store Connect call may take.  Node's fetch has no
  // default timeout, so a call that never answers would hang the script with
  // the reservation still pending in App Store Connect.
  //
  // The value is overridable so a test can drive a real timeout without
  // waiting two minutes for one.
  const REQUEST_TIMEOUT_MS = (() => {
    const raw = process.env.ASC_REQUEST_TIMEOUT_MS;
    const n = raw ? Number.parseInt(raw, 10) : Number.NaN;
    if (!Number.isFinite(n) || n <= 0) return 120_000;
    // AbortSignal.timeout does not accept a delay above 2^31-1: it either
    // throws a RangeError or silently rounds the delay down, so an
    // unclamped override would abort every request immediately.
    return Math.min(n, 2_147_483_647);
  })();

  // Describe a failed response without ever printing what it holds.
  //
  // The raw body of an App Store Connect error is not printed: it is
  // whatever the service chose to say, and it may echo a header or a token.
  // Only the titles and details of the JSON API errors are used, and a run of
  // token-like characters in one of those is redacted.
  //
  // A rejected key is reported with the fleet's masked preview of the key in
  // play and the key id beside it, so the operator can tell which credential
  // was refused without any of the key being published.  The preview is taken
  // from the key material rather than from the envelope, because every key
  // file opens and ends the same way and a preview of the envelope would
  // identify none of them.
  function describeError(res) {
    if (res.networkError) {
      // A timeout and a transport failure have different causes, and the
      // operator needs the one that is true:  one means App Store Connect was
      // slow, the other that the request never got there.
      return res.timedOut
        ? "the request timed out before App Store Connect answered"
        : "the request never reached App Store Connect";
    }
    if (res.status === 401 || res.status === 403) {
      // The key id is a public identifier:  it travels in the header of every
      // request to App Store Connect.  Together with the fleet's masked
      // preview of the key in play it says which credential was rejected,
      // which is the question an operator actually has, without publishing
      // any of the key.
      return `App Store Connect rejected the key: check ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 in Fleet-OPS prod /asc (key id ${keyId}, key in play ${maskKeyPreview(privateKeyPem)})`;
    }
    const parts = [];
    const errors = res.parsed && Array.isArray(res.parsed.errors) ? res.parsed.errors : [];
    for (const problem of errors.slice(0, 3)) {
      // The errors array comes from the service, so an element may be null or
      // a bare string.  Reading .title off one of those throws, which would
      // replace the safe message this function exists to produce with a stack
      // trace, so the shape is checked before anything is read.
      const title = isPlainObject(problem) && typeof problem.title === "string" ? problem.title : "unknown error";
      const detail = isPlainObject(problem) && typeof problem.detail === "string" ? problem.detail : "";
      parts.push(detail ? `${title}: ${detail}` : title);
    }
    if (parts.length === 0) {
      parts.push("no JSON API error detail was returned");
    }
    return parts
      .map((part) => part.replace(/[A-Za-z0-9._~+/=-]{24,}/g, "[redacted]"))
      .join("; ");
  }

  // The blockers App Store Connect names when a version cannot be reviewed.
  //
  // The refusal on the review submission item carries a `meta.associatedErrors`
  // member:  a map from the resource that is not ready to the list of state
  // errors on it.  Each entry carries a code, a title and a detail, and the
  // code is the part an operator can act on, so both the resource and the
  // code are printed.  The shape is checked before anything is read, because
  // a refusal is a document from the service and its members are not
  // guaranteed.
  function describeAssociatedErrors(res) {
    const errors = res && res.parsed && Array.isArray(res.parsed.errors) ? res.parsed.errors : [];
    const lines = [];
    for (const problem of errors) {
      if (!isPlainObject(problem)) continue;
      const meta = isPlainObject(problem.meta) ? problem.meta : null;
      if (!meta || !isPlainObject(meta.associatedErrors)) continue;
      for (const [resource, list] of Object.entries(meta.associatedErrors)) {
        if (!Array.isArray(list)) continue;
        for (const item of list) {
          if (!isPlainObject(item)) continue;
          const code = typeof item.code === "string" ? item.code : "unknown error";
          const title = typeof item.title === "string" ? item.title : "";
          lines.push(`${resource} -> ${code}${title ? ` (${title})` : ""}`);
        }
      }
    }
    return lines;
  }

  // Guard the shape of a response before any of it is read.
  //
  // The scripts in this directory are dependency-free, so the guard is
  // written out by hand rather than pulled in as a schema library.
  //
  // A guard cannot return from main() on its own, so it throws a named
  // failure instead: the caller unwinds to main()'s handler, which prints the
  // message and keeps the exit code the guard set.
  function isPlainObject(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  function requireObject(value, what) {
    if (!isPlainObject(value)) {
      process.exitCode = 2;
      throw new NamedFailure(`${method}: invalid ${what} response`);
    }
    return value;
  }

  function requireArray(value, what) {
    if (!Array.isArray(value)) {
      process.exitCode = 2;
      throw new NamedFailure(`${method}: invalid ${what} response`);
    }
    return value;
  }

  // Every call is aborted after REQUEST_TIMEOUT_MS, so a call that never
  // answers rejects with a TimeoutError rather than hanging.  That rejection
  // is turned into an ordinary non-ok response here rather than at each call
  // site: the commit path in particular has to reach its discardReservation()
  // on a timeout, and an escaping exception would skip it and leave the
  // reservation open in a ten-entry set.
  async function api(methodName, apiPath, jsonBody) {
    const url = apiPath.startsWith("http") ? apiPath : `${apiBase}${apiPath}`;
    let res;
    try {
      res = await fetch(url, {
        method: methodName,
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json"
        },
        body: jsonBody ? jsonBody : undefined,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
      });
    } catch (error) {
      const timedOut = error && error.name === "TimeoutError";
      return {
        status: 0,
        ok: false,
        // The request never reached App Store Connect.  A caller that only
        // looks at the status would read this as a server verdict, so the
        // transport failure is marked and reported as one.
        networkError: true,
        // A timeout and a refused connection are different causes, and the
        // message has to name the one that happened.
        timedOut: Boolean(timedOut),
        text: "",
        parsed: {
          errors: [{
            title: timedOut ? "the request timed out" : "the request failed",
            detail: error && error.message ? error.message : "unknown error"
          }]
        }
      };
    }
    const text = await res.text();
    let parsed;
    try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
    return { status: res.status, ok: res.ok, parsed, text };
  }

  // Drop a reservation that will never be committed.
  //
  // A screenshot set holds ten entries, so a reservation that is left open
  // after a failed upload sits in the set forever and pushes the real
  // screenshots out of it.  The delete is best effort: the script still
  // reports the original failure, but it says whether the entry went away
  // so a later run knows to look for it.
  //
  // Every caller has to await this before it exits the process: a pending
  // fetch is cancelled by the exit, and the reservation would survive.
  async function discardReservation(screenshotId) {
    try {
      const dropped = await api("DELETE", `/v1/appScreenshots/${screenshotId}`);
      if (dropped.ok) {
        console.error(`upload-screenshots: dropped the reservation ${screenshotId}`);
        return true;
      }
      console.error(`upload-screenshots: the reservation ${screenshotId} is still open (HTTP ${dropped.status}): ${describeError(dropped)}`);
      return false;
    } catch (error) {
      const reason = error && error.name === "TimeoutError"
        ? "the delete timed out"
        : `the delete failed (${error && error.message ? error.message : "unknown error"})`;
      console.error(`upload-screenshots: the reservation ${screenshotId} is still open: ${reason}`);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Submit an app store version for review
  // -------------------------------------------------------------------------
  // Usage: node asc-api.mjs submit-review <versionId> [reviewSubmissionId] [platform]
  //
  // Submitting is the one call that cannot be undone, so the things that
  // have to be true first are checked here rather than discovered from
  // Apple's refusal:
  //
  //   1. the version's screenshots are uploaded (a version with no
  //      screenshots is not submittable, and the binding call refuses with
  //      the list of what is missing)
  //   2. a build is attached to the version
  //   3. the version's versionString matches that build's marketing version
  //
  // The version is attached to the review submission here, because App Store
  // Connect never attaches it by itself.  The items relationship on the
  // submission allows GET_RELATED and GET_RELATIONSHIP only, so it can be
  // read but never written:  the binding is a resource of its own, a review
  // submission item.  Without that step the command can never work from a
  // clean account, because a fresh version is bound to nothing.
  //
  // When the version is not yet reviewable, the binding call is refused with
  // a 409 whose body names every blocker, one entry per resource.  That list
  // is the most useful thing this command can print, so it is reported
  // rather than swallowed.
  if (method === "submit-review") {
    const versionId = path;
    const submissionId = body;
    //  The platform the operator asked for by name, and the platform in play.
    //  They are not the same thing:  a platform that was not asked for is
    //  this command's default, and the default must never rewrite a
    //  submission somebody else prepared for another platform.
    const platformRequested = typeof arg4 === "string" && arg4.length > 0;
    const platform = arg4 || "IOS";
    if (!versionId) {
      console.error("Usage: node asc-api.mjs submit-review <versionId> [reviewSubmissionId] [platform]");
      process.exitCode = 2;
      return;
    }
    if (!/^(IOS|MAC_OS)$/.test(platform)) {
      console.error(`submit-review: ${platform} is not a review platform; use IOS or MAC_OS`);
      process.exitCode = 2;
      return;
    }

    // 1. The screenshots.
    //
    //  The counts are kept per display type, not pooled:  App Store Connect
    //  wants a screenshot for every device family the app runs on, so three
    //  iPhone images and an empty iPad set would pass a total of six and
    //  still be refused.  A set that could not be read is a failure, not an
    //  absent set:  treating it as absent would let an irreversible
    //  submission go out on a read that never happened.
    const localizations = await api("GET", `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations`);
    if (!localizations.ok) {
      console.error(`submit-review: ${describeError(localizations)}`);
      process.exitCode = 2;
      return;
    }
    const locs = requireArray(localizations.parsed?.data, "version localization list");
    const byDisplayType = new Map();
    const locDisplayTypes = new Map();
    for (const loc of locs) {
      if (!isPlainObject(loc) || typeof loc.id !== "string") continue;
      const sets = await api("GET", `/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`);
      if (!sets.ok) {
        console.error(`submit-review: ${describeError(sets)}`);
        process.exitCode = 2;
        return;
      }
      const typesHere = new Set();
      for (const set of requireArray(sets.parsed?.data, "screenshot set list")) {
        const displayType = isPlainObject(set) ? set.attributes?.screenshotDisplayType : null;
        const count = isPlainObject(set) ? set.attributes?.screenshotCount : null;
        if (typeof displayType !== "string" || typeof count !== "number") continue;
        byDisplayType.set(displayType, (byDisplayType.get(displayType) || 0) + count);
        if (count > 0) typesHere.add(displayType);
      }
      //  The locale is what the operator fixes, so the refusal names it
      //  alongside the resource id;  the id alone is the fallback.
      const locale = isPlainObject(loc.attributes) && typeof loc.attributes.locale === "string"
        ? `${loc.attributes.locale} (${loc.id})`
        : loc.id;
      if (typesHere.size > 0) locDisplayTypes.set(locale, typesHere);
    }
    const breakdown = [...byDisplayType.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([type, count]) => `${type} ${count}`)
      .join(", ");
    console.error(`submit-review: screenshots by display type: ${breakdown || "none"}`);
    //  The requirement is counted per device family, and a set that exists
    //  but holds nothing does not count:  an empty iPad set is the case a
    //  pooled total lets through.
    const familyCounts = new Map();
    for (const [type, count] of byDisplayType) {
      const family = DISPLAY_TYPE_FAMILY[type];
      if (!family) continue;
      familyCounts.set(family, (familyCounts.get(family) || 0) + count);
    }
    const missing = (platform === "MAC_OS"
      ? REQUIRED_SCREENSHOT_FAMILIES_MAC
      : REQUIRED_SCREENSHOT_FAMILIES).filter(
      (family) => (familyCounts.get(family) || 0) < 1
    );
    if (missing.length > 0) {
      console.error(
        `submit-review: not submitting, the version has no screenshot for ${missing.join(" and ")}`
      );
      process.exitCode = 2;
      return;
    }
    //  The named display types, for the same reason the families are checked
    //  and one step finer.  The iPad family has two members and only the
    //  13-inch one is the profile App Store Connect requires, so a version
    //  carrying the 12.9-inch set alone is short of it even though its
    //  family count is satisfied.
    if (platform !== "MAC_OS") {
      const missingTypes = REQUIRED_SCREENSHOT_DISPLAY_TYPES_IOS.filter(
        (type) => (byDisplayType.get(type) || 0) < 1
      );
      if (missingTypes.length > 0) {
        console.error(
          `submit-review: not submitting, the version has no screenshot for the required display type ${missingTypes.join(" and ")}`
        );
        process.exitCode = 2;
        return;
      }
      //  The same requirement per localization, because App Store Connect
      //  validates screenshots per localization:  a version whose 13-inch
      //  set exists only for en-US passes the pooled count above and is
      //  still refused for every other locale.  A localization carrying no
      //  screenshot set at all falls back to the primary locale, so only
      //  localizations that carry at least one set are judged.
      const localesMissing = [];
      for (const [locId, typesHere] of locDisplayTypes) {
        const missingForLoc = REQUIRED_SCREENSHOT_DISPLAY_TYPES_IOS.filter((type) => !typesHere.has(type));
        if (missingForLoc.length > 0) {
          localesMissing.push(
            `localization ${locId} has no screenshot for the required display type ${missingForLoc.join(" and ")}`
          );
        }
      }
      if (localesMissing.length > 0) {
        console.error(`submit-review: not submitting, ${localesMissing.join("; ")}`);
        process.exitCode = 2;
        return;
      }
    }

    // 2. The build.
    const attached = await api("GET", `/v1/appStoreVersions/${versionId}/build`);
    if (!attached.ok) {
      console.error(`submit-review: ${describeError(attached)}`);
      process.exitCode = 2;
      return;
    }
    const build = attached.parsed?.data;
    if (!isPlainObject(build) || typeof build.id !== "string") {
      console.error("submit-review: not submitting, no build is attached to the version");
      process.exitCode = 2;
      return;
    }

    // 3. The version string, and the build's own marketing version.
    //
    // App Store Connect pairs a build with a version by their marketing
    // version, so a version whose versionString is still the one from the
    // previous build is refused.  That is a cheap mistake to make and an
    // expensive one to find out about from Apple, so it is checked here.
    const version = await api("GET", `/v1/appStoreVersions/${versionId}`);
    if (!version.ok) {
      console.error(`submit-review: ${describeError(version)}`);
      process.exitCode = 2;
      return;
    }
    const versionString = version.parsed?.data?.attributes?.versionString;
    const appId = version.parsed?.data?.relationships?.app?.data?.id;
    const buildVersion = build.attributes?.version;
    console.error(`submit-review: version ${versionString} | build ${buildVersion} (${build.id})`);
    if (typeof versionString !== "string" || versionString.length === 0) {
      console.error("submit-review: not submitting, the version has no versionString");
      process.exitCode = 2;
      return;
    }

    const withPreRelease = await api("GET", `/v1/builds/${build.id}?include=preReleaseVersion`);
    if (!withPreRelease.ok) {
      //  A read that failed is not an absent pre-release version:  treating
      //  it as absent would let an irreversible submission go out on a check
      //  that never ran, and it would swallow the one failure that matters
      //  most here, a rejected key.
      console.error(`submit-review: ${describeError(withPreRelease)}`);
      process.exitCode = 2;
      return;
    }
    const included = withPreRelease.parsed?.included;
    const preReleaseId = withPreRelease.parsed?.data?.relationships?.preReleaseVersion?.data?.id;
    const hasPreRelease = typeof preReleaseId === "string" && preReleaseId.length > 0;
    //  A build with no pre-release version carries no include:  JSON:API
    //  leaves the member out rather than sending an empty list, and there is
    //  nothing to compare in that case.  An include that is missing while the
    //  build names one is a read that could not be understood.
    if (hasPreRelease && !Array.isArray(included)) {
      console.error(
        `submit-review: not submitting, the build names pre-release ${preReleaseId} and the read returns no include for it`
      );
      process.exitCode = 2;
      return;
    }
    const preRelease = hasPreRelease
      ? included.find((item) => isPlainObject(item) && item.id === preReleaseId)
      : null;
    //  The marketing version lives on the pre-release version as `version`.
    //  That is not a guess:  the live API answers
    //  GET /v1/builds/<id>?include=preReleaseVersion with
    //  included[].attributes.version = "1.0.235" and no `versionString` on
    //  that resource at all.  `versionString` is the field of an
    //  appStoreVersion, which is where the version's own name is read above.
    const marketing = preRelease && isPlainObject(preRelease.attributes)
      ? preRelease.attributes.version
      : null;
    //  A build that names a pre-release version but whose marketing version
    //  cannot be read is not a build with nothing to compare:  it is a
    //  comparison that did not happen, and letting the submission through
    //  would skip the one check that pairs the version with the build.
    if (hasPreRelease && (typeof marketing !== "string" || marketing.length === 0)) {
      console.error(
        `submit-review: not submitting, the build names pre-release ${preReleaseId} but its marketing version could not be read`
      );
      process.exitCode = 2;
      return;
    }
    if (typeof marketing === "string" && marketing.length > 0 && marketing !== versionString) {
      console.error(
        `submit-review: not submitting, the version says ${versionString} and the build says ${marketing}. ` +
        "Set the version's versionString to the build's marketing version first."
      );
      process.exitCode = 2;
      return;
    }

    // The review submission.
    //
    // The version is bound to a submission by a review submission item, a
    // resource of its own.  The items relationship on the submission allows
    // GET_RELATED and GET_RELATIONSHIP only, so it can be read but never
    // written, and a version that no item names is bound to nothing.  So the
    // binding is made here, which is what lets this command work from a
    // clean account instead of only against a version somebody else prepared.
    //
    // A submission already bound to a different version is left alone:  one
    // submission carries one version, and a second one cannot be added to
    // it.  A submission bound to nothing is the one that gets this version.
    const blockers = [];
    let candidates = [];
    //  The platform every candidate carries, so the platform can be checked
    //  against the one in play before the irreversible call goes out.
    const candidatePlatforms = new Map();
    if (submissionId) {
      candidates = [submissionId];
      //  A named submission is taken as given, but two things about it still
      //  have to be checked:  a submission that was already sent cannot be
      //  sent again, and its platform has to be the one asked for, because a
      //  macOS submission for an iOS version would send the wrong build to
      //  review.
      //
      //  The platform is NOT set here.  The binding is read first, because a
      //  submission that holds another version is left alone, and a
      //  submission that is left alone must not be mutated either.
      const named = await api("GET", `/v1/reviewSubmissions/${submissionId}`);
      if (!named.ok) {
        console.error(`submit-review: ${describeError(named)}`);
        process.exitCode = 2;
        return;
      }
      const namedAttributes = isPlainObject(named.parsed?.data?.attributes)
        ? named.parsed.data.attributes
        : null;
      if (!namedAttributes) {
        console.error("submit-review: the review submission came back without readable attributes");
        process.exitCode = 2;
        return;
      }
      if (namedAttributes.submittedDate !== null && namedAttributes.submittedDate !== undefined) {
        console.error("submit-review: not submitting, the review submission was already submitted");
        process.exitCode = 2;
        return;
      }
      candidatePlatforms.set(
        submissionId,
        typeof namedAttributes.platform === "string" ? namedAttributes.platform : null
      );
    } else {
      if (typeof appId !== "string" || appId.length === 0) {
        console.error("submit-review: not submitting, the version names no app");
        process.exitCode = 2;
        return;
      }
      const listed = await api("GET", `/v1/apps/${appId}/reviewSubmissions`);
      if (!listed.ok) {
        console.error(`submit-review: ${describeError(listed)}`);
        process.exitCode = 2;
        return;
      }
      candidates = requireArray(listed.parsed?.data, "review submission list")
        .filter((s) => isPlainObject(s) && typeof s.id === "string")
        .filter((s) => {
          const attributes = isPlainObject(s.attributes) ? s.attributes : {};
          //  A submission that was already sent cannot be sent again.
          if (attributes.submittedDate !== null && attributes.submittedDate !== undefined) return false;
          //  A submission for another platform would put the wrong build in
          //  review, so it is not a candidate.  A submission with no platform
          //  at all is a candidate:  the platform is set on it and read back
          //  before the irreversible call, so it never goes to review with
          //  the wrong platform.
          return typeof attributes.platform !== "string" || attributes.platform === platform;
        })
        .map((s) => {
          const attributes = isPlainObject(s.attributes) ? s.attributes : {};
          candidatePlatforms.set(
            s.id,
            typeof attributes.platform === "string" ? attributes.platform : null
          );
          return s.id;
        });
    }
    if (candidates.length === 0) {
      //  The app has no draft submission at all, so one is made.  The
      //  platform goes on it at create time, which is the shape App Store
      //  Connect accepts:  items and submitted are both refused on create.
      if (typeof appId !== "string" || appId.length === 0) {
        console.error("submit-review: not submitting, the version names no app");
        process.exitCode = 2;
        return;
      }
      const created = await api("POST", "/v1/reviewSubmissions", JSON.stringify({
        data: {
          type: "reviewSubmissions",
          attributes: { platform },
          relationships: { app: { data: { type: "apps", id: appId } } }
        }
      }));
      if (!created.ok) {
        console.error(`submit-review: ${describeError(created)}`);
        process.exitCode = 2;
        return;
      }
      const createdId = created.parsed?.data?.id;
      if (typeof createdId !== "string" || createdId.length === 0) {
        console.error("submit-review: the review submission was created but came back without an id");
        process.exitCode = 2;
        return;
      }
      candidates = [createdId];
      //  The platform went on it at create time, so it does not have to be
      //  set again.  A response that does not echo a platform is recorded as
      //  carrying none:  recording the platform that was asked for would make
      //  the platform check pass, and the submission would go to review with a
      //  platform that was never proven.
      const createdPlatform = isPlainObject(created.parsed?.data?.attributes)
        ? created.parsed.data.attributes.platform
        : null;
      candidatePlatforms.set(createdId, typeof createdPlatform === "string" ? createdPlatform : null);
    }

    // Is this submission bound to the version?
    //
    // The item's own id is the review submission item's id, not the
    // version's:  the version is named in the item's relationship.  Reading
    // the item's id as the version's would never match, so the check has to
    // follow the relationship.
    const boundVersionOf = (item) => {
      if (!isPlainObject(item)) return null;
      const relationships = isPlainObject(item.relationships) ? item.relationships : null;
      if (!relationships) return null;
      const related = isPlainObject(relationships.appStoreVersion) ? relationships.appStoreVersion : null;
      if (!related) return null;
      const data = isPlainObject(related.data) ? related.data : null;
      return data && typeof data.id === "string" ? data.id : null;
    };

    let submitted = null;
    //  Whether the submit was ever attempted.  A refusal of the submit and a
    //  run that never sent one are different failures, and the final report
    //  has to say which one happened.
    let submitAttempted = false;
    const boundElsewhere = [];
    //  The submission this run bound the version to.  A binding cannot be
    //  undone from this tool, and one version lives on one submission, so
    //  every path that leaves the version bound and the submission unsent
    //  says so and stops the run.
    let boundSubmission = null;
    const reportBound = () => {
      console.error(
        `submit-review: the version ${versionId} is bound to review submission ${boundSubmission}, ` +
        "which was not submitted.  The binding cannot be undone from here:  clear it in App Store Connect " +
        "before the next run."
      );
    };
    for (const candidate of candidates) {
      const items = await api("GET", `/v1/reviewSubmissions/${candidate}/items`);
      if (!items.ok) {
        console.error(`submit-review: ${candidate}: ${describeError(items)}`);
        continue;
      }
      const list = requireArray(items.parsed?.data, "review submission item list");
      const boundTo = list.map(boundVersionOf).filter(Boolean);
      if (boundTo.length > 0 && !boundTo.includes(versionId)) {
        boundElsewhere.push(`${candidate} -> ${boundTo.join(", ")}`);
        console.error(
          `submit-review: ${candidate} is bound to ${boundTo.join(", ")}; skipping it`
        );
        continue;
      }
      //  The platform is checked before anything is written:  a submission
      //  that carries another platform is never rewritten to one the operator
      //  did not ask for, and this refusal mutates nothing.  The platform is
      //  set and read back below, before the binding, so that a platform
      //  that cannot be proven stops the run with the version still unbound.
      const candidatePlatform = candidatePlatforms.has(candidate)
        ? candidatePlatforms.get(candidate)
        : null;
      if (candidatePlatform !== platform && !platformRequested && typeof candidatePlatform === "string") {
        console.error(
          `submit-review: not submitting, the review submission ${candidate} is for ${candidatePlatform} ` +
          "and no platform was requested.  Name the platform to submit it."
        );
        process.exitCode = 2;
        return;
      }
      //  The platform is set and read back BEFORE the binding, so the
      //  platform is proven before any write that cannot be undone.  A
      //  platform that cannot be set, or that is not there when it is read
      //  back, stops the run with the version still unbound, so there is
      //  nothing for the operator to clear by hand.
      if (candidatePlatform !== platform) {
        const setPlatform = await api("PATCH", `/v1/reviewSubmissions/${candidate}`, JSON.stringify({
          data: {
            type: "reviewSubmissions",
            id: candidate,
            attributes: { platform }
          }
        }));
        if (!setPlatform.ok) {
          console.error(`submit-review: the platform could not be set: ${describeError(setPlatform)}`);
          //  The binding has not happened yet, so the version is on no
          //  submission and nothing has to be cleared by hand.
          console.error("submit-review: the version was not bound and nothing was submitted");
          process.exitCode = 2;
          return;
        }
        //  The platform is read back, so a change that was ignored or only
        //  half applied cannot slip into the call that cannot be undone.
        const readBack = await api("GET", `/v1/reviewSubmissions/${candidate}`);
        const applied = isPlainObject(readBack.parsed?.data?.attributes)
          ? readBack.parsed.data.attributes.platform
          : null;
        if (applied !== platform) {
          console.error(
            `submit-review: the platform on ${candidate} is ` +
            `${typeof applied === "string" ? applied : "unreadable"}, ` +
            `not ${platform}; not submitting`
          );
          //  The binding has not happened yet, so the version is on no
          //  submission and nothing has to be cleared by hand.
          console.error("submit-review: the version was not bound and nothing was submitted");
          process.exitCode = 2;
          return;
        }
      }
      if (boundTo.length === 0) {
        //  The submission is bound to nothing, so this version goes on it.
        const bound = await api("POST", "/v1/reviewSubmissionItems", JSON.stringify({
          data: {
            type: "reviewSubmissionItems",
            relationships: {
              reviewSubmission: { data: { type: "reviewSubmissions", id: candidate } },
              appStoreVersion: { data: { type: "appStoreVersions", id: versionId } }
            }
          }
        }));
        if (!bound.ok) {
          for (const line of describeAssociatedErrors(bound)) blockers.push(line);
          console.error(`submit-review: ${candidate} could not be bound to ${versionId}: ${describeError(bound)}`);
          //  A rejected credential is not a recoverable error:  the calls
          //  that follow this one include the submit, which cannot be undone,
          //  so the run stops here instead of issuing them with a credential
          //  App Store Connect has already refused.
          if (bound.status === 401 || bound.status === 403) {
            process.exitCode = 2;
            return;
          }
          continue;
        }
        //  The version is bound to this submission now, and the binding
        //  cannot be undone from here.
        boundSubmission = candidate;
        console.error(`submit-review: bound ${versionId} to review submission ${candidate}`);
      }
      //  The one call that cannot be undone carries the one attribute that
      //  has been proven in production, and nothing else.  The platform was
      //  set above, on a call that can be undone.
      submitAttempted = true;
      const result = await api("PATCH", `/v1/reviewSubmissions/${candidate}`, JSON.stringify({
        data: {
          type: "reviewSubmissions",
          id: candidate,
          attributes: { submitted: true }
        }
      }));
      if (!result.ok) {
        //  The refusal on the submit carries the same blockers the binding
        //  refusal carries, and they are the most useful thing this command
        //  can print.
        for (const line of describeAssociatedErrors(result)) blockers.push(line);
        console.error(`submit-review: ${candidate} refused: ${describeError(result)}`);
        //  A rejected credential stops the run here as well:  the next
        //  candidate would be submitted with a credential that has already
        //  been refused.
        if (result.status === 401 || result.status === 403) {
          if (boundSubmission) reportBound();
          process.exitCode = 2;
          return;
        }
        //  This run bound the version, so the run stops here.  A refused
        //  submit leaves the version attached to a submission, and a second
        //  candidate would be bound to the same version:  one version lives
        //  on one submission, and the binding cannot be undone from here.
        if (boundSubmission) {
          reportBound();
          break;
        }
        continue;
      }
      submitted = candidate;
      break;
    }
    if (!submitted) {
      if (submitAttempted) {
        //  The run got as far as the submit and App Store Connect refused
        //  it.  Saying that no submission is bound would be false:  this run
        //  bound the version itself.
        console.error("submit-review: not submitting, App Store Connect refused the submission");
      } else {
        //  The run never got as far as the submit, so no submission carries
        //  this version.  Saying that App Store Connect refused a submission
        //  would be false:  none was sent.
        console.error("submit-review: not submitting, the version was never bound to a submission");
      }
      if (blockers.length > 0) {
        console.error("submit-review: App Store Connect says the version is not ready:");
        for (const line of blockers) console.error(`  ${line}`);
      } else if (!submitAttempted && boundElsewhere.length > 0) {
        console.error(
          "submit-review: the app's review submission holds another version " +
          `(${boundElsewhere.join("; ")}).  One submission carries one version, so it has to be ` +
          "cleared in App Store Connect before this one can go to review."
        );
      }
      process.exitCode = 2;
      return;
    }
    const after = await api("GET", `/v1/reviewSubmissions/${submitted}`);
    if (!after.ok) {
      console.error(`submit-review: ${describeError(after)}`);
      process.exitCode = 2;
      return;
    }
    const attributes = after.parsed?.data?.attributes;
    const state = isPlainObject(attributes) ? attributes.state : null;
    const submittedDate = isPlainObject(attributes) ? attributes.submittedDate : null;
    if (state !== null && typeof state !== "string") {
      console.error("submit-review: the review submission came back with an unreadable state");
      process.exitCode = 2;
      return;
    }
    if (submittedDate !== null && typeof submittedDate !== "string") {
      console.error("submit-review: the review submission came back with an unreadable submittedDate");
      process.exitCode = 2;
      return;
    }
    // Only the report goes to stdout, so a wrapper that parses it as JSON
    // cannot be broken by a progress line.
    console.log(JSON.stringify({
      ok: true,
      reviewSubmission: submitted,
      state,
      submittedDate,
      versionString,
      build: build.id,
      platform
    }));
    return;
  }

  // -------------------------------------------------------------------------
  // App Store screenshot upload
  // -------------------------------------------------------------------------
  // Usage: node asc-api.mjs upload-screenshots <localizationId> <displayType> <file...>
  //
  // App Store Connect has no single-call screenshot upload.  The bytes go to
  // a pre-signed URL Apple hands out with the reservation, and the reservation
  // is only committed once the bytes are in, so it takes three calls:
  //
  //   1. POST  /v1/appScreenshots        reserve, get the upload operations
  //   2. PUT   <uploadOperation.url>     send the bytes
  //   3. PATCH /v1/appScreenshots/<id>   uploaded=true, then read
  //                                       assetDeliveryState
  //
  // The screenshot set (one per display size) is created on demand and reused,
  // so running this twice does not create a second set.  The display type is
  // the App Store Connect enum, e.g. APP_IPHONE_67 for the 6.9-inch iPhone
  // set and APP_IPAD_PRO_3GEN_129 for the 13-inch iPad set.
  if (method === "upload-screenshots") {
    const localizationId = path;
    let displayType = body;
    const files = process.argv.slice(5);
    if (!localizationId || !displayType || files.length === 0) {
      console.error("Usage: node asc-api.mjs upload-screenshots <localizationId> <displayType|auto> <file...>");
      process.exitCode = 2;
      return;
    }

    // "auto" reads the pixel size out of the file and picks the screenshot set
    // that size belongs to, so the display type cannot be mis-specified.
    // App Store Connect has no APP_IPHONE_69 and no APP_IPAD_PRO_13:  the
    // 6.9-inch iPhone size lives in APP_IPHONE_67.
    //
    // The two iPad types are the trap, because the enum names and Apple's
    // size table point in opposite directions.  Apple's own table at
    // developer.apple.com/help/app-store-connect/reference/screenshot-specifications
    // says the 13-inch display accepts 2064 x 2752 AND 2048 x 2732, and the
    // 12.9-inch display accepts only 2048 x 2732.  Only the 13-inch M4 and
    // M5 render at 2064 x 2752;  every 12.9-inch iPad Pro, the 3rd
    // generation included, renders at 2048 x 2732, and the capture script
    // falls back to those 12.9-inch simulators when no 13-inch one is
    // installed.
    //
    // Both iPad sizes therefore map to APP_IPAD_PRO_3GEN_129:  it is the
    // display profile App Store Connect requires (IPAD_13_PROFILE), and
    // routing 2048 x 2732 to the legacy set would leave the required set
    // empty on any runner that used the fallback, so the submission would
    // be refused.  APP_IPAD_PRO_129 stays reachable by naming the display
    // type explicitly instead of "auto", for a version that also ships the
    // legacy 12.9-inch set.
    //
    // Putting 2064 x 2752 in APP_IPAD_PRO_129 is therefore a spec mismatch,
    // and App Store Connect says so on the asset:  SPEC_MISMATCH, and every
    // image in the set is FAILED.  The iPhone sizes are Apple's own list, all
    // 16:10, and they belong to the desktop set.
    const sizeToDisplayType = {
      "1320x2868": "APP_IPHONE_67",
      "1290x2796": "APP_IPHONE_67",
      "1284x2778": "APP_IPHONE_65",
      "1242x2688": "APP_IPHONE_65",
      "2064x2752": "APP_IPAD_PRO_3GEN_129",
      "2048x2732": "APP_IPAD_PRO_3GEN_129",
      "1280x800": "APP_DESKTOP",
      "1440x900": "APP_DESKTOP",
      "2560x1600": "APP_DESKTOP",
      "2880x1800": "APP_DESKTOP"
    };
    // Every file has to belong to the same screenshot set.  A capture run
    // produces iPhone and iPad files together and they belong in different
    // sets, so a mixed list is refused here rather than sending the second
    // family's files to the first family's set.
    const fileSizes = new Map();
    for (const file of files) {
      if (!existsSync(file)) {
        console.error(`upload-screenshots: no such file: ${file}`);
        process.exitCode = 2;
        return;
      }
      // The width and height sit at offsets 16 and 20, so anything shorter
      // than a signature plus an IHDR header cannot be measured.  Reading
      // them anyway raises a RangeError with a stack trace instead of the
      // named failure every other bad input gets here.
      const bytes = readFileSync(file);
      if (bytes.length < 24) {
        console.error(`upload-screenshots: ${file} is ${bytes.length} bytes, too small to be a PNG`);
        process.exitCode = 2;
        return;
      }
      const header = bytes.subarray(0, 24);
      const size = `${header.readUInt32BE(16)}x${header.readUInt32BE(20)}`;
      const type = sizeToDisplayType[size];
      if (!type) {
        console.error(`upload-screenshots: ${size} is not a size App Store Connect accepts`);
        process.exitCode = 2;
        return;
      }
      fileSizes.set(file, { size, type });
    }
    // The sizes every display type accepts, from Apple's table.  "auto"
    // maps a size to the set the submit gate requires, but an explicitly
    // named display type is checked against the sizes IT accepts:  2048 x
    // 2732 is accepted by both iPad sets, and the legacy 12.9-inch set
    // would otherwise be unreachable now that the size maps to the
    // required 13-inch one.
    const displayTypeSizes = {
      APP_IPHONE_67: ["1320x2868", "1290x2796"],
      APP_IPHONE_65: ["1284x2778", "1242x2688"],
      APP_IPAD_PRO_3GEN_129: ["2064x2752", "2048x2732"],
      APP_IPAD_PRO_129: ["2048x2732"],
      APP_DESKTOP: ["1280x800", "1440x900", "2560x1600", "2880x1800"]
    };
    if (displayType === "auto") {
      displayType = fileSizes.get(files[0]).type;
    } else if (!Object.hasOwn(displayTypeSizes, displayType)) {
      //  Own-property test:  an inherited member such as "constructor" is
      //  not a display type either, and reading it would pass the guard
      //  and crash on the .includes below instead of refusing cleanly.
      console.error(`upload-screenshots: ${displayType} is not a display type this script knows`);
      process.exitCode = 2;
      return;
    }
    for (const file of files) {
      const { size, type } = fileSizes.get(file);
      if (!displayTypeSizes[displayType].includes(size)) {
        console.error(`upload-screenshots: ${file} is ${size}, which ${displayType} does not accept (the size belongs to ${type})`);
        console.error(`upload-screenshots: run the ${type} files on their own`);
        process.exitCode = 2;
        return;
      }
    }
    console.error(`upload-screenshots: ${fileSizes.get(files[0]).size} -> ${displayType}`);

    const sets = await api("GET", `/v1/appStoreVersionLocalizations/${localizationId}/appScreenshotSets`);
    if (!sets.ok) {
      console.error(`upload-screenshots: could not list screenshot sets (HTTP ${sets.status}): ${describeError(sets)}`);
      process.exitCode = 2;
      return;
    }
    const setList = requireArray(sets.parsed?.data, "screenshot-set list");
    let set = setList.find(
      (entry) => isPlainObject(entry) && typeof entry.id === "string"
        && entry.attributes?.screenshotDisplayType === displayType
    );
    if (!set) {
      const created = await api("POST", "/v1/appScreenshotSets", JSON.stringify({
        data: {
          type: "appScreenshotSets",
          attributes: { screenshotDisplayType: displayType },
          relationships: {
            appStoreVersionLocalization: {
              data: { type: "appStoreVersionLocalizations", id: localizationId }
            }
          }
        }
      }));
      if (!created.ok) {
        console.error(`upload-screenshots: could not create the ${displayType} set (HTTP ${created.status}): ${describeError(created)}`);
        process.exitCode = 2;
        return;
      }
      set = requireObject(created.parsed?.data, "screenshot set");
      console.error(`upload-screenshots: created the ${displayType} set ${set.id}`);
    } else {
      console.error(`upload-screenshots: reusing the ${displayType} set ${set.id}`);
    }

    for (const file of files) {
      if (!existsSync(file)) {
        console.error(`upload-screenshots: no such file: ${file}`);
        process.exitCode = 2;
        return;
      }
      const bytes = readFileSync(file);
      const fileName = file.split("/").pop();

      const reserved = await api("POST", "/v1/appScreenshots", JSON.stringify({
        data: {
          type: "appScreenshots",
          attributes: { fileName, fileSize: bytes.length },
          relationships: {
            appScreenshotSet: { data: { type: "appScreenshotSets", id: set.id } }
          }
        }
      }));
      if (!reserved.ok) {
        console.error(`upload-screenshots: could not reserve ${fileName} (HTTP ${reserved.status}): ${describeError(reserved)}`);
        process.exitCode = 2;
        return;
      }
      // The reservation now exists in a set that holds ten entries, so it has
      // to be dropped on every path that stops here.  When the response shape
      // gives back no usable id there is nothing to delete by, and the message
      // says so rather than letting the run end quietly with a slot consumed.
      const reservation = reserved.parsed?.data;
      if (!isPlainObject(reservation)) {
        console.error(`upload-screenshots: invalid screenshot reservation for ${fileName}; a reservation may be open in set ${set.id}`);
        process.exitCode = 2;
        return;
      }
      const screenshot = reservation;
      if (typeof screenshot.id !== "string" || screenshot.id.length === 0) {
        console.error(`upload-screenshots: invalid screenshot reservation for ${fileName}; a reservation may be open in set ${set.id}`);
        if (screenshot.id) await discardReservation(screenshot.id);
        process.exitCode = 2;
        return;
      }
      const operations = Array.isArray(screenshot.attributes?.uploadOperations)
        ? screenshot.attributes.uploadOperations
        : [];
      if (operations.length === 0) {
        console.error(`upload-screenshots: Apple returned no upload operation for ${fileName}`);
        await discardReservation(screenshot.id);
        process.exitCode = 2;
        return;
      }

      for (const operation of operations) {
        const headers = {};
        for (const header of operation.requestHeaders || []) headers[header.name] = header.value;
        const offset = operation.offset || 0;
        const length = operation.length || bytes.length;
        const chunk = bytes.subarray(offset, offset + length);
        let put;
        try {
          put = await fetch(operation.url, {
            method: operation.method || "PUT",
            headers,
            body: chunk,
            signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
          });
        } catch (error) {
          // The reservation is still open in App Store Connect, and a set
          // holds ten entries, so it is dropped before the script leaves.
          await discardReservation(screenshot.id);
          const reason = error && error.name === "TimeoutError"
            ? "the upload timed out"
            : `the upload failed (${error && error.message ? error.message : "unknown error"})`;
          console.error(`upload-screenshots: upload of ${fileName} failed: ${reason}`);
          process.exitCode = 2;
          return;
        }
        if (!put.ok) {
          console.error(`upload-screenshots: upload of ${fileName} failed (HTTP ${put.status})`);
          await discardReservation(screenshot.id);
          process.exitCode = 2;
          return;
        }
      }

      const committed = await api("PATCH", `/v1/appScreenshots/${screenshot.id}`, JSON.stringify({
        data: { type: "appScreenshots", id: screenshot.id, attributes: { uploaded: true } }
      }));
      if (!committed.ok) {
        console.error(`upload-screenshots: could not commit ${fileName} (HTTP ${committed.status}): ${describeError(committed)}`);
        await discardReservation(screenshot.id);
        process.exitCode = 2;
        return;
      }
      const committedScreenshot = requireObject(committed.parsed?.data, "screenshot commit");
      const state = committedScreenshot.attributes?.assetDeliveryState;
      const stateName = state?.state || "UNKNOWN";
      console.error(`upload-screenshots: ${fileName} -> ${screenshot.id} (${stateName})`);
      if (state?.errors?.length) {
        console.error(`upload-screenshots: Apple rejected ${fileName}:`);
        for (const problem of state.errors) {
          console.error(`  ${problem.code}: ${problem.title} ${problem.detail || ""}`);
        }
        process.exitCode = 3;
        return;
      }
    }
    console.log(JSON.stringify({ ok: true, setId: set.id, displayType, files }));
    process.exitCode = 0;
    return;
  }

  // Highest N already used by the "<prefix>.N" MARKETING version train
  // (e.g. 1.0.7). This is what makes App Store Connect -- not a single unbacked
  // local file -- the source of truth for "what has already shipped", so a
  // lost/reset counter cannot silently reuse a version that ASC rejects as a
  // duplicate.
  //
  // WHICH ASC FIELD IS WHICH (verified against live data 2026-08-12):
  //   preReleaseVersions[].attributes.version = CFBundleShortVersionString
  //                                             (the MARKETING version, "1.0.7")
  //   builds[].attributes.version             = CFBundleVersion
  //                                             (the BUILD number, "202608120521")
  // ship-testflight.sh sequences the MARKETING version, so this must read
  // preReleaseVersions. Reading builds[].version only ever worked by accident,
  // during the window when the ship script wrote the same dotted string into
  // both fields. It was already silently wrong for socratic, whose newest
  // marketing version is 1.0.1 but whose build numbers are "2" / "1" /
  // "202608120212" -- none of which match "1.0.N", so ASC contributed 0 and
  // "verification" verified nothing.
  //
  // Build numbers are still scanned afterwards, purely so this can never report
  // a LOWER floor than the old behaviour did for an app whose build numbers do
  // happen to be dotted (congress 1.0.7/1.0.1, usage 1.0.1).
  //
  // stdout: the integer N (0 when the train has no versions yet). stderr: notes.
  // exit 0 = authoritative answer; exit 2 = could not determine (caller must
  // treat that as "unverified", NOT as zero).
  if (method === "latest-build-seq") {
    const bundleId = path;
    const prefix = body;
    if (!bundleId || !prefix) {
      console.error("Usage: node asc-api.mjs latest-build-seq <bundleId> <prefix>");
      process.exitCode = 2;
      return;
    }
    const apps = await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=1`);
    if (!apps.ok) {
      // Every failure the service reports goes through describeError, so a
      // rejected key is never read as a bundle id that does not exist.  The
      // status stays in the message: ship-testflight.sh logs these lines
      // because the status is the only thing that explains a failed lookup,
      // and describeError alone cannot tell a rate limit from a bad request.
      const status = apps.networkError ? "" : ` (HTTP ${apps.status})`;
      console.error(`latest-build-seq: ${describeError(apps)}${status}`);
      process.exitCode = 2;
      return;
    }
    if (!isPlainObject(apps.parsed?.data?.[0])) {
      console.error(`latest-build-seq: no app in App Store Connect has the bundle id ${bundleId}`);
      process.exitCode = 2;
      return;
    }
    const appId = apps.parsed.data[0].id;
    // The id is what every query below filters on, so an app record without
    // one would send filter[app]=undefined and produce an HTTP 400 that reads
    // as a query the client built wrong.
    if (typeof appId !== "string" || appId.length === 0) {
      console.error(`latest-build-seq: the app record for ${bundleId} has no usable id`);
      process.exitCode = 2;
      return;
    }

    // Escape the prefix so "1.0" cannot match "120" via the regex dot.
    const escaped = prefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`^${escaped}\\.(\\d+)$`);

    let best = 0;
    const consider = (value) => {
      const m = re.exec(value || "");
      if (!m) return;
      const n = parseInt(m[1], 10);
      if (Number.isFinite(n) && n > best) best = n;
    };

    const platformArg = (arg4 || "").toUpperCase();
    const wantPlatform = (platformArg === "MACOS" || platformArg === "MAC_OS") ? "MAC_OS" : (platformArg === "IOS" ? "IOS" : null);

    // 1) Marketing version trains -- the authoritative record.
    let url = `/v1/preReleaseVersions?filter[app]=${appId}&limit=200`;
    let seenVersions = 0;
    for (let page = 0; page < 10 && url; page++) {
      const res = await api("GET", url);
      if (!res.ok) {
        console.error(`latest-build-seq: preReleaseVersions query failed (HTTP ${res.status})`);
        process.exitCode = 2;
        return;
      }
      for (const v of res.parsed.data || []) {
        // If a specific platform is requested, filter by it. Default to IOS if unspecified.
        const plat = v.attributes?.platform || "IOS";
        if (wantPlatform ? plat !== wantPlatform : plat !== "IOS") continue;
        seenVersions++;
        consider(v.attributes?.version);
      }
      url = res.parsed.links?.next || "";
    }

    // 2) Build numbers, so the floor can never regress below what the previous
    //    implementation reported.
    url = `/v1/builds?filter[app]=${appId}&sort=-uploadedDate&limit=200`;
    let seenBuilds = 0;
    for (let page = 0; page < 10 && url; page++) {
      const res = await api("GET", url);
      if (!res.ok) {
        console.error(`latest-build-seq: builds query failed (HTTP ${res.status})`);
        process.exitCode = 2;
        return;
      }
      for (const b of res.parsed.data || []) {
        seenBuilds++;
        consider(b.attributes?.version);
      }
      url = res.parsed.links?.next || "";
    }

    console.error(
      `latest-build-seq: ${seenVersions} marketing version(s) + ${seenBuilds} build(s) inspected; highest ${prefix}.N is N=${best}`
    );
    console.log(String(best));
    process.exitCode = 0;
    return;
  }

  // After upload: find THE BUILD THIS RUN JUST UPLOADED, declare export
  // compliance on it, set its TestFlight "What to Test" notes, and wait until
  // internal testers can actually install it.
  //
  // WHY THE BUILD VERSION IS A REQUIRED ARGUMENT (defect found 2026-08-13):
  // this used to do
  //     GET /v1/builds?filter[app]=<id>&sort=-uploadedDate&limit=1
  // and assume "newest" was the build the run had just uploaded. It never is.
  // ASC ingestion is asynchronous, so for the first minutes after an upload the
  // new build has NO record at all -- the newest build is the PREVIOUS ship,
  // which is already VALID and already IN_BETA_TESTING. So the compliance PATCH
  // was a no-op on an old build and the readiness poll returned success on poll
  // 1, printing "TestFlight internal testers can install this build" about a
  // build it had never inspected.
  //
  // Reproduced from two ships on 2026-08-13:
  //   usage       archive CURRENT_PROJECT_VERSION=202608131759
  //               ensure-tf-ready.json version=202608130439  (13h older)
  //   usage-local archive CURRENT_PROJECT_VERSION=202608131801
  //               ensure-tf-ready.json version=202608130441  (previous ship)
  //
  // CFBundleVersion is known exactly at archive time (ship-testflight.sh passes
  // it to xcodebuild as CURRENT_PROJECT_VERSION) and ASC ingests it verbatim as
  // builds[].attributes.version, so it is an exact key. There is deliberately NO
  // "newest build" fallback: that fallback IS the defect.
  //
  // Exit codes: 0 ready | 2 usage/API error | 3 readiness timeout (build found,
  // still processing) | 4 the uploaded build never appeared within the discovery
  // budget, so compliance was NOT declared on it | 5 the build is ready but the
  // app has no internal tester who could install it (see countInternalTesters) |
  // 6 the build is ready but the internal-tester count could not be read, so
  // whether anyone can install it is unverified.
  if (method === "ensure-appstore-profiles") {
    const mapPath = path;
    if (!mapPath) {
      console.error("Usage: node asc-api.mjs ensure-appstore-profiles <path-to-appstore-profiles.json>");
      process.exit(2);
    }
    // Hand-written boundary checks rather than zod, on purpose: this client is
    // dependency-free (see header) and hosted ios-ship runs it with plain
    // `node` before any `pnpm install`, so `import "zod"` would fail with
    // ERR_MODULE_NOT_FOUND and break every ship.  Same reasoning as
    // scripts/ci-build-resolver.mjs and scripts/update-botfleet-mac.mjs.
    /* oxlint-disable anti-slop/no-runtime-typeof -- hand-written boundary parse; zod is not installed on the ios-ship runner (see comment above). */
    const BUNDLE_ID_RE = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;
    const isPlainObject = (v) => Object.prototype.toString.call(v) === "[object Object]";
    const isNonEmptyString = (v) => typeof v === "string" && v.trim().length > 0;
    const apiRows = (res, key) => {
      const rows = isPlainObject(res.parsed) ? res.parsed[key] : undefined;
      if (rows === undefined) return [];
      if (!Array.isArray(rows)) {
        console.error(`ensure-appstore-profiles: unexpected App Store Connect response shape (${key} is not an array)`);
        process.exit(2);
      }
      return rows.filter(isPlainObject);
    };
    let want;
    try {
      want = JSON.parse(readFileSync(mapPath, "utf8"));
    } catch (err) {
      console.error(`ensure-appstore-profiles: cannot read map: ${err && err.message ? err.message : err}`);
      process.exit(2);
    }
    if (!isPlainObject(want) || !Object.keys(want).length) {
      console.error("ensure-appstore-profiles: map must be a non-empty {bundleId: profileName} object");
      process.exit(2);
    }
    for (const [bundleId, profileName] of Object.entries(want)) {
      if (!BUNDLE_ID_RE.test(bundleId) || !isNonEmptyString(profileName)) {
        console.error(
          `ensure-appstore-profiles: invalid map entry ${JSON.stringify(bundleId)}: keys must be bundle ids and values non-empty profile names`
        );
        process.exit(2);
      }
    }
    /* oxlint-enable anti-slop/no-runtime-typeof */

    function installedCodesigningSha1s() {
      try {
        const out = execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
          timeout: 30000
        });
        const shas = [];
        for (const line of out.split("\n")) {
          const m = line.match(/^\s*\d+\)\s+([0-9A-F]{40})\s+"/i);
          if (m) shas.push(m[1].toUpperCase());
        }
        return shas;
      } catch {
        return [];
      }
    }

    function certSha1FromContent(b64) {
      if (!b64) return null;
      try {
        const der = Buffer.from(b64, "base64");
        return createHash("sha1").update(der).digest("hex").toUpperCase();
      } catch {
        return null;
      }
    }

    const installed = new Set(installedCodesigningSha1s());
    if (installed.size === 0) {
      console.error("ensure-appstore-profiles: no codesigning identities in keychain (import IOS_CERT_* first)");
      process.exit(2);
    }

    const certRes = await api("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=200");
    if (!certRes.ok) {
      console.error(`ensure-appstore-profiles: certificate list failed (HTTP ${certRes.status})`);
      process.exit(2);
    }
    let distCertId = null;
    for (const row of apiRows(certRes, "data")) {
      const sha = certSha1FromContent(row.attributes?.certificateContent);
      if (sha && installed.has(sha)) {
        distCertId = row.id;
        console.error(`ensure-appstore-profiles: using distribution certificate id=${distCertId} (sha1=${sha})`);
        break;
      }
    }
    if (!distCertId) {
      console.error("ensure-appstore-profiles: no App Store Connect DISTRIBUTION certificate matches an installed identity");
      process.exit(2);
    }

    const profRes = await api("GET", "/v1/profiles?filter[profileType]=IOS_APP_STORE&limit=200&include=bundleId");
    if (!profRes.ok) {
      console.error(`ensure-appstore-profiles: profile list failed (HTTP ${profRes.status})`);
      process.exit(2);
    }
    const bundleIdByResource = new Map();
    for (const inc of apiRows(profRes, "included")) {
      if (inc.type === "bundleIds") {
        bundleIdByResource.set(inc.id, inc.attributes?.identifier);
      }
    }
    const activeByBundleAndName = new Map();
    for (const row of apiRows(profRes, "data")) {
      const rel = row.relationships?.bundleId?.data?.id;
      const identifier = bundleIdByResource.get(rel);
      const attrs = row.attributes || {};
      if (!identifier || attrs.profileState !== "ACTIVE") continue;
      activeByBundleAndName.set(`${identifier}\0${attrs.name}`, row);
    }

    for (const [bundleId, profileName] of Object.entries(want)) {
      const key = `${bundleId}\0${profileName}`;
      if (activeByBundleAndName.has(key)) {
        console.error(`ensure-appstore-profiles: reusing ACTIVE profile name=${profileName} bundle=${bundleId}`);
        continue;
      }

      const bidRes = await api("GET", `/v1/bundleIds?filter[identifier]=${encodeURIComponent(bundleId)}&limit=5`);
      if (!bidRes.ok) {
        console.error(`ensure-appstore-profiles: bundleId lookup failed for ${bundleId} (HTTP ${bidRes.status})`);
        process.exit(2);
      }
      const bundleRow = apiRows(bidRes, "data").find((r) => r.attributes?.identifier === bundleId);
      if (!bundleRow) {
        console.error(`ensure-appstore-profiles: bundle id ${bundleId} not registered in App Store Connect`);
        process.exit(2);
      }

      const body = JSON.stringify({
        data: {
          type: "profiles",
          attributes: {
            name: profileName,
            profileType: "IOS_APP_STORE"
          },
          relationships: {
            bundleId: { data: { type: "bundleIds", id: bundleRow.id } },
            certificates: { data: [{ type: "certificates", id: distCertId }] }
          }
        }
      });
      const created = await api("POST", "/v1/profiles", body);
      if (!created.ok) {
        const err = (created.parsed.errors || [])[0] || {};
        console.error(
          `ensure-appstore-profiles: create failed for ${bundleId} name=${profileName} (HTTP ${created.status} ${err.code || err.title || ""})`
        );
        process.exit(2);
      }
      console.error(`ensure-appstore-profiles: created profile name=${profileName} bundle=${bundleId}`);
    }
    process.exit(0);
  }

  // ensure-standing-testers <appleId> [buildVersion]
  //
  // The fleet's standing TestFlight testers (asc-standing-testers skill) must
  // sit in an EXTERNAL beta group of every fleet iOS app and get each new
  // build.  The emails come from ASC_STANDING_TESTERS (comma/space separated,
  // a GitHub secret), never from a file in this public repo, and are printed
  // masked only.  Idempotent: reuses the external group, existing tester
  // records and existing group/build links.  Only ever ADDS the listed
  // emails; never removes or invites anyone else.  When the build needs Beta
  // App Review for external testing it submits it (real submission, nothing
  // faked) and reports Apple's error verbatim if the app record is missing
  // review data.
  //
  // Exit codes: 0 everything in place | 3 partial (warnings printed) |
  // 2 usage / config error.  The ship workflow treats non-zero as a loud
  // warning and never fails the TestFlight ship on it.
  if (method === "ensure-standing-testers") {
    const appId = String(path || "").trim();
    const wantBuild = String(body || "").trim();
    const prefix = "standing-testers";
    // Hand-written parse, not zod: see ensure-appstore-profiles above.
    const EMAIL_RE = /^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/;
    const raw = String(process.env.ASC_STANDING_TESTERS || "");
    const emails = [...new Set(raw.split(/[\s,;]+/).map((e) => e.trim().toLowerCase()).filter(Boolean))];
    const mask = maskEmail;
    if (!/^\d+$/.test(appId)) {
      console.error(`${prefix}: usage: node asc-api.mjs ensure-standing-testers <appleId> [buildVersion]`);
      process.exit(2);
    }
    if (!emails.length) {
      console.error(`${prefix}: ASC_STANDING_TESTERS is empty; set the repo secret to the standing tester emails`);
      process.exit(2);
    }
    const bad = emails.filter((e) => !EMAIL_RE.test(e));
    if (bad.length) {
      console.error(`${prefix}: ASC_STANDING_TESTERS has ${bad.length} malformed entr${bad.length === 1 ? "y" : "ies"}; nothing changed`);
      process.exit(2);
    }
    if (emails.length > 5) {
      console.error(`${prefix}: ASC_STANDING_TESTERS lists ${emails.length} emails; the standing list is three.  Refusing to invite`);
      process.exit(2);
    }
    const rows = ascRows;
    const errText = ascErrorText;
    let warnings = 0;
    const warn = (msg) => { warnings += 1; console.error(`${prefix}: WARNING ${msg}`); };

    // 1) External beta group: reuse "Public Beta" or the first external group;
    //    create a private "Public Beta" (public link off) only when none exists.
    const groupsRes = await api("GET", `/v1/apps/${appId}/betaGroups?limit=200&fields[betaGroups]=name,isInternalGroup,publicLinkEnabled`);
    if (!groupsRes.ok) {
      console.error(`${prefix}: beta group list failed (${errText(groupsRes)})`);
      process.exit(3);
    }
    const external = rows(groupsRes).filter((g) => g.attributes?.isInternalGroup === false);
    let group = external.find((g) => g.attributes?.name === "Public Beta") || external[0];
    if (group) {
      console.error(`${prefix}: reusing external group "${group.attributes?.name}" id=${group.id} publicLink=${group.attributes?.publicLinkEnabled ? "on" : "off"}`);
    } else {
      const created = await api("POST", "/v1/betaGroups", JSON.stringify({
        data: {
          type: "betaGroups",
          attributes: { name: "Public Beta" },
          relationships: { app: { data: { type: "apps", id: appId } } }
        }
      }));
      if (!created.ok) {
        console.error(`${prefix}: could not create external group "Public Beta" (${errText(created)})`);
        process.exit(3);
      }
      group = created.parsed.data;
      console.error(`${prefix}: created external group "Public Beta" id=${group.id} (public link off)`);
    }

    // 2) Testers: add each standing email to the group, reusing tester records.
    const inGroupRes = await api("GET", `/v1/betaGroups/${group.id}/betaTesters?limit=200&fields[betaTesters]=email`);
    if (!inGroupRes.ok) {
      warn(`could not list testers in group "${group.attributes?.name}" (${errText(inGroupRes)}); not re-adding anyone`);
      process.exit(3);
    }
    const inGroup = new Set(rows(inGroupRes).map((t) => String(t.attributes?.email || "").toLowerCase()));
    for (const email of emails) {
      if (inGroup.has(email)) {
        console.error(`${prefix}: ${mask(email)} already in group`);
        continue;
      }
      const added = await addTesterToGroup({ api, appId, groupId: group.id, email });
      const res = added.res;
      const existing = added.existing;
      if (res.ok || res.status === 204) {
        console.error(`${prefix}: added ${mask(email)} to group (${existing ? "existing tester" : "new tester"})`);
      } else {
        warn(`could not add ${mask(email)} to group (${errText(res)})`);
      }
    }

    // 2b) Internal group: App Store Connect users install every build with no
    //     Beta App Review.  This is the path that reaches the owner's phone; a
    //     new app record has none until this creates it (GH #1018).
    // Its warnings go through warn(), so they count toward the exit code.
    await ensureInternalTesterGroup({
      api, appId, emails,
      log: (m) => console.error(`${prefix}: ${m}`),
      warn
    });

    // 3) Build: the given CFBundleVersion, else the newest upload.
    const buildQuery = wantBuild
      ? `/v1/builds?filter[app]=${appId}&filter[version]=${encodeURIComponent(wantBuild)}&limit=5`
      : `/v1/builds?filter[app]=${appId}&sort=-uploadedDate&limit=1`;
    const buildRes = await api("GET", buildQuery);
    const build = rows(buildRes)[0];
    if (!build) {
      warn(`no build found for app ${appId}${wantBuild ? ` version ${wantBuild}` : ""} (${buildRes.ok ? "empty" : errText(buildRes)})`);
      process.exit(3);
    }
    const buildLabel = `build ${build.attributes?.version} id=${build.id}`;
    if (build.attributes?.processingState !== "VALID") {
      warn(`${buildLabel} processingState=${build.attributes?.processingState}; not distributing yet`);
      process.exit(3);
    }
    const link = await api("POST", `/v1/betaGroups/${group.id}/relationships/builds`,
      JSON.stringify({ data: [{ type: "builds", id: build.id }] }));
    if (link.ok || link.status === 204) {
      console.error(`${prefix}: ${buildLabel} assigned to group "${group.attributes?.name}"`);
    } else {
      warn(`could not assign ${buildLabel} to group (${errText(link)})`);
    }

    // 4) Beta App Review: external testers only get a build Apple approved.
    const detail = await api("GET", `/v1/builds/${build.id}/buildBetaDetail`);
    if (!detail.ok) {
      warn(`could not read buildBetaDetail for ${buildLabel} (${errText(detail)}); Beta App Review submission skipped`);
      process.exit(3);
    }
    const ext = detail.parsed?.data?.attributes?.externalBuildState || "unknown";
    console.error(`${prefix}: ${buildLabel} externalBuildState=${ext}`);
    if (ext === "READY_FOR_BETA_SUBMISSION") {
      const sub = await api("POST", "/v1/betaAppReviewSubmissions", JSON.stringify({
        data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: build.id } } } }
      }));
      if (sub.ok) {
        console.error(`${prefix}: submitted ${buildLabel} for Beta App Review; testers are notified when Apple approves`);
      } else {
        const errs = (sub.parsed?.errors || []).map((e) => `${e.code || ""}: ${e.detail || e.title || ""}`).join(" | ");
        warn(`Beta App Review submission failed (HTTP ${sub.status}) ${errs}.  Fill the TestFlight Test Information (beta app description, feedback email, review contact) in App Store Connect for app ${appId}`);
      }
    } else if (["BETA_REJECTED", "MISSING_EXPORT_COMPLIANCE", "PROCESSING_EXCEPTION", "EXPIRED"].includes(ext)) {
      warn(`${buildLabel} cannot reach external testers (externalBuildState=${ext})`);
    }

    console.error(`${prefix}: done (${emails.length} standing tester(s), ${warnings} warning(s))`);
    process.exit(warnings ? 3 : 0);
  }

  if (method === "ensure-tf-ready") {
    const bundleId = path;
    const wantBuildVersion = body;
    const wantMarketing = arg4;
    const appleIdHint = String(arg5 || process.env.ASC_APPLE_ID || "").trim();
    if (!bundleId || !wantBuildVersion) {
      console.error("Usage: node asc-api.mjs ensure-tf-ready <bundleId> <buildVersion> [marketingVersion] [appleId]");
      console.error("  <buildVersion> is CFBundleVersion (CURRENT_PROJECT_VERSION) of the build");
      console.error("  this run uploaded. It is required: without it there is no way to tell the");
      console.error("  new build from the previous ship, and ASC has no record of the new build");
      console.error("  for the first minutes after upload.");
      process.exitCode = 2;
      return;
    }

    const totalTimeoutSec = (() => {
      const raw = process.env.IOS_TF_READY_TIMEOUT_SEC;
      const n = raw ? parseInt(raw, 10) : NaN;
      return Number.isFinite(n) && n > 0 ? n : 900;
    })();
    const deadline = Date.now() + totalTimeoutSec * 1000;
    const POLL_MS = 15000;
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    const apps = await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=1`);
    if (!apps.ok) {
      // Every failure the service reports goes through describeError, so a
      // rejected key is never read as a bundle id that does not exist.  The
      // status stays in the message for the same reason as latest-build-seq.
      const status = apps.networkError ? "" : ` (HTTP ${apps.status})`;
      console.error(`ensure-tf-ready: ${describeError(apps)}${status}`);
      process.exitCode = 2;
      return;
    }
    if (!isPlainObject(apps.parsed?.data?.[0])) {
      console.error(`ensure-tf-ready: no app in App Store Connect has the bundle id ${bundleId}`);
      process.exitCode = 2;
      return;
    }
    const appId = apps.parsed.data[0].id;
    // The id is what every query below filters on, so an app record without
    // one would send filter[app]=undefined and produce an HTTP 400 that reads
    // as a query the client built wrong.
    if (typeof appId !== "string" || appId.length === 0) {
      console.error(`ensure-tf-ready: the app record for ${bundleId} has no usable id`);
      process.exitCode = 2;
      return;
    }

    // ---- Phase A: discovery. Poll until the uploaded build has an ASC record.
    let query = `/v1/builds?filter[app]=${appId}&filter[version]=${encodeURIComponent(wantBuildVersion)}`;
    if (wantMarketing) {
      query += `&filter[preReleaseVersion.version]=${encodeURIComponent(wantMarketing)}`;
    }
    query += "&limit=2&include=buildBetaDetail,preReleaseVersion";

    let build = null;
    let attempt = 0;
    let transientErrors = 0;
    while (Date.now() < deadline) {
      attempt++;
      const res = await api("GET", query);
      if (!res.ok) {
        // A rate-limit or a 5xx is exactly what a ~60-poll loop against a
        // third-party API should expect, and the whole export-compliance fix
        // hangs off this loop -- so one transient blip must not abandon it.
        // Genuine client errors (400/401/403/404) still fail fast.
        if (res.status === 429 || res.status >= 500) {
          transientErrors++;
          console.error(`ensure-tf-ready: discovery query transient HTTP ${res.status} (attempt ${attempt}); retrying`);
          await sleep(POLL_MS);
          continue;
        }
        console.error(`ensure-tf-ready: discovery query failed (HTTP ${res.status})`);
        process.exitCode = 2;
        return;
      }
      const rows = res.parsed.data || [];
      if (rows.length > 1) {
        console.error(`ensure-tf-ready: ${rows.length} builds match version ${wantBuildVersion} -- ambiguous, refusing to guess`);
        process.exitCode = 2;
        return;
      }
      if (rows.length === 1) {
        build = rows[0];
        build.__included = res.parsed.included || [];
        console.error(`ensure-tf-ready: discovered build ${wantBuildVersion} after ${attempt} attempt(s)`);
        break;
      }
      console.error(`ensure-tf-ready: build ${wantBuildVersion} not visible yet (attempt ${attempt}); waiting`);
      await sleep(POLL_MS);
    }

    if (!build) {
      // Name what IS present, so the log answers "then what did ASC have?".
      let newest = "unknown";
      try {
        const probe = await api("GET", `/v1/builds?filter[app]=${appId}&sort=-uploadedDate&limit=1`);
        if (probe.ok) {
          // The response is the service's, so its shape is checked before any
          // of it is read.  Three states stay distinct: a version is the
          // actual newest build, "none" is the service saying there is no
          // build at all, and "unknown" is an answer that could not be read.
          // A malformed body must not fold into "none".
          const rows = Array.isArray(probe.parsed?.data) ? probe.parsed.data : null;
          if (rows === null) {
            newest = "unknown";
          } else if (rows.length === 0) {
            newest = "none";
          } else {
            const first = rows[0];
            newest = isPlainObject(first) && isPlainObject(first.attributes)
              && typeof first.attributes.version === "string"
              ? first.attributes.version
              : "unknown";
          }
        } else {
          // The probe did not answer, so what is present is not known.  Saying
          // "none" would assert that the app has no builds at all, which is a
          // different and wrong claim.
          console.error(`ensure-tf-ready: the newest-build probe failed: ${describeError(probe)}`);
        }
      } catch { /* diagnostic only */ }
      console.error(
        `ensure-tf-ready: build version ${wantBuildVersion} never appeared for ${bundleId} within ${totalTimeoutSec}s; ` +
        `newest present is ${newest}. Export compliance was NOT declared on the build this run uploaded.` +
        (transientErrors ? ` (${transientErrors} transient API error(s) during discovery)` : "")
      );
      console.log(JSON.stringify({
        ok: false, wanted: wantBuildVersion, newestPresent: newest,
        discoveryTimedOut: true, transientErrors
      }));
      process.exitCode = 4;
      return;
    }

    const buildId = build.id;
    const version = build.attributes?.version;
    const enc = build.attributes?.usesNonExemptEncryption;
    const beta = (build.__included || []).find((x) => x.type === "buildBetaDetails")?.attributes || {};
    console.error(`ensure-tf-ready: build=${version} id=${buildId} enc=${enc} internal=${beta.internalBuildState || "unknown"}`);

    // ---- Phase B: export compliance, on the DISCOVERED build.
    if (enc !== false) {
      const patch = await api("PATCH", `/v1/builds/${buildId}`, JSON.stringify({
        data: { type: "builds", id: buildId, attributes: { usesNonExemptEncryption: false } }
      }));
      if (!patch.ok) {
        console.error(`ensure-tf-ready: compliance patch failed HTTP ${patch.status}`);
        process.exitCode = 2;
        return;
      }
      console.error("ensure-tf-ready: declared usesNonExemptEncryption=false");
    }

    // ---- Phase B2: TestFlight "What to Test". Before the readiness wait, so a
    // Phase C timeout cannot lose the notes. Never fails the caller.
    try {
      await setWhatToTest({ api, buildId, appId, marketing: wantMarketing });
    } catch (err) {
      console.error(`ensure-tf-ready: release-notes step failed (non-fatal): ${err && err.message ? err.message : err}`);
    }

    // ---- Phase C: readiness, drawing from the same overall deadline. Always
    // polls at least once: if discovery consumed nearly the whole budget, a
    // zero-poll "timed out" line would be misleading, and by this point the
    // compliance PATCH (the part that actually matters) has already landed.
    let pollNo = 0;
    while (pollNo === 0 || Date.now() < deadline) {
      pollNo++;
      const again = await api("GET", `/v1/builds/${buildId}?include=buildBetaDetail`);
      const attrs = again.parsed.data?.attributes || {};
      const detail = (again.parsed.included || []).find((x) => x.type === "buildBetaDetails")?.attributes || {};
      const state = detail.internalBuildState || "";
      console.error(`ensure-tf-ready: poll ${pollNo} enc=${attrs.usesNonExemptEncryption} internal=${state}`);
      if (state === "IN_BETA_TESTING" || state === "READY_FOR_BETA_TESTING") {
        // READY_FOR_BETA_TESTING only says Apple finished processing.  It does
        // not say anyone can install the build: a new app record has no internal
        // group, and that is how 14 green ships reached nobody (GH #1018).
        const internalTesters = await countInternalTesters({ api, appId });
        if (internalTesters.ok) {
          console.error(`ensure-tf-ready: internal testers with access to all builds=${internalTesters.testers} (groups=${internalTesters.groups})`);
        } else {
          console.error(`ensure-tf-ready: could not count internal testers (${internalTesters.error})`);
        }
        const nobody = internalTesters.ok && internalTesters.testers === 0;
        console.log(JSON.stringify({
          ok: true,
          buildId,
          version,
          internalBuildState: state,
          usesNonExemptEncryption: attrs.usesNonExemptEncryption,
          internalTesterCount: internalTesters.ok ? internalTesters.testers : null
        }));
        // 5 = read and zero; 6 = could not be read, so installability is unverified.
        process.exit(nobody ? 5 : internalTesters.ok ? 0 : 6);
      }
      await sleep(POLL_MS);
    }
    console.error("ensure-tf-ready: timed out waiting for IN_BETA_TESTING (upload may still be processing)");
    console.log(JSON.stringify({ ok: false, buildId, version, timedOut: true }));
    process.exitCode = 3;
    return;
  }

  const url = path.startsWith("http") ? path : `${apiBase}${path}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json"
    },
    body: body ? body : undefined,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
  });
  const text = await res.text();
  console.error(`HTTP ${res.status}`);
  console.log(text);
  if (!res.ok) { process.exitCode = 2; return; }
}

// Run only when invoked as a script, so a test can import the helpers above.
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch((err) => {
    if (err instanceof NamedFailure) {
      // The failure named itself, so a stack trace would only be noise.
      console.error(err.message);
    } else {
      console.error(String(err && err.stack ? err.stack : err));
    }
    // A failure that already chose its exit code keeps it.
    if (!process.exitCode) process.exitCode = 1;
    return;
  });
}
