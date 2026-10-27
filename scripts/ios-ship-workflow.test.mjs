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
  assert.match(code, /bash scripts\/ios-ship-testflight\.sh\s*$/m);
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
  assert.match(code, /uses: \.\/\.github\/actions\/infisical-secrets/);
  // The Sentry step names the org secret that exists.  The repository has no
  // secret called INFISICAL_PROJECT_ID, so the vault leg resolved nothing and
  // the step fell through to the repository copies without saying so.
  assert.doesNotMatch(code, /project-id: \$\{\{ secrets\.INFISICAL_PROJECT_ID \}\}/);
  assert.match(code, /project-id: \$\{\{ secrets\.INFISICAL_FLEET_OPS_PROJECT_ID \}\}/);
  assert.match(code, /secrets\.INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/);
  assert.doesNotMatch(code, /infisical secrets get/);
  assert.doesNotMatch(code, /infisical\/get-cli/);
  // No new code may talk to the vault directly.
  assert.doesNotMatch(code, /listSecretsRaw|loginUniversalAuth/);

  // The multiline key never enters the step environment.  The tooling and
  // the staging script run in ONE step: the tooling brings the fleet's
  // reader onto the runner, the staging script resolves the three values
  // environment-first, streams the key over stdin into a mode-600 file and
  // removes the ASC_KEY_P8 entry, so only the file's path and the two
  // identifiers cross into the later steps.
  // The step names the tooling, and the tooling names the consumer that
  // resolves the values.
  assert.match(code, /scripts\/install-release-secrets-tooling\.sh/);
  // No workflow step reads the vault directly: the reader is the fleet's
  // own, and the staging script is the only thing that resolves a value.
  assert.doesNotMatch(code, /node scripts\/infisical-fetch\.mjs/);
  // The step is a single call to the tooling, and the tooling runs the
  // consumer in the same process tree, so the minted token reaches it
  // through its environment and never through a file.
  assert.match(code, /bash scripts\/install-release-secrets-tooling\.sh/);
  const tooling = readFileSync(join(ROOT, "scripts/install-release-secrets-tooling.sh"), "utf8");
  assert.match(tooling, /node "\$repo_root\/scripts\/stage-asc-key\.mjs"/);
  assert.doesNotMatch(tooling, /release-secrets-env\.sh/);
  // The minted token must never reach the log.  The guard names every output
  // helper the script has, because a regression that printed through `say` or
  // `fail` would leak the token while a guard that only matched `printf`
  // still passed.
  assert.doesNotMatch(tooling, /\b(say|echo|printf|fail)\b[^\n]*\$(token|\{token\})/);
  assert.doesNotMatch(code, /release-secrets-env\.sh/);
  assert.match(tooling, /export INFISICAL_TOKEN="\$token"/);
  assert.match(tooling, /export INFISICAL_FLEET_OPS_PROJECT_ID="\$project_id"/);
  // The consumer runs even when the tooling install fails, and the step
  // reports the status of the command that actually failed.
  assert.match(tooling, /install_rc=0[\s\S]*install_tooling \|\| install_rc=\$\?/);
  assert.match(tooling, /stage_rc=0[\s\S]*stage-asc-key\.mjs"? \|\| stage_rc=\$\?/);
  assert.match(tooling, /if \[ "\$install_rc" -ne 0 \]; then exit "\$install_rc"; fi/);
  assert.match(tooling, /exit "\$stage_rc"/);
  // The tooling is part of the ship, so a change to it runs the ship the
  // same way a change to any other ship script does.
  assert.match(code, /'scripts\/install-release-secrets-tooling\.sh'/);
  // The staging script resolves each value from process.env first and only
  // then through the approved reader, so a credential in the step's own
  // environment always wins over the vault.
  const stage = readFileSync(join(ROOT, "scripts/stage-asc-key.mjs"), "utf8");
  assert.match(stage, /process\.env[\s\S]*fleet-secrets/s);
  assert.ok(
    stage.indexOf("fromProcess.get(name)") < stage.indexOf("getSecret(name"),
    "the environment must be looked up before the approved reader",
  );
  // The vault is named where it is read: the step says which vault it
  // reads, and the staging script owns the folder inside it.
  assert.match(code, /Load and stage the ASC credentials \(Fleet-OPS prod \/asc\)/);
  assert.match(stage, /SECRET_FOLDER = '\/asc'/);
  // No step may ask the composite action for an ASC_* name: the action
  // writes every requested value into $GITHUB_ENV, which would put the
  // private key back into the environment of every later step.
  assert.doesNotMatch(code, /names: ASC_/);
  assert.match(readFileSync(join(ROOT, "scripts/stage-asc-key.mjs"), "utf8"), /ios-stage-asc-key\.sh/);
  // The key leaves the environment file with the entry itself removed, not
  // with a blank assignment that leaves the earlier bytes in the file for the
  // runner to import into a later step.
  assert.match(readFileSync(join(ROOT, "scripts/stage-asc-key.mjs"), "utf8"), /removeEnvironmentEntries/);
  assert.doesNotMatch(readFileSync(join(ROOT, "scripts/stage-asc-key.mjs"), "utf8"), /appendFileSync\(env\.GITHUB_ENV, 'ASC_KEY_P8=/);
  assert.doesNotMatch(code, /for name in .*ASC_KEY_P8/);
  assert.doesNotMatch(code, /printf '%s=%s\\n' "ASC_KEY_P8"/);
  // The workflow never writes the key into an environment entry itself.
  assert.doesNotMatch(code, /ASC_KEY_P8:\s*\$\{\{/);

  // The Distribution identity stays a repository secret, scoped to its step.
  assert.match(code, /IOS_DIST_P12_BASE64:\s*\$\{\{ secrets\.IOS_DIST_P12_BASE64 \}\}/);

  // `secrets.*` in `if:` kills the whole workflow at dispatch time.
  assert.doesNotMatch(code, /if:.*secrets\./);

  const prepare = read("scripts/ios-appstore-gm-prepare.sh");
  assert.match(prepare, /ASC_KEY_P8 or ASC_KEY_PATH required/);
  assert.doesNotMatch(prepare, /echo "\$ASC_KEY_P8"/);
  assert.doesNotMatch(prepare, /echo "\$IOS_DIST_P12/);
});

test("the ASC credential reaches every client through the environment, never a path", () => {
  // The clients refuse a path as a credential source (Kody rule 42), so the
  // shell layer that owns the credential has to hand it over in the
  // environment.  Every step that starts a client sources the loader first,
  // or the step runs with no credential at all and the failure reads like a
  // permission problem.
  const clients = [
    "ios-enable-apns.mjs",
    "ios-install-appstore-profiles.sh",
    "ios-ship-testflight.sh",
    "asc-api.mjs",
  ];
  const blocks = [...code.matchAll(/^[ ]*run: \|\n((?:[ ]{10,}.*\n|\n)*)/gm)].map((m) => m[1]);
  assert.ok(blocks.length >= 6, `the workflow should have several run blocks, found ${blocks.length}`);
  for (const client of clients) {
    const starters = blocks.filter((b) => b.includes(client));
    assert.ok(starters.length >= 1, `no run block starts ${client}`);
    for (const block of starters) {
      assert.match(
        block,
        /source scripts\/ios-load-asc-key\.sh/,
        `a step that starts ${client} must hand it the credential through the environment`,
      );
    }
  }

  // The removed subcommand must not come back:  asc-key.mjs has no exec.
  assert.doesNotMatch(code, /asc-key\.mjs exec/);
  assert.doesNotMatch(read("scripts/ios-fleet/asc-key.mjs"), /"exec"/);

  // The loader exports the key and never prints it.
  const loader = read("scripts/ios-load-asc-key.sh");
  assert.match(loader, /export ASC_KEY_P8/);
  assert.doesNotMatch(loader, /echo "\$pem"/);
  assert.doesNotMatch(loader, /echo "\$ASC_KEY_P8"/);
  assert.doesNotMatch(loader, /printf[^\n]*\$pem/);

  // The loader is part of the ship, so a change to it runs the ship.
  assert.ok(pushPaths().includes("scripts/ios-load-asc-key.sh"), "editing the loader must re-ship");
});

test("the version manifest publish names its cause and can write the CodeCaps row (CC-202)", () => {
  const ship = read("scripts/ios-fleet/ship-testflight.sh");
  const publish = read("scripts/ios-fleet/publish-ios-versions.sh");

  // The publisher's streams are never discarded, and its failure stays a
  // warning: the TestFlight upload that already succeeded must not fail.
  assert.doesNotMatch(ship, /publish-ios-versions\.sh[^|\n]*>\/dev\/null/);
  assert.match(ship, /publish_output="\$\(bash "\$\{FLEET_DIR\}\/publish-ios-versions\.sh"/);
  assert.match(ship, /version-manifest publish failed \(non-fatal, rc=\$\{publish_rc\}\)/);
  assert.match(publish, /HTTP \$\{API_STATUS\}/);
  assert.match(publish, /no IOS_VERSIONS_PUBLISH_TOKEN credential/);
  assert.match(publish, /contents:read on this repository and cannot write/);

  // The remote leg merges into the live manifest and writes through a
  // branch and pull request, because ai-fleet-coordinator main requires a
  // pull request and this job's token is contents:read here.
  assert.match(publish, /repos\/\$\{REPO\}\/git\/refs/);
  assert.match(publish, /repos\/\$\{REPO\}\/pulls/);
  assert.match(publish, /"branch": branch/);
  assert.doesNotMatch(publish, /gh api "\$\{ARGS\[@\]\}"/);
  assert.match(publish, /other app|every other app/);

  // The credential is the org GH_PAT secret, scoped to the ship step only,
  // and this job's own permissions stay read-only.
  assert.match(code, /IOS_VERSIONS_PUBLISH_TOKEN:\s*\$\{\{ secrets\.GH_PAT \}\}/);
  assert.match(code, /permissions:\s*\n\s+contents: read/);
  assert.doesNotMatch(code, /contents: write/);
  assert.doesNotMatch(code, /(echo|printf)[^\n]*IOS_VERSIONS_PUBLISH_TOKEN/);
  assert.match(publish, /CURL_CONFIG="\$\{WORK_DIR\}\/curl-config"/);
  assert.match(publish, /chmod 600 "\$CURL_CONFIG"/);
  assert.doesNotMatch(publish, /echo[^\n]*\$\{TOKEN\}/);
  assert.doesNotMatch(publish, /Authorization: Bearer \$\{TOKEN\}/);
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
  for (const script of [
    "scripts/ios-fleet/test-scheduled-ship-gate.sh",
    "scripts/ios-fleet/test-publish-ios-versions.sh",
    "scripts/test-ios-stage-asc-key.sh",
    "scripts/test-ios-load-asc-key.sh",
  ]) {
    // A shell test that fails says why on stderr, and the reason belongs in
    // the failure message:  a CI log that only says "Command failed" is a
    // dead end.
    let out = "";
    try {
      out = execFileSync("bash", [join(ROOT, script)], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      assert.fail(`${script} failed: ${String(error.stderr || "").trim() || error.message}`);
    }
    assert.match(out, /all tests passed/, `${script} did not report success`);
  }
});

// CC-200: the iOS lane never reached Sentry.  Two defects, both quiet.  The
// token in SENTRY_AUTH_TOKEN was the DSN, and a DSN is not an API token, so
// sentry-cli refused it in about seventy milliseconds.  The project was the
// app's own, while the events land in the project the shared fleet DSN names,
// so a dSYM in the wrong project never matches an event.  The failure was a
// warning line inside a green job.
const shipScript = read("scripts/ios-fleet/ship-testflight.sh");

test("the iOS lane loads the Sentry API token, not the DSN", () => {
  assert.match(code, /SENTRY_AUTH_TOKEN_FULLSCOPE/);
  assert.match(shipScript, /SENTRY_AUTH_TOKEN_FULLSCOPE/);
  // The full-scope token is the one sentry-cli accepts, and it is the one the
  // workflow hands over.  The DSN must never reach the token slot.
  assert.match(shipScript, /\*:\/\/\*\|\*@\*/);
  assert.match(shipScript, /looks like a DSN, not an API token/);
});

test("the iOS lane uploads to the DSN project as well as the app's own", () => {
  assert.match(shipScript, /sentry_dsn_project/);
  assert.match(shipScript, /sentry_project_list/);
  assert.match(shipScript, /SENTRY_PROJECT="\$p"/);
  // The DSN project is not the same thing as the app's project, so both are
  // uploaded to, and the same project is never uploaded to twice.
  assert.match(shipScript, /\$dsn_project" != "\$app_project"/);
});

test("a failed Sentry upload is an error annotation and a red run", () => {
  assert.match(shipScript, /::error title=Sentry upload::/);
  assert.match(shipScript, /sentry_report_failure/);
  assert.match(shipScript, /\.ios-ship-sentry-failed/);
  // The workflow turns the marker into a failed step, and it is the LAST
  // step, after the ship-state cache is saved, so a red run can neither block
  // the release that already happened nor make the next ship repeat itself.
  assert.match(code, /Sentry artifact upload status/);
  assert.match(code, /\.ios-ship-sentry-failed/);
  assert.match(code, /exit 1/);
  const shipSteps = code.split(/- name:/);
  const statusIndex = shipSteps.findIndex((s) => /Sentry artifact upload status/.test(s));
  const cacheIndex = shipSteps.findIndex((s) => /Save ship-state cache/.test(s));
  assert.ok(statusIndex > 0 && cacheIndex > 0, "the ship job has both steps");
  assert.ok(statusIndex > cacheIndex, "the Sentry status step runs after the ship-state cache is saved");
});

test("the Sentry status step never claims a TestFlight upload that never ran", () => {
  // The marker is written before the export and the upload, so a marker can
  // exist for a run that never uploaded anything.  The claim has to come from
  // the ship step's own outcome, not from the mere presence of the marker.
  assert.match(code, /- name: Ship CodeCaps to TestFlight\n\s+id: ship\b/);
  assert.match(code, /steps\.ship\.outcome\s*\}\}" = "success"/);
  assert.ok(
    (code.match(/steps\.ship\.outcome/g) || []).length >= 2,
    "the status step must read the ship step's outcome in both branches",
  );
});

test("the Sentry upload keeps the token out of argv and reports every miss", () => {
  // The token reaches curl on stdin, so a process listing cannot read it.
  assert.match(shipScript, /-H @-/);
  assert.match(shipScript, /<<<"Authorization: Bearer \$\{SENTRY_API_TOKEN\}"/);
  assert.doesNotMatch(shipScript, /curl[^\n]*Bearer/);
  assert.doesNotMatch(shipScript, /-H "Authorization: Bearer/);

  // A credential that cannot be resolved is reported by name and fails the
  // resolution, instead of becoming an empty token that looks like a success.
  assert.ok(shipScript.includes("could not be read from fleet-secrets"));
  assert.match(shipScript, /load_sentry_auth\(\) \{[\s\S]*?return 1/);

  // Source bundles are a per-project artifact, so every project gets them.
  assert.match(shipScript, /debug-files upload --include-sources "\$archive"/);
  assert.doesNotMatch(shipScript, /debug-files upload "\$archive"/);

  // The Size Analysis quota is 100 builds a month, so only the project that
  // holds the events spends one.
  assert.ok(shipScript.includes('if [[ -z "$dsn_project" || "$p" == "$dsn_project" ]]; then'));

  // A DSN project that cannot be resolved is reported:  dropping it silently
  // is the defect the lane exists to fix.
  assert.ok(shipScript.includes("the Sentry project named by the DSN could not be resolved"));

  // The marker write is guarded:  a bookkeeping failure must not abort the
  // ship under set -e.
  assert.ok(shipScript.includes('>>"$(sentry_failure_marker)" 2>/dev/null'));
});

test("upload-only never forwards the (from IPA) placeholder to the manifest publisher", () => {
  const ship = read("scripts/ios-fleet/ship-testflight.sh");
  const guard = ship.indexOf('"${MARKETING:-}" == "(from IPA)" || "${BUILD_NUM:-}" == "(from IPA)"');
  const publish = ship.indexOf('bash "${FLEET_DIR}/publish-ios-versions.sh"');
  assert.ok(guard > 0 && publish > guard, "placeholder guard must come before the publisher call");
});

test("Sentry error-file read failure cannot abort a ship under errexit", () => {
  const restore = shipScript.match(/if \[\[ -s "\$\{LOG_DIR\}\/sentry-dsn-project\.error" \]\]; then[\s\S]*?\n    fi/)[0];
  const script = `set -e
LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT
printf 'reason' >"$LOG_DIR/sentry-dsn-project.error"
cat() { return 1; }
${restore}
echo continued`;
  assert.match(execFileSync("bash", ["-c", script], {encoding:"utf8"}), /continued/);
});
