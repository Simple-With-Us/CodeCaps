// Offline tests for scripts/ios-observe-ship.mjs upload/skip detection.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OBSERVE = join(ROOT, "scripts/ios-observe-ship.mjs");

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
  const result = spawnSync(
    process.execPath,
    [OBSERVE, fake],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        GITHUB_OUTPUT: outFile,
        LOG: logText,
        RC: String(exitCode),
      },
    },
  );
  const output = result.stdout + result.stderr;
  let recorded = "";
  try {
    recorded = readFileSync(outFile, "utf8");
  } catch {
    recorded = "";
  }
  rmSync(dir, { recursive: true, force: true });
  return { ...result, recorded, output };
}

test("gate-skip logs yield uploaded=false", () => {
  const r = runFakeShip("ship-gate: exiting 0 before any version is resolved (nothing consumed)\n", 0);
  assert.equal(r.status, 0);
  assert.match(r.recorded, /uploaded=false/);
  assert.match(r.recorded, /ship_observed=skipped/);
});

test("upload success logs yield uploaded=true", () => {
  const r = runFakeShip("upload path succeeded via xcodebuild export (destination=upload)\n", 0);
  assert.equal(r.status, 0);
  assert.match(r.recorded, /uploaded=true/);
  assert.match(r.recorded, /ship_observed=uploaded/);
});
