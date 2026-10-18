// Contract for the Mac auto-ship pipeline (.github/workflows/macos-ship.yml).
//
// Owner 2026-10-17: a merge to main that touches the Mac app's native tree
// uploads a fresh TestFlight build with no human step.  These checks pin every
// piece of that wiring so a refactor cannot quietly turn the pipeline back into
// a manual one.  The gap that prompted them: macos-ship.yml was
// workflow_dispatch only, read the stale ASC_* repository secrets (HTTP 401),
// and sat on the retired 0.1.N marketing train, so CodeCaps for Mac stayed at
// 0.1.12 while main moved on.
//
// The Mac TestFlight app is built from the Xcode project in
// ios/CodeCapsCompanion (scheme CodeCapsCompanionMac), plus the shared
// Sources/QuotaCore files its targets compile.  It is NOT the SwiftPM tree
// under Sources/, which is the Sparkle app owned by mac-release.yml.
//
// Run: node --test scripts/macos-ship-workflow.test.mjs
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

const workflow = read(".github/workflows/macos-ship.yml");
const code = withoutComments(workflow);
const iosCode = withoutComments(read(".github/workflows/ios-ship.yml"));

/** The top-level `on:` mapping, up to the next top-level key. */
function onBlock(yml) {
  const m = yml.match(/^on:\n((?:[ \t]+.*\n|[ \t]*#.*\n|\n)*)/m);
  assert.ok(m, "macos-ship.yml must declare an on: block");
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

/** Shared files the two Mac targets compile, from project.yml. */
function macQuotaCoreFiles() {
  const yml = read("ios/CodeCapsCompanion/project.yml");
  const start = yml.indexOf("\n  CodeCapsCompanionMac:");
  const end = yml.indexOf("\nschemes:");
  assert.ok(start > 0 && end > start, "project.yml must define the Mac targets before schemes:");
  const macTargets = yml.slice(start, end);
  assert.match(macTargets, /\n  CodeCapsWidgetsMac:/, "the Mac widget target must follow the Mac app target");
  return new Set(
    [...macTargets.matchAll(/path:\s*\.\.\/\.\.\/(Sources\/QuotaCore\/[A-Za-z0-9_+.-]+\.swift)/g)].map((m) => m[1]),
  );
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

/** Would a push touching `file` start macos-ship.yml?  Later `!` entries exclude. */
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

/** The text of one step of a workflow, by exact step name. */
function stepBlock(yml, name) {
  const lines = yml.split("\n");
  const start = lines.findIndex((l) => l === `      - name: ${name}`);
  assert.ok(start >= 0, `step "${name}" must exist`);
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^ {6}- /.test(lines[i]) || /^ {2}\S/.test(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}

test("macos-ship.yml ships automatically on a merge that touches the native tree", () => {
  const on = onBlock(workflow);

  assert.match(on, /push:\s*\n\s+branches:\s*\[main\]/);
  assert.ok(pushPaths().includes("ios/CodeCapsCompanion/**"), "the Xcode project tree must be a push path");
  assert.ok(pushPaths().includes(".github/workflows/macos-ship.yml"), "editing the workflow must re-ship");
  assert.match(on, /workflow_dispatch:/);

  // A scheduled catch-up is allowed only behind the scheduled path gate, and
  // the gate must read the state file the Mac ship writes (codecaps-mac).
  if (/^\s+schedule:/m.test(on)) {
    assert.match(code, /scheduled-ship-gate\.sh/);
    assert.match(code, /--event "\$\{\{ github\.event_name \}\}"/);
    assert.ok(gatePrefixes().includes("ios/CodeCapsCompanion/"), "the gate must watch the Xcode project tree");
    assert.match(code, /--repo-root "\$GITHUB_WORKSPACE" \\\n\s+codecaps-mac\s*$/m);
  }

  // The gate diffs against an older sha, and the notes need the commit range.
  assert.ok((code.match(/fetch-depth:\s*0/g) || []).length >= 2, "gate and ship checkouts need fetch-depth: 0");
  // The Swift CI wait runs before the Mac runner starts.
  assert.match(code, /bash scripts\/await-swift-ci-checks\.sh/);
  // What to Test is mandatory and published, never dry-rendered.
  assert.match(code, /IOS_TF_RELEASE_NOTES:\s*"1"/);
  // Ship through the wrapper that runs ship-testflight.sh codecaps-mac
  // (ensure-tf-ready inside).
  assert.match(code, /run: bash scripts\/mac-ship-testflight\.sh\s*$/m);
  assert.match(read("scripts/mac-ship-testflight.sh"), /exec bash "\$IN_REPO" codecaps-mac /);
  assert.match(read("scripts/ios-fleet/ship-testflight.sh"), /ensure-tf-ready/);
  // Hosted macOS with the stable-Xcode guard, never a self-hosted label.
  assert.match(code, /runs-on:\s*macos-latest/);
  assert.doesNotMatch(code, /runs-on:\s*\[?\s*self-hosted/);
  assert.match(code, /Assert stable Xcode/);
  assert.match(code, /github\.event\.repository\.fork == false/);
  // TestFlight ships come from main only.
  assert.match(code, /github\.ref == 'refs\/heads\/main'/);
  // A later push queues behind an upload in flight instead of cancelling it.
  assert.match(code, /concurrency:\s*\n\s+group: macos-ship-codecaps\s*\n\s+cancel-in-progress: false/);
});

test("every shared file the Mac targets compile ships a build when it changes", () => {
  const compiled = macQuotaCoreFiles();
  assert.ok(compiled.size >= 8, `project.yml should reference the QuotaCore files, found ${compiled.size}`);

  const paths = pushPaths();
  const prefixes = gatePrefixes();
  for (const file of compiled) {
    assert.ok(triggers(file, paths), `${file} is compiled by a Mac target but is not an on.push.paths entry`);
    assert.ok(prefixes.includes(file), `${file} is compiled by a Mac target but is not a scheduled-gate --path-prefix`);
  }

  // The reverse: no QuotaCore file the Mac targets do not compile, and no
  // directory wildcard.  Edits to the rest of QuotaCore must not ship TestFlight.
  const listed = [...paths, ...prefixes].filter((p) => p.startsWith("Sources/"));
  for (const p of listed) {
    assert.doesNotMatch(p, /\*/, `${p}: use exact files, a wildcard would ship on unrelated edits`);
    assert.ok(compiled.has(p), `${p} is listed but no Mac target compiles it`);
  }
  assert.equal(triggers("Sources/QuotaCore/InfisicalSettings.swift", paths), false);
  // The SwiftPM tree is the Sparkle app (mac-release.yml), a different product.
  assert.equal(triggers("Sources/CodeCaps/MenuBarController.swift", paths), false);
  assert.equal(triggers("Package.swift", paths), false);
});

test("the Mac and iOS ships watch the same shared files, because the targets share them", () => {
  const iosYml = read(".github/workflows/ios-ship.yml");
  const iosSources = [...iosYml.matchAll(/^ {6}- '(Sources\/QuotaCore\/[^']+)'$/gm)].map((m) => m[1]).sort();
  const macSources = pushPaths().filter((p) => p.startsWith("Sources/")).sort();
  assert.deepEqual(macSources, iosSources, "ios-ship.yml and macos-ship.yml list different QuotaCore files");
});

test("push paths trigger on the native tree and not on test-only changes", () => {
  const paths = pushPaths();
  assert.equal(triggers("ios/CodeCapsCompanion/App/Views/CompanionContentView.swift", paths), true);
  assert.equal(triggers("ios/CodeCapsCompanion/App/InfoMac.plist", paths), true);
  assert.equal(triggers("ios/CodeCapsCompanion/project.yml", paths), true);
  assert.equal(triggers("Sources/QuotaCore/ResetAlarmTracker.swift", paths), true);
  assert.equal(triggers("scripts/ios-fleet/ship-testflight.sh", paths), true);
  assert.equal(triggers("scripts/mac-ship-testflight.sh", paths), true);
  assert.equal(triggers("scripts/mac-appstore-gm-prepare.sh", paths), true);
  assert.equal(triggers("scripts/ios-fleet/test-scheduled-ship-gate.sh", paths), false);
  assert.equal(triggers("Sources/CodeCaps/AppDelegate.swift", paths), false);
  assert.equal(triggers("docs/IOS-TESTFLIGHT.md", paths), false);
  assert.equal(triggers("README.md", paths), false);
});

test("ASC credentials come from Fleet-OPS /asc, never the stale repository secrets", () => {
  // The repository ASC_* secrets are a revoked copy (HTTP 401, CC-163).
  assert.doesNotMatch(code, /secrets\.ASC_KEY_ID/);
  assert.doesNotMatch(code, /secrets\.ASC_ISSUER_ID/);
  assert.doesNotMatch(code, /secrets\.ASC_KEY_P8/);
  assert.doesNotMatch(code, /ASC_KEY_(ID|P8):\s*\$\{\{/);

  assert.match(code, /ASC_INFISICAL_PROJECT_ID:\s*8dae6d03-8f12-48b2-adf3-e5c1b881c8c5/);
  assert.match(code, /--path=\/asc/);
  assert.match(code, /infisical login --method=universal-auth/);
  assert.match(code, /secrets\.INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/);

  // The multiline key goes to a mode-600 file, never GITHUB_ENV.
  assert.match(code, /scripts\/ios-stage-asc-key\.sh/);
  assert.doesNotMatch(code, /for name in .*ASC_KEY_P8/);

  // The load step is a verbatim copy of ios-ship.yml's, so a fix to one cannot
  // silently skip the other.
  const step = "Load ASC credentials (Fleet-OPS prod /asc)";
  assert.equal(stepBlock(code, step), stepBlock(iosCode, step), "the ASC load step drifted from ios-ship.yml");

  // The signing identities stay repository secrets, scoped to the import step.
  const imports = stepBlock(code, "Import signing identities");
  for (const name of ["IOS_DIST_P12_BASE64", "IOS_DIST_P12_PASSWORD", "MAC_INSTALLER_P12_BASE64", "MAC_INSTALLER_P12_PASSWORD"]) {
    assert.match(imports, new RegExp(`${name}:\\s*\\$\\{\\{ secrets\\.${name} \\}\\}`), `${name} must reach the import step`);
    assert.equal((code.match(new RegExp(`secrets\\.${name}`, "g")) || []).length, 1, `${name} must not leak into other steps`);
  }
  assert.match(imports, /mac-appstore-gm-prepare\.sh/);

  // `secrets.*` in `if:` kills the whole workflow at dispatch time.
  assert.doesNotMatch(code, /if:.*secrets\./);

  const prepare = read("scripts/mac-appstore-gm-prepare.sh");
  assert.match(prepare, /ASC_KEY_P8 or ASC_KEY_PATH required/);
  assert.match(prepare, /KEY_PATH="\$\{ASC_KEY_PATH:-/);
  assert.doesNotMatch(prepare, /echo "\$ASC_KEY_P8"/);
  assert.doesNotMatch(prepare, /echo "\$IOS_DIST_P12/);
  assert.doesNotMatch(prepare, /echo "\$MAC_INSTALLER_P12/);
});

test("the ship carries no standing gate override and always publishes What to Test", () => {
  assert.doesNotMatch(code, /IOS_TF_MIN_INTERVAL_SEC/);
  assert.doesNotMatch(code, /--force-ship/);
  assert.doesNotMatch(code, /IOS_TF_RELEASE_NOTES:\s*"0"/);
  assert.doesNotMatch(code, /allow-unverified-seq/);
  assert.doesNotMatch(code, /IOS_SHIP_PRIORITY/);
});

test("ship state cache is keyed apart from the iOS ship and from the retired 0.1.N sequence", () => {
  const keys = [...code.matchAll(/ios-fleet-state-codecaps-[A-Za-z0-9]*-?[A-Za-z0-9]*-?/g)].map((m) => m[0]);
  assert.ok(keys.length >= 6, "gate and ship restore and save the state cache");
  for (const k of keys) assert.equal(k, "ios-fleet-state-codecaps-mac-v1-", `${k} is not the Mac 1.0.N cache family`);
  // restore-keys match by prefix, so neither family may be a prefix of the other.
  const iosFamily = "ios-fleet-state-codecaps-ios-";
  assert.ok(!iosFamily.startsWith("ios-fleet-state-codecaps-mac-v1-") && !"ios-fleet-state-codecaps-mac-v1-".startsWith(iosFamily));
  assert.match(iosCode, /ios-fleet-state-codecaps-ios-/);
});

test("the marketing train is 1.0.N and the ship script targets codecaps-mac", () => {
  const apps = JSON.parse(read("scripts/ios-fleet/apps.json"));
  const mac = apps.apps["codecaps-mac"];
  assert.match(mac.marketingVersionDefault, /^1\.0\.\d+$/, "0.x.x versions are banned by AGENT-SYNC");
  assert.equal(mac.bundleId, "com.simplewithus.codecaps.macos");
  assert.equal(mac.scheme, "CodeCapsCompanionMac");
  assert.equal(mac.projectRel, "ios/CodeCapsCompanion/CodeCapsCompanion.xcodeproj");
});

test("the Mac profile map still names both Mac bundle ids", () => {
  const map = JSON.parse(read("ios/CodeCapsCompanion/mac-appstore-profiles.json"));
  assert.deepEqual(Object.keys(map).sort(), ["com.simplewithus.codecaps.macos", "com.simplewithus.codecaps.macos.widgets"]);
});

test("the shared gate and key-handoff shell tests still pass", () => {
  for (const script of ["scripts/ios-fleet/test-scheduled-ship-gate.sh", "scripts/test-ios-stage-asc-key.sh"]) {
    const out = execFileSync("bash", [join(ROOT, script)], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    assert.match(out, /all tests passed/, `${script} did not report success`);
  }
});
