#!/usr/bin/env node
/**
 * Minimal App Store Connect API client. No dependencies beyond Node's
 * built-in crypto (ES256 JWT signing) and fetch (Node 18+).
 *
 * Auth: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH from the environment, else Infisical
 * Fleet-OPS via fleet-secrets (never prints values).
 *
 * Usage:
 *   node asc-api.mjs GET /v1/apps
 *   node asc-api.mjs GET "/v1/apps?filter[bundleId]=trade.socratic.app"
 *   node asc-api.mjs PATCH /v1/betaAppReviewDetails/<id> '{"data":{...}}'
 *   node asc-api.mjs latest-build-seq <bundleId> <prefix>   # e.g. ... trade.congress.ios 1.0
 *
 * Prints the raw JSON response to stdout. Caller is responsible for not
 * echoing anything secret-shaped from the response (ASC responses don't
 * carry credentials, only app metadata, so this is safe to print as-is).
 */
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createSign } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

// A failure that already knows what to say.
//
// A guard deep in the call stack cannot return from main(), so it throws this
// instead.  The handler at the bottom of the file prints the message on its
// own, without a stack trace, and keeps the exit code the failure set.
class NamedFailure extends Error {}

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

// AFC-359: credentials come from the environment (CI sets ASC_KEY_ID / ASC_ISSUER_ID /
// ASC_KEY_PATH), else Infisical Fleet-OPS /asc through fleet-secrets: ASC_KEY_ID, ASC_ISSUER_ID and
// ASC_KEY_P8 (the .p8 contents).  The key is used in memory only; nothing is written to disk or printed.
function fleetSecretsGet(name, folder) {
  const localBin = join(homedir(), ".local", "bin", "fleet-secrets");
  // $FLEET_SECRETS, then ~/.local/bin, then whatever "fleet-secrets" is on PATH.
  const bin = process.env.FLEET_SECRETS || (existsSync(localBin) ? localBin : "fleet-secrets");
  try {
    return execFileSync(bin, ["get", name, "--path", folder], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).replace(/\n$/, "");
  } catch {
    return "";
  }
}

function resolveAscCredentials() {
  let keyId = process.env.ASC_KEY_ID || "";
  let issuerId = process.env.ASC_ISSUER_ID || "";
  const envKeyPath = (process.env.ASC_KEY_PATH || "").replace(/^~(?=\/)/, homedir());
  if (keyId && issuerId && envKeyPath && existsSync(envKeyPath)) {
    return { keyId, issuerId, privateKeyPem: readFileSync(envKeyPath, "utf8") };
  }
  // The key id, issuer and private key must belong together:  with no key id in the
  // environment all three come from /asc;  an env key id that is not the /asc one gets its
  // own .p8 from /authkey-<id>-p8, never the /asc key.
  const ascKeyId = fleetSecretsGet("ASC_KEY_ID", "/asc");
  if (!keyId) {
    keyId = ascKeyId;
    issuerId = fleetSecretsGet("ASC_ISSUER_ID", "/asc");
  } else if (!issuerId && keyId === ascKeyId) {
    // env named the /asc key itself:  its issuer is the /asc one
    issuerId = fleetSecretsGet("ASC_ISSUER_ID", "/asc");
  }
  if (!keyId || !issuerId) {
    console.error("Missing ASC_KEY_ID / ASC_ISSUER_ID: set them in the environment or add ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 to Infisical /asc");
    process.exitCode = 1;
    return null;
  }
  const privateKeyPem = keyId === ascKeyId
    ? fleetSecretsGet("ASC_KEY_P8", "/asc")
    : fleetSecretsGet(`AUTHKEY_${keyId}`, `/authkey-${keyId.toLowerCase()}-p8`);
  if (!privateKeyPem) {
    console.error(`Missing the .p8 for key ${keyId}: Infisical /asc ASC_KEY_P8 (the /asc key) or /authkey-<id>-p8 AUTHKEY_<id>`);
    process.exitCode = 1;
    return null;
  }
  return { keyId, issuerId, privateKeyPem: privateKeyPem + "\n" };
}

