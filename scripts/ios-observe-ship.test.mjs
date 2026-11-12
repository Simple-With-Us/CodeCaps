// Offline tests for scripts/ios-observe-ship.mjs upload/skip detection.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  UPLOADED_LINE_RES,
  SKIPPED_LINE_RES,
  createStreamScanner,
  feedStreamChunk,
  finishStreamScan,
} from "./ios-observe-ship.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OBSERVE = join(ROOT, "scripts/ios-observe-ship.mjs");

const PREFIX = "[ios-ship] ";

function runFakeShip(logText, exitCode = 0) {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const outFile = join(dir, "github-output");
  const fake = join(dir, "fake-ship.sh");
  writeFileSync(
    fake,
    `#!/usr/bin/env bash
printf '%s' "$LOG"
exit "$RC"
`,
    { mode: 0o755 },
  );
  const env = {
    ...process.env,
    GITHUB_OUTPUT: outFile,
    LOG: logText,
    RC: String(exitCode),
  };
  const result = spawnSync(process.execPath, [OBSERVE, fake], { encoding: "utf8", env });
  let recorded = "";
  try {
    recorded = readFileSync(outFile, "utf8");
  } catch {
    recorded = "";
  }
  rmSync(dir, { recursive: true, force: true });
  return { ...result, recorded };
}

test("anchored line match does not phantom-upload across stream halves", () => {
  const stdout = createStreamScanner();
  const stderr = createStreamScanner();
  feedStreamChunk("noise build 123", stdout);
  feedStreamChunk(" submitted for TestFlight\n", stderr);
  const uploaded =
    finishStreamScan(stdout).uploaded || finishStreamScan(stderr).uploaded;
  assert.equal(uploaded, false);
});

test("upload marker must be a full prefixed line", () => {
  const state = createStreamScanner();
  feedStreamChunk(
    `prefix ${PREFIX}upload path succeeded via xcodebuild export (destination=upload) suffix\n`,
    state,
  );
  assert.equal(finishStreamScan(state).uploaded, false);
  const bare = createStreamScanner();
  feedStreamChunk("upload path succeeded via xcodebuild export (destination=upload)\n", bare);
  assert.equal(finishStreamScan(bare).uploaded, false);
  const prefixed = createStreamScanner();
  feedStreamChunk(
    `${PREFIX}upload path succeeded via xcodebuild export (destination=upload)\n`,
    prefixed,
  );
  assert.equal(finishStreamScan(prefixed).uploaded, true);
});

test("bare upload markers without [ios-ship] prefix yield uploaded=false", () => {
  const r = runFakeShip(
    "upload path succeeded via xcodebuild export (destination=upload)\n",
    0,
  );
  assert.equal(r.status, 0);
  assert.match(r.recorded, /uploaded=false/);
});

test("prefixed upload markers from log() yield uploaded=true", () => {
  const r = runFakeShip(
    `${PREFIX}upload path succeeded via xcodebuild export (destination=upload)\n`,
    0,
  );
  assert.equal(r.status, 0);
  assert.match(r.recorded, /uploaded=true/);
  assert.match(r.recorded, /ship_observed=uploaded/);
});

test("gate-skip logs yield uploaded=false when prefixed", () => {
  const r = runFakeShip(
    `${PREFIX}ship-gate: exiting 0 before any version is resolved (nothing consumed)\n`,
    0,
  );
  assert.equal(r.status, 0);
  assert.match(r.recorded, /uploaded=false/);
  assert.match(r.recorded, /ship_observed=skipped/);
});

test("bare gate-skip marker without prefix is not treated as skip", () => {
  const r = runFakeShip(
    "ship-gate: exiting 0 before any version is resolved (nothing consumed)\n",
    0,
  );
  assert.equal(r.status, 0);
  assert.match(r.recorded, /uploaded=false/);
  assert.doesNotMatch(r.recorded, /ship_observed=skipped/);
});

test("spawn failure writes uploaded=false and exits nonzero", () => {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const outFile = join(dir, "github-output");
  const result = spawnSync(
    process.execPath,
    [OBSERVE, "/nonexistent/ios-observe-ship-test-cmd"],
    { encoding: "utf8", env: { ...process.env, GITHUB_OUTPUT: outFile } },
  );
  const recorded = readFileSync(outFile, "utf8");
  rmSync(dir, { recursive: true, force: true });
  assert.notEqual(result.status, 0);
  assert.match(recorded, /uploaded=false/);
  assert.match(recorded, /ship_observed=spawn_error/);
});

test("UPLOADED_LINE_RES patterns match prefixed ship-testflight.sh log lines only", () => {
  assert.ok(
    UPLOADED_LINE_RES.some((re) =>
      re.test(`${PREFIX}upload submitted; watch TestFlight processing for com.example`),
    ),
  );
  assert.ok(
    !UPLOADED_LINE_RES.some((re) =>
      re.test("upload submitted; watch TestFlight processing for com.example"),
    ),
  );
  assert.ok(!UPLOADED_LINE_RES.some((re) => re.test("build 281 submitted for review")));
  assert.ok(
    SKIPPED_LINE_RES.some((re) =>
      re.test(`${PREFIX}ship-gate: exiting 0 before any version is resolved (nothing consumed)`),
    ),
  );
  assert.ok(
    !SKIPPED_LINE_RES.some((re) =>
      re.test("ship-gate: exiting 0 before any version is resolved (nothing consumed)"),
    ),
  );
});
