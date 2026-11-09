#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createSign } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { normalizePrivateKey } from "./asc-key.mjs";
import { fleetSecretsEnvironment, hasInfisicalServiceToken } from "./infisical-service-token.mjs";

const APP_BUNDLE = "com.simplewithus.codecaps.ios";
const KEEP_VERSION = "0.1.0";
const API_ORIGIN = "https://api.appstoreconnect.apple.com";
const MAX_PAGES = 50;

function base64url(value) {
  return Buffer.from(value).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function privateKey(value) {
  const cleaned = String(value || "").trim();
  if (!cleaned) return "";
  if (cleaned.includes("-----BEGIN ")) return normalizePrivateKey(cleaned) || "";
  const decoded = Buffer.from(cleaned, "base64").toString("utf8");
  return normalizePrivateKey(decoded) || "";
}

function fleetSecret(name) {
  if (!hasInfisicalServiceToken(process.env)) return "";
  const bin = process.env.FLEET_SECRETS_BIN || process.env.FLEET_SECRETS
    || join(homedir(), ".local", "bin", "fleet-secrets");
  try {
    return execFileSync(bin, ["get", name, "--path", "/asc"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      env: fleetSecretsEnvironment(process.env),
      timeout: 30000
    }).replace(/\n$/, "");
  } catch {
    return "";
  }
}

function credentials() {
  const appleKey = process.env.APPLE_API_KEY_P8_BASE64 || "";
  const appleId = String(process.env.APPLE_API_KEY_ID || "").trim();
  const appleIssuer = String(process.env.APPLE_API_ISSUER_ID || "").trim();
  const ascKey = process.env.ASC_KEY_P8 || "";
  const ascId = String(process.env.ASC_KEY_ID || "").trim();
  const ascIssuer = String(process.env.ASC_ISSUER_ID || "").trim();
  const keyId = appleId || ascId || fleetSecret("ASC_KEY_ID").trim();
  const issuerId = appleIssuer || ascIssuer || fleetSecret("ASC_ISSUER_ID").trim();
  const key = privateKey(appleKey || ascKey || fleetSecret("ASC_KEY_P8"));
  if (!/^[A-Za-z0-9]{1,40}$/.test(keyId) || !issuerId || !key) {
    throw new Error("an authorized App Store Connect API key is unavailable");
  }
  if (!appleKey && !ascKey && !hasInfisicalServiceToken(process.env)) {
    throw new Error("an explicit Infisical service token is required for the ASC secret fallback");
  }
  return { keyId, issuerId, key };
}

function resolveApiBase() {
  const configured = String(process.env.ASC_API_BASE || API_ORIGIN).replace(/\/+$/, "");
  if (configured === API_ORIGIN) return configured;
  if (/^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/.test(configured)) return configured;
  throw new Error("ASC_API_BASE must be the production host or a loopback test host");
}

function signedToken(credential) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: credential.keyId, typ: "JWT" }));
  const payload = base64url(JSON.stringify({ iss: credential.issuerId, iat: now, exp: now + 1190, aud: "appstoreconnect-v1" }));
  const signingInput = `${header}.${payload}`;
  const signer = createSign("SHA256");
  signer.update(signingInput);
  signer.end();
  const signature = signer.sign({ key: credential.key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${base64url(signature)}`;
}

function createClient() {
  const base = resolveApiBase();
  const token = signedToken(credentials());
  return async (method, path, body) => {
    const target = path.startsWith("http") ? new URL(path) : new URL(path, `${base}/`);
    if (target.origin !== base) throw new Error("ASC pagination link changed API host");
    let response;
    try {
      response = await fetch(target, {
        method,
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body,
        signal: AbortSignal.timeout(30000)
      });
    } catch {
      return { ok: false, status: 0, parsed: null };
    }
    const text = await response.text();
    let parsed;
    try { parsed = JSON.parse(text); } catch { parsed = null; }
    return { ok: response.ok, status: response.status, parsed };
  };
}

async function allRows(api, firstPath, type, describe) {
  const rows = [];
  let next = firstPath;
  for (let page = 0; page < MAX_PAGES && next; page++) {
    const response = await api("GET", next);
    if (!response.ok || !Array.isArray(response.parsed?.data)) {
      throw new Error(`${describe} inventory failed (HTTP ${response.status})`);
    }
    for (const row of response.parsed.data) {
      if (row?.type !== type || typeof row.id !== "string") throw new Error(`malformed ${describe} inventory row`);
      rows.push(row);
    }
    next = response.parsed.links?.next || "";
  }
  if (next) throw new Error(`${describe} inventory exceeds ${MAX_PAGES} pages`);
  return rows;
}

async function readInventory(api, appId) {
  const versionRows = await allRows(
    api,
    `/v1/apps/${encodeURIComponent(appId)}/appStoreVersions?filter[platform]=IOS&limit=200`,
    "appStoreVersions",
    "App Store version"
  );
  const versions = versionRows.map((row) => {
    const version = row.attributes?.versionString;
    const state = row.attributes?.appStoreState;
    if (!/^\d+(?:\.\d+)*$/.test(version || "") || typeof state !== "string" || row.attributes?.platform !== "IOS") {
      throw new Error(`malformed iOS App Store version ${row.id}`);
    }
    return { id: row.id, version, state };
  });

  const builds = [];
  const trainVersions = new Map();
  let next = `/v1/builds?filter[app]=${encodeURIComponent(appId)}`
    + `&filter[preReleaseVersion.platform]=IOS&include=preReleaseVersion&limit=200`;
  for (let page = 0; page < MAX_PAGES && next; page++) {
    const response = await api("GET", next);
    if (!response.ok || !Array.isArray(response.parsed?.data)) throw new Error(`TestFlight build inventory failed (HTTP ${response.status})`);
    for (const train of response.parsed.included || []) {
      if (train?.type !== "preReleaseVersions" || typeof train.id !== "string"
          || !/^\d+(?:\.\d+)*$/.test(train.attributes?.version || "") || train.attributes?.platform !== "IOS") {
        throw new Error("malformed included iOS TestFlight train");
      }
      trainVersions.set(train.id, train.attributes.version);
    }
    for (const row of response.parsed.data) {
      const version = trainVersions.get(row.relationships?.preReleaseVersion?.data?.id);
      if (row.type !== "builds" || typeof row.id !== "string" || typeof row.attributes?.expired !== "boolean"
          || !/^\d+(?:\.\d+)*$/.test(row.attributes?.version || "") || !version) {
        throw new Error(`unattributed or malformed TestFlight build ${row?.id || "(missing id)"}`);
      }
      builds.push({ id: row.id, build: row.attributes.version, version, expired: row.attributes.expired });
    }
    next = response.parsed.links?.next || "";
  }
  if (next) throw new Error(`TestFlight build inventory exceeds ${MAX_PAGES} pages`);
  return { versions, builds };
}

async function readReviewItems(api, appId, versions) {
  const submissions = await allRows(
    api,
    `/v1/apps/${encodeURIComponent(appId)}/reviewSubmissions?filter[platform]=IOS&limit=200`,
    "reviewSubmissions",
    "App Store review submission"
  );
  const versionsById = new Map(versions.map((version) => [version.id, version]));
  const items = [];
  for (const submission of submissions) {
    const submissionState = submission.attributes?.state;
    if (typeof submissionState !== "string") throw new Error(`malformed App Store review submission ${submission.id}`);
    const submissionPath = `/v1/reviewSubmissions/${encodeURIComponent(submission.id)}/items`
      + `?limit=200&fields[reviewSubmissionItems]=state,appStoreVersion`;
    const rows = await allRows(api, submissionPath, "reviewSubmissionItems", "App Store review item");
    for (const item of rows) {
      const versionRef = item.relationships?.appStoreVersion?.data;
      if (!versionRef) continue;
      if (versionRef.type !== "appStoreVersions" || typeof versionRef.id !== "string") {
        throw new Error(`malformed App Store version relationship on review item ${item.id}`);
      }
      const version = versionsById.get(versionRef.id);
      if (!version) throw new Error(`review item ${item.id} references an unlisted iOS App Store version`);
      const activeSubmission = ["READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW"].includes(submissionState);
      const pendingRelease = submissionState === "COMPLETE"
        && ["WAITING_FOR_EXPORT_COMPLIANCE", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE"].includes(version.state);
      if (version.version !== KEEP_VERSION && (activeSubmission || pendingRelease)) {
        items.push({ id: item.id, versionId: version.id, version: version.version, versionState: version.state,
          submissionId: submission.id, submissionState, itemState: item.attributes?.state || "unknown" });
      }
    }
  }
  return items;
}

const deletableVersionStates = new Set([
  "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"
]);

export async function expireObsoleteVersions({ api = createClient(), apply = false } = {}) {
  const appResponse = await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(APP_BUNDLE)}&limit=1`);
  const app = appResponse.parsed?.data?.[0];
  if (!appResponse.ok || app?.type !== "apps" || typeof app.id !== "string") {
    throw new Error(`CodeCaps App Store record lookup failed (HTTP ${appResponse.status})`);
  }
  const inventory = await readInventory(api, app.id);
  const reviewItems = await readReviewItems(api, app.id, inventory.versions);
  const reviewVersionIds = new Set(reviewItems.map((item) => item.versionId));
  const builds = inventory.builds.filter((row) => row.version !== KEEP_VERSION && !row.expired);
  const versionsToDelete = inventory.versions.filter((row) => row.version !== KEEP_VERSION && deletableVersionStates.has(row.state));
  const protectedVersions = inventory.versions.filter((row) => row.version !== KEEP_VERSION
    && !deletableVersionStates.has(row.state) && !reviewVersionIds.has(row.id));
  if (!apply) {
    return { dryRun: true, keptVersion: KEEP_VERSION,
      buildsToExpire: builds.map(({ build, version }) => ({ build, version })),
      appStoreVersionsToDelete: versionsToDelete.map(({ version, state }) => ({ version, state })),
      reviewItemsToRemove: reviewItems.map(({ version, versionState, submissionState, itemState }) => ({
        version, versionState, submissionState, itemState
      })),
      protectedVersions: protectedVersions.map(({ version, state }) => ({ version, state })) };
  }

  for (const row of builds) {
    const response = await api("PATCH", `/v1/builds/${encodeURIComponent(row.id)}`, JSON.stringify({
      data: { type: "builds", id: row.id, attributes: { expired: true } }
    }));
    if (!response.ok) throw new Error(`TestFlight build ${row.build} (${row.version}) failed to expire (HTTP ${response.status})`);
  }
  for (const item of reviewItems) {
    const response = await api("DELETE", `/v1/reviewSubmissionItems/${encodeURIComponent(item.id)}`);
    if (!response.ok) {
      throw new Error(`App Store version ${item.version} could not be removed from ${item.submissionState} review (HTTP ${response.status})`);
    }
  }

  const afterReviewRemoval = await readInventory(api, app.id);
  const versionsToDeleteNow = afterReviewRemoval.versions.filter((row) => row.version !== KEEP_VERSION
    && deletableVersionStates.has(row.state));
  for (const row of versionsToDeleteNow) {
    const response = await api("DELETE", `/v1/appStoreVersions/${encodeURIComponent(row.id)}`);
    if (!response.ok) throw new Error(`App Store version ${row.version} failed to delete (HTTP ${response.status})`);
  }

  const verified = await readInventory(api, app.id);
  const remainingReviewItems = await readReviewItems(api, app.id, verified.versions);
  const activeBuilds = verified.builds.filter((row) => row.version !== KEEP_VERSION && !row.expired);
  const remainingDeletableVersions = verified.versions.filter((row) => row.version !== KEEP_VERSION && deletableVersionStates.has(row.state));
  const remainingProtected = verified.versions.filter((row) => row.version !== KEEP_VERSION && !deletableVersionStates.has(row.state));
  const result = { dryRun: false, keptVersion: KEEP_VERSION, expiredBuilds: builds.length,
    removedFromReview: reviewItems.map(({ version, submissionState }) => ({ version, submissionState })),
    deletedAppStoreVersions: versionsToDeleteNow.map(({ version }) => version),
    remainingOldActiveBuilds: activeBuilds.length,
    remainingDeletableAppStoreVersions: remainingDeletableVersions.map(({ version, state }) => ({ version, state })),
    remainingOldReviewItems: remainingReviewItems.map(({ version, submissionState }) => ({ version, submissionState })),
    protectedVersions: remainingProtected.map(({ version, state }) => ({ version, state })) };
  if (activeBuilds.length || remainingDeletableVersions.length || remainingReviewItems.length || remainingProtected.length) process.exitCode = 3;
  return result;
}

async function main() {
  const [bundle, keepVersion, action] = process.argv.slice(2);
  if (bundle !== APP_BUNDLE || keepVersion !== KEEP_VERSION || ![undefined, "--apply", "--dry-run"].includes(action)) {
    console.error("Usage: expire-obsolete-codecaps-versions.mjs com.simplewithus.codecaps.ios 0.1.0 [--apply|--dry-run]");
    process.exitCode = 2;
    return;
  }
  try {
    const result = await expireObsoleteVersions({ apply: action === "--apply" });
    if (result.protectedVersions.length) {
      console.error(`${result.protectedVersions.length} older App Store version(s) are not editable drafts and remain protected`);
    }
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(`expire-obsolete-codecaps-versions: ${error.message}`);
    process.exitCode = 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
