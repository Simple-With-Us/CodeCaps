// Contract for the iOS auto-ship pipeline (.github/workflows/ios-ship.yml).
//
// Owner 2026-10-17: a merge to main that touches the iOS native tree uploads a
// fresh TestFlight build with no human step.  These checks pin every piece of
// that wiring so a refactor cannot quietly turn the pipeline back into a manual
// one.  The gap that prompted them: the app and widget targets compile shared
// Sources/QuotaCore files, and a QuotaCore-only change never shipped because
// the paths filter and the scheduled gate only knew ios/CodeCapsCompanion/**.
//
// Run: node --test scripts/ios-ship-workflow.test.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function read(rel) {
  return readFileSync(join(ROOT, rel), "utf8");
}

function withoutComments(text) {
  return text
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");
}

const workflow = read(".github/workflows/ios-ship.yml");
const code = withoutComments(workflow);

/** The top-level `on:` mapping, up to the next top-level key. */
function onBlock(yml) {
  const m = yml.match(/^on:\n((?:[ \t]+.*\n|[ \t]*#.*\n|\n)*)/m);
  assert.ok(m, "ios-ship.yml must declare an on: block");
  return withoutComments(m[1]);
}

/** The `on.push.paths` entries (including any `!` exclusions), in order. */
function pushPaths() {
  const on = onBlock(workflow);
  const push = on.match(/^ {2}push:\n((?: {4}.*\n|\n)*)/m);
  assert.ok(push, "on.push must exist");
  const paths = push[1].match(/^ {4}paths:\n((?: {6}.*\n|\n)*)/m);
  assert.ok(paths, "on.push.paths must exist");
  return [...paths[1].matchAll(/^ {6}- '([^']+)'$/gm)].map((m) => m[1]);
}

/** Every `--path-prefix` argument the scheduled gate is called with. */
function gatePrefixes() {
  return [...code.matchAll(/--path-prefix '([^']+)'/g)].map((m) => m[1]);
}

/** Shared files the iOS and widget targets compile, from project.yml. */
function projectQuotaCoreFiles() {
  const yml = read("ios/CodeCapsCompanion/project.yml");
  const files = new Set(
    [...yml.matchAll(/path:\s*\.\.\/\.\.\/(Sources\/QuotaCore\/[A-Za-z0-9_+.-]+\.swift)/g)].map((m) => m[1]),
  );
  return files;
}

/** GitHub `paths:` glob match: `**` crosses directories, `*` does not. */
function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      re += ".*";
      i++;
    } else if (c === "*") {
      re += "[^/]*";
    } else if (c === "?") {
      re += "[^/]";
    } else {
      re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
    }
  }
  return new RegExp(`^${re}$`);
}

/** Would a push touching `file` start ios-ship.yml?  Later `!` entries exclude. */
function triggers(file, paths = pushPaths()) {
  let hit = false;
  for (const p of paths) {
    if (p.startsWith("!")) {
      if (hit && globToRegExp(p.slice(1)).test(file)) hit = false;
    } else if (globToRegExp(p).test(file)) {
      hit = true;
    }
  }
  return hit;
}