function base64url(input) {
  return Buffer.from(input).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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
  const credentials = resolveAscCredentials();
  if (!credentials) {
    // The helper already named what is missing and set the exit code.
    return;
  }
  const { keyId, issuerId, privateKeyPem } = credentials;
  const token = signJwt({ keyId, issuerId, privateKeyPem });

  const [method, path, body, arg4] = process.argv.slice(2);
  if (!method || !path) {
    console.error("Usage: node asc-api.mjs <METHOD> <PATH> [JSON_BODY]");
    console.error("       node asc-api.mjs ensure-tf-ready <bundleId> <buildVersion> [marketingVersion]");
    console.error("       node asc-api.mjs latest-build-seq <bundleId> <prefix>");
    console.error("       node asc-api.mjs upload-screenshots <localizationId> <displayType> <file...>");
    process.exitCode = 1;
    return;
  }

  // How long a single App Store Connect call may take.  Node's fetch has no
  // default timeout, so a call that never answers would hang the script with
  // the reservation still pending in App Store Connect.
  const REQUEST_TIMEOUT_MS = 120_000;

  // Describe a failed response without ever printing what it holds.
  //
  // The raw body of an App Store Connect error is not printed: it is
  // whatever the service chose to say, and it may echo a header or a token.
  // Only the titles and details of the JSON API errors are used, and a run of
  // token-like characters in one of those is redacted.  A rejected key is
  // named, never previewed: a masked preview of a private key is still a
  // piece of the key.
  function describeError(res) {
    if (res.networkError) {
      return "the request never reached App Store Connect";
    }
    if (res.status === 401 || res.status === 403) {
      return "App Store Connect rejected the key: check ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 in Fleet-OPS prod /asc";
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
      throw new NamedFailure(`upload-screenshots: invalid ${what} response`);
    }
    return value;
  }

  function requireArray(value, what) {
    if (!Array.isArray(value)) {
      process.exitCode = 2;
      throw new NamedFailure(`upload-screenshots: invalid ${what} response`);
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
  // set and APP_IPAD_PRO_129 for the 13-inch iPad set.
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
    // App Store Connect has no APP_IPHONE_69 or APP_IPAD_PRO_13: the 6.9-inch
    // iPhone size lives in APP_IPHONE_67 and the 13-inch iPad size in
    // APP_IPAD_PRO_129.  The sizes are Apple's own list, at
    // developer.apple.com/help/app-store-connect/reference/screenshot-specifications
    const sizeToDisplayType = {
      "1320x2868": "APP_IPHONE_67",
      "1290x2796": "APP_IPHONE_67",
      "1284x2778": "APP_IPHONE_65",
      "1242x2688": "APP_IPHONE_65",
      "2064x2752": "APP_IPAD_PRO_129",
      "2048x2732": "APP_IPAD_PRO_3GEN_129"
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
    if (displayType === "auto") {
      displayType = fileSizes.get(files[0]).type;
    }
    for (const file of files) {
      const { size, type } = fileSizes.get(file);
      if (type !== displayType) {
        console.error(`upload-screenshots: ${file} is ${size}, which belongs to ${type}, not ${displayType}`);
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
    if (!apps.ok || !apps.parsed.data?.[0]) {
      // A request that never reached App Store Connect is not a verdict about
      // the app, so it is not reported as "not found".
      console.error(apps.networkError
        ? `latest-build-seq: ${describeError(apps)}`
        : `latest-build-seq: app not found for bundle (HTTP ${apps.status})`);
      process.exitCode = 2;
      return;
    }
    const appId = apps.parsed.data[0].id;

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
  // budget, so compliance was NOT declared on it.
  if (method === "ensure-tf-ready") {
    const bundleId = path;
    const wantBuildVersion = body;
    const wantMarketing = arg4;
    if (!bundleId || !wantBuildVersion) {
      console.error("Usage: node asc-api.mjs ensure-tf-ready <bundleId> <buildVersion> [marketingVersion]");
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
    if (!apps.ok || !apps.parsed.data?.[0]) {
      // A request that never reached App Store Connect is not a verdict about
      // the app, so it is not reported as "not found".
      console.error(apps.networkError
        ? `ensure-tf-ready: ${describeError(apps)}`
        : `ensure-tf-ready: app not found for bundle (HTTP ${apps.status})`);
      process.exitCode = 2;
      return;
    }
    const appId = apps.parsed.data[0].id;

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
          newest = probe.parsed?.data?.[0]?.attributes?.version || "none";
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
        console.log(JSON.stringify({
          ok: true,
          buildId,
          version,
          internalBuildState: state,
          usesNonExemptEncryption: attrs.usesNonExemptEncryption
        }));
        process.exitCode = 0;
        return;
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
