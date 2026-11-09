#!/usr/bin/env node
/**
 * Wrap ios-ship-testflight.sh so Actions can gate post-sync recheck on a real
 * upload. Skipped ships (rate/same-HEAD gate) must not look like uploaded == true.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

/** Max partial line retained across chunks (not the full xcodebuild log). */
const LINE_TAIL_MAX = 512;

export const UPLOADED_LINE_RES = [
  /^upload path succeeded via xcodebuild export \(destination=upload\)/,
  /^upload submitted; watch TestFlight processing/,
];
export const SKIPPED_LINE_RES = [
  /^ship-gate: exiting 0 before any version is resolved \(nothing consumed\)/,
];

/**
 * Incrementally match anchored ship-log lines without retaining the full stream.
 * @param {string} chunk
 * @param {{ partial: string, uploaded: boolean, skipped: boolean }} state
 */
export function feedStreamChunk(chunk, state) {
  const text = state.partial + chunk;
  const parts = text.split(/\r?\n/);
  state.partial = parts.pop() ?? "";
  if (state.partial.length > LINE_TAIL_MAX) {
    state.partial = state.partial.slice(-LINE_TAIL_MAX);
  }
  for (const line of parts) {
    if (UPLOADED_LINE_RES.some((re) => re.test(line))) {
      state.uploaded = true;
    }
    if (SKIPPED_LINE_RES.some((re) => re.test(line))) {
      state.skipped = true;
    }
  }
}

/** @param {{ partial: string, uploaded: boolean, skipped: boolean }} state */
export function finishStreamScan(state) {
  const tail = state.partial.trimEnd();
  if (tail) {
    if (UPLOADED_LINE_RES.some((re) => re.test(tail))) {
      state.uploaded = true;
    }
    if (SKIPPED_LINE_RES.some((re) => re.test(tail))) {
      state.skipped = true;
    }
  }
  return { uploaded: state.uploaded, skipped: state.skipped };
}

export function createStreamScanner() {
  return { partial: "", uploaded: false, skipped: false };
}

function writeOutputs(outputs, uploaded, observed) {
  if (!outputs) {
    return;
  }
  fs.appendFileSync(outputs, `uploaded=${uploaded ? "true" : "false"}\n`);
  fs.appendFileSync(outputs, `ship_observed=${observed}\n`);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];

async function main() {
  const cmd = process.argv.slice(2);
  if (cmd.length === 0) {
    console.error("usage: ios-observe-ship.mjs <command> [args...]");
    process.exit(2);
  }

  const outputs = process.env.GITHUB_OUTPUT?.trim();
  const stdoutScan = createStreamScanner();
  const stderrScan = createStreamScanner();

  const child = spawn(cmd[0], cmd.slice(1), {
    stdio: ["inherit", "pipe", "pipe"],
    shell: false,
  });

  child.stdout.on("data", (chunk) => {
    feedStreamChunk(chunk.toString(), stdoutScan);
    process.stdout.write(chunk);
  });
  child.stderr.on("data", (chunk) => {
    feedStreamChunk(chunk.toString(), stderrScan);
    process.stderr.write(chunk);
  });

  const exitPromise = new Promise((resolve) => {
    let settled = false;
    const done = (result) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(result);
    };
    child.on("error", (err) => {
      const msg = `ios-observe-ship: spawn failed: ${err?.message ?? err}\n`;
      process.stderr.write(msg);
      feedStreamChunk(msg, stderrScan);
      writeOutputs(outputs, false, "spawn_error");
      done({ code: 1, signal: null, spawnFailed: true });
    });
    child.on("close", (code, signal) => {
      done({ code: code ?? (signal ? 1 : 0), signal, spawnFailed: false });
    });
  });

  const { code, spawnFailed } = await exitPromise;

  if (spawnFailed) {
    process.exit(1);
  }

  const out = finishStreamScan(stdoutScan);
  const err = finishStreamScan(stderrScan);
  const uploaded = out.uploaded || err.uploaded;
  const skipped = out.skipped || err.skipped;

  let observed = "none";
  if (uploaded) {
    observed = "uploaded";
  } else if (skipped) {
    observed = "skipped";
  } else if (code === 0) {
    observed = "unknown_success";
  }

  writeOutputs(outputs, uploaded, observed);
  process.exit(code);
}

if (isMain) {
  await main();
}