test("ios-ship.yml ships automatically on a merge that touches the native tree", () => {
  const on = onBlock(workflow);

  assert.match(on, /push:\s*\n\s+branches:\s*\[main\]/);
  assert.ok(pushPaths().includes("ios/CodeCapsCompanion/**"), "the iOS tree must be a push path");
  assert.ok(pushPaths().includes(".github/workflows/ios-ship.yml"), "editing the workflow must re-ship");
  assert.match(on, /workflow_dispatch:/);

  // A scheduled catch-up is allowed only behind the scheduled path gate.
  if (/^\s+schedule:/m.test(on)) {
    assert.match(code, /scheduled-ship-gate\.sh/);
    assert.match(code, /--event "\$\{\{ github\.event_name \}\}"/);
    assert.ok(gatePrefixes().includes("ios/CodeCapsCompanion/"), "the gate must watch the iOS tree");
  }

  // The gate diffs against an older sha, and the notes need the commit range.
  assert.ok((code.match(/fetch-depth:\s*0/g) || []).length >= 2, "gate and ship checkouts need fetch-depth: 0");
  // What to Test is mandatory and published, never dry-rendered.
  assert.match(code, /IOS_TF_RELEASE_NOTES:\s*"1"/);
  // Ship through the wrapper that runs ship-testflight.sh (ensure-tf-ready inside).
  assert.match(code, /run: bash scripts\/ios-ship-testflight\.sh\s*$/m);
  assert.match(read("scripts/ios-fleet/ship-testflight.sh"), /ensure-tf-ready/);
  // Hosted macOS with the stable-Xcode guard, never a self-hosted label.
  assert.match(code, /runs-on:\s*macos-latest/);
  assert.doesNotMatch(code, /runs-on:\s*\[?\s*self-hosted/);
  assert.match(code, /Assert stable Xcode/);
  assert.match(code, /github\.event\.repository\.fork == false/);
});

test("every shared file the iOS targets compile ships a build when it changes", () => {
  const compiled = projectQuotaCoreFiles();
  assert.ok(compiled.size >= 8, `project.yml should reference the QuotaCore files, found ${compiled.size}`);

  const paths = pushPaths();
  const prefixes = gatePrefixes();
  for (const file of compiled) {
    assert.ok(triggers(file, paths), `${file} is compiled by an iOS target but is not an on.push.paths entry`);
    assert.ok(prefixes.includes(file), `${file} is compiled by an iOS target but is not a scheduled-gate --path-prefix`);
  }

  // The reverse: no QuotaCore file the iOS targets do not compile, and no
  // directory wildcard.  Mac-only QuotaCore edits must not ship TestFlight.
  const listed = [...paths, ...prefixes].filter((p) => p.startsWith("Sources/"));
  for (const p of listed) {
    assert.doesNotMatch(p, /\*/, `${p}: use exact files, a wildcard would ship on Mac-only edits`);
    assert.ok(compiled.has(p), `${p} is listed but no iOS target compiles it`);
  }
  assert.equal(triggers("Sources/QuotaCore/InfisicalSettings.swift", paths), false);
  assert.equal(triggers("Sources/CodeCaps/MenuBarController.swift", paths), false);
});

test("push paths trigger on the native tree and not on test-only changes", () => {
  const paths = pushPaths();
  assert.equal(triggers("ios/CodeCapsCompanion/App/Views/CompanionContentView.swift", paths), true);
  assert.equal(triggers("ios/CodeCapsCompanion/project.yml", paths), true);
  assert.equal(triggers("Sources/QuotaCore/ResetAlarmTracker.swift", paths), true);
  assert.equal(triggers("scripts/ios-fleet/ship-testflight.sh", paths), true);
  assert.equal(triggers("scripts/ios-fleet/test-scheduled-ship-gate.sh", paths), false);
  assert.equal(triggers("Sources/CodeCaps/AppDelegate.swift", paths), false);
  assert.equal(triggers("README.md", paths), false);
});

test("ASC credentials come from Fleet-OPS /asc, never the stale repository secrets", () => {
  // The repository ASC_* secrets are a revoked copy (HTTP 401, CC-163).
  assert.doesNotMatch(code, /secrets\.ASC_KEY_ID/);
  assert.doesNotMatch(code, /secrets\.ASC_ISSUER_ID/);
  assert.doesNotMatch(code, /secrets\.ASC_KEY_P8/);
  assert.doesNotMatch(code, /ASC_KEY_(ID|P8):\s*\$\{\{/);

  // The project id is a secret, never a literal in this public file, and the
  // bare Infisical CLI is not used: it prints the value to stdout.
  assert.doesNotMatch(code, /8dae6d03/);
  assert.doesNotMatch(code, /ASC_INFISICAL_PROJECT_ID/);
  assert.match(code, /INFISICAL_PROJECT_ID: \$\{\{ secrets\.INFISICAL_FLEET_OPS_PROJECT_ID \}\}/);
  assert.match(code, /INFISICAL_SECRET_PATH: \/asc/);
  assert.match(code, /uses: \.\/\.github\/actions\/infisical-secrets/);
  assert.match(code, /secrets\.INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/);
  assert.doesNotMatch(code, /infisical secrets get/);
  assert.doesNotMatch(code, /infisical\/get-cli/);
  // No new code may talk to the vault directly.
  assert.doesNotMatch(code, /listSecretsRaw|loginUniversalAuth/);

  // The multiline key never enters the step environment.  The loader reads
  // the vault itself and streams the key over stdin into a mode-600 file, so
  // only the file's path crosses into the later steps and the workflow never
  // names the private key.
  assert.match(code, /scripts\/stage-asc-key\.mjs/);
  assert.match(readFileSync(join(ROOT, "scripts/stage-asc-key.mjs"), "utf8"), /ios-stage-asc-key\.sh/);
  assert.doesNotMatch(code, /for name in .*ASC_KEY_P8/);
  assert.doesNotMatch(code, /printf '%s=%s\\n' "ASC_KEY_P8"/);
  assert.doesNotMatch(code, /ASC_KEY_P8/);

  // The Distribution identity stays a repository secret, scoped to its step.
  assert.match(code, /IOS_DIST_P12_BASE64:\s*\$\{\{ secrets\.IOS_DIST_P12_BASE64 \}\}/);

  // `secrets.*` in `if:` kills the whole workflow at dispatch time.
  assert.doesNotMatch(code, /if:.*secrets\./);

  const prepare = read("scripts/ios-appstore-gm-prepare.sh");
  assert.match(prepare, /ASC_KEY_P8 or ASC_KEY_PATH required/);
  assert.doesNotMatch(prepare, /echo "\$ASC_KEY_P8"/);
  assert.doesNotMatch(prepare, /echo "\$IOS_DIST_P12/);
});

test("the ship carries no standing gate override and always publishes What to Test", () => {
  assert.doesNotMatch(code, /IOS_TF_MIN_INTERVAL_SEC/);
  assert.doesNotMatch(code, /--force-ship/);
  assert.doesNotMatch(code, /IOS_TF_RELEASE_NOTES:\s*"0"/);
  assert.doesNotMatch(code, /allow-unverified-seq/);
});

test("ship state cache is keyed apart from the Mac ship", () => {
  const keys = [...code.matchAll(/ios-fleet-state-codecaps-[a-z]*-?/g)].map((m) => m[0]);
  assert.ok(keys.length >= 6, "gate and ship restore and save the state cache");
  for (const k of keys) assert.equal(k, "ios-fleet-state-codecaps-ios-", `bare prefix ${k} also matches the Mac ship cache`);
});

test("the marketing train is 1.0.N and release notes use the owner clock", () => {
  const apps = JSON.parse(read("scripts/ios-fleet/apps.json"));
  assert.match(apps.apps.codecaps.marketingVersionDefault, /^1\.0\.\d+$/);

  const src = read("scripts/ios-fleet/asc-api.mjs");
  const fn = src.match(/function centralTimestamp[\s\S]*?\n}\n/)[0];
  assert.doesNotMatch(fn, /\bCT\b[`"']/);
  assert.match(fn, /toLowerCase\(\)/);
});

test("scheduled gate and key handoff shell tests pass", () => {
  for (const script of ["scripts/ios-fleet/test-scheduled-ship-gate.sh", "scripts/test-ios-stage-asc-key.sh"]) {
    const out = execFileSync("bash", [join(ROOT, script)], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    assert.match(out, /all tests passed/, `${script} did not report success`);
  }
});
