// Credential-free contract and mocked notarization preflight tests.
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync, readdirSync, symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import {chicagoMergeStamp, latestFixedMarketingVersion, offlineBuildMetadata, parseAppcastFloor, planSharedBuild, releaseBuildPlannerArgs} from './mac-release-version.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => readFileSync(join(root, p), 'utf8');
const workflow = read('.github/workflows/mac-release.yml');
const code = workflow.split('\n').filter(l => !/^\s*#/.test(l)).join('\n');
function step(s, name) {
  const start = s.indexOf(`      - name: ${name}\n`);
  assert.ok(start >= 0, name);
  const end = s.indexOf('\n      - ', start + 1);
  return s.slice(start, end < 0 ? undefined : end).trim();
}
const LOADERS = [
  'Load and stage the ASC credentials (Fleet-OPS prod /asc)',
  'Check the ASC credentials arrived',
];
const stripGuard = s => s.replaceAll("        if: github.event_name != 'pull_request'\n", '');
function allSteps(s, name) {
  const out = [];
  const marker = `      - name: ${name}\n`;
  let at = s.indexOf(marker);
  while (at >= 0) {
    const end = s.indexOf('\n      - ', at + 1);
    out.push(s.slice(at, end < 0 ? undefined : end).trim());
    at = s.indexOf(marker, at + 1);
  }
  return out;
}
const iosShip = read('.github/workflows/ios-ship.yml');
const iosCode = iosShip.split('\n').filter(l => !/^\s*#/.test(l)).join('\n');
test('Sparkle reads the ASC credentials through the fleet reader, never repository ASC secrets', () => {
  // The three signing credentials are named on purpose.  A blanket
  // `secrets.ASC_` would also catch ASC_STANDING_TESTERS, which is a list of
  // TestFlight tester addresses and is read from the repository on purpose.
  for (const name of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8']) {
    assert.doesNotMatch(code, new RegExp(`secrets\\.${name}`));
  }
  // One handoff, two workflows.  The release path and the iOS ship path must
  // carry the same text, so a fix to one is a fix to the other.
  for (const name of LOADERS) {
    assert.equal(stripGuard(step(workflow, name)), step(iosShip, name), `mac-release and ios-ship disagree on "${name}"`);
    assert.match(step(workflow, name), /if: github.event_name != 'pull_request'/);
  }
  // The credential check job runs the same handoff as the release job, so a
  // change to one cannot leave the other proving nothing.
  for (const name of LOADERS) {
    const copies = allSteps(workflow, name);
    assert.equal(copies.length, 2, `"${name}" must exist in the release job and in the credential check`);
    assert.equal(stripGuard(copies[0]), copies[1], `the credential check's "${name}" drifted from the release job's`);
  }
  const loader = LOADERS.map(name => step(workflow, name)).join('\n');
  // The project id is a secret.  A literal in a public workflow is both a
  // leak of an internal identifier and a second copy to keep in step.
  for (const file of [workflow, iosShip]) {
    assert.doesNotMatch(file, /8dae6d03/);
    assert.doesNotMatch(file, /ASC_INFISICAL_PROJECT_ID/);
  }
  assert.match(loader, /project-id: \$\{\{ secrets\.INFISICAL_FLEET_OPS_PROJECT_ID \}\}/);
  assert.doesNotMatch(loader, /echo .*\$\{ASC_INFISICAL_PROJECT_ID\}/);
  // asc-mode stages the PEM and exports ASC_KEY_PATH.  The raw key is not a
  // GITHUB_ENV value.  The workflow calls the composite action, not the
  // fetch script and not a universal-auth login.
  assert.match(loader, /uses: \.\/\.github\/actions\/infisical-secrets/);
  assert.match(loader, /names: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8/);
  assert.match(loader, /required: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8/);
  assert.match(loader, /secret-path: \/asc/);
  assert.match(loader, /service-token: \$\{\{ secrets\.INFISICAL_ASC_READ_TOKEN \}\}/);
  assert.match(loader, /asc-mode: "true"/);
  assert.doesNotMatch(loader, /GH_FALLBACK_ASC_/);
  assert.doesNotMatch(loader, /client-id:/);
  assert.doesNotMatch(loader, /INFISICAL_UNIVERSAL_AUTH_CLIENT/);
  assert.doesNotMatch(loader, /INFISICAL_CLIENT_(ID|SECRET)/);
  assert.doesNotMatch(loader, /install-release-secrets-tooling/);
  assert.doesNotMatch(loader, /node scripts\/infisical-fetch\.mjs/);
  const fetch = read('scripts/infisical-fetch.mjs');
  assert.match(fetch, /export function exportAscCredentials/);
  assert.match(fetch, /ios-stage-asc-key\.sh/);
  assert.match(fetch, /expandSecretReferences: "false"/);
  assert.match(fetch, /recursive: "false"/);
  assert.doesNotMatch(fetch, /writeGithubEnvValue\(env\.GITHUB_ENV, "ASC_KEY_P8"/);
  assert.doesNotMatch(fetch, /universal-auth/);
  // The repository's stale signing secrets are never read.  The three
  // signing credentials are named on purpose: a blanket `secrets.ASC_` would
  // also catch ASC_STANDING_TESTERS, which is a list of TestFlight tester
  // addresses and is read from the repository on purpose.
  for (const file of [code, iosCode]) {
    for (const name of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8']) {
      assert.doesNotMatch(file, new RegExp(`secrets\\.${name}\\b`));
    }
    assert.doesNotMatch(file, /ASC_KEY_P8: \$\{\{/);
    assert.doesNotMatch(file, /client-id:/);
    assert.doesNotMatch(file, /INFISICAL_UNIVERSAL_AUTH_CLIENT/);
    assert.doesNotMatch(file, /INFISICAL_CLIENT_(ID|SECRET)/);
    assert.doesNotMatch(file, /install-release-secrets-tooling/);
    assert.match(file, /names: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8/);
    assert.match(file, /asc-mode: "true"/);
    assert.match(file, /service-token: \$\{\{ secrets\.INFISICAL_ASC_READ_TOKEN \}\}/);
  }
  // The vault is named where it is read.
  assert.match(loader, /Load and stage the ASC credentials \(Fleet-OPS prod \/asc\)/);
  assert.match(read('scripts/stage-asc-key.mjs'), /SECRET_FOLDER = '\/asc'/);
  // The bare Infisical CLI is gone: it prints the value to stdout, and its
  // only install path is macOS-only.
  for (const file of [workflow, iosShip]) {
    assert.doesNotMatch(file, /infisical secrets get/);
    assert.doesNotMatch(file, /infisical\/get-cli/);
    assert.doesNotMatch(file, /universal-auth/);
  }
  assert.match(loader, /Missing \$name in Fleet-OPS prod \/asc; verify the CI identity has read access to Fleet-OPS prod \/asc\./);
  assert.match(loader, /Missing ASC key material in Fleet-OPS prod \/asc; verify the CI identity has read access to Fleet-OPS prod \/asc\./);
  assert.match(code, /NOTARY_KEY_PATH: \$\{\{ env.ASC_KEY_PATH \}\}/);
  assert.match(code, /NOTARY_KEY_ID: \$\{\{ env.ASC_KEY_ID \}\}/);
  assert.match(code, /NOTARY_ISSUER_ID: \$\{\{ env.ASC_ISSUER_ID \}\}/);
  assert.doesNotMatch(code, /printf.*ASC_KEY_P8|ASC_KEY_P8:/);
  assert.match(code, /rm -f -- "\$ASC_KEY_PATH"/);
});
test('PRs cannot notarize or publish, and icon-only changes trigger releases', () => {
  assert.match(step(workflow, 'Load the Developer ID certificate (Infisical, then repository secrets)'), /if: github.event_name != 'pull_request'/);
  assert.match(code, /SPARKLE_ED_PRIVATE_KEY: \$\{\{ github.event_name != 'pull_request' && secrets.SPARKLE_ED_PRIVATE_KEY \|\| '' \}\}/);
  assert.match(step(workflow, 'Remove the signing keychain and key'), /if: always\(\)/);
  assert.match(step(workflow, 'Remove the signing keychain and key'), /rm -f -- "\$ASC_KEY_PATH"/);
  assert.match(step(workflow, 'Decide whether this run can publish'), /GITHUB_EVENT_NAME.*pull_request[\s\S]*publish=false[\s\S]*exit 0/);
  for (const name of ['Verify notarization access before building', 'Build, sign, notarize and staple', 'Write the signed appcast', 'Publish the GitHub release', 'Confirm the live feed serves this build']) {
    assert.match(step(workflow, name), /if: steps.gate.outputs.publish == 'true'/);
  }
  assert.match(code, /'assets\/AppIcon.icns'/);
  assert.match(code, /run: node --test scripts\/mac-release-workflow.test.mjs scripts\/stage-asc-key.node-test.mjs/);
  // A manual run can be asked to prove the credentials without publishing.
  assert.match(code, /verify-only:/);
  assert.match(step(workflow, 'Decide whether this run can publish'), /inputs\.verify-only[\s\S]*publish=false/);
  // A verify-only run still asks Apple's notary whether it accepts the key,
  // and it does not spend minutes building a bundle it will never publish.
  assert.match(step(workflow, 'Decide whether this run can publish'), /verify-only[\s\S]*verify_only=true/);
  assert.match(step(workflow, 'Verify notarization access before building'), /publish == 'true' \|\| steps\.gate\.outputs\.verify_only == 'true'/);
  assert.match(code, /steps\.gate\.outputs\.publish != 'true' && steps\.gate\.outputs\.verify_only != 'true'/);
  // A verify-only run must not install a toolchain it will not use.
  assert.match(step(workflow, 'Install XcodeGen'), /publish == 'true' \|\| steps\.gate\.outputs\.verify_only != 'true'/);
  // The credential check job holds the signing key, so it must not be able
  // to push commits, tags or releases.
  assert.match(code, /verify-release-credentials:[\s\S]*permissions:\s*\n\s*contents: read/);
  // Workflows reach the vault through the composite action, not by calling
  // the fetch helpers directly.
  for (const file of [workflow, iosShip]) {
    assert.doesNotMatch(file, /listSecretsRaw|loginUniversalAuth/);
    assert.doesNotMatch(file, /client-id:/);
    assert.doesNotMatch(file, /INFISICAL_UNIVERSAL_AUTH_CLIENT/);
    assert.doesNotMatch(file, /INFISICAL_CLIENT_(ID|SECRET)/);
  }
  assert.match(read('scripts/stage-asc-key.mjs'), /from '\.\/infisical-fetch\.mjs'/);
  // The staging script resolves every credential environment-first and then
  // through an injected getter, so the job's own environment is looked up
  // before anything else, the fallback is stubbed at its seam rather than at
  // a network endpoint, and the ASC_KEY_P8 entry is blanked so that no later
  // step can read the key from the environment.  The script holds no vault
  // client of its own.
  const stage = read('scripts/stage-asc-key.mjs');
  assert.match(stage, /env\[name\]/);
  assert.match(stage, /getSecret = fleetSecretsGet/);
  // The key leaves the environment file with the entry itself removed, not
  // with a blank assignment that leaves the earlier bytes in the file for the
  // runner to import into a later step.
  assert.match(stage, /removeEnvironmentEntries/);
  assert.match(stage, /KEY_ENTRIES = new Set\(\['ASC_KEY_P8'\]\)/);
  assert.doesNotMatch(stage, /appendFileSync\(env\.GITHUB_ENV, 'ASC_KEY_P8=/);
  assert.match(stage, /isUnresolvedReference/);
  assert.match(stage, /maskValue\(keyId, log\)/);
  assert.match(stage, /maskValue\(issuerId, log\)/);
  assert.doesNotMatch(stage, /listSecretsRaw|loginUniversalAuth/);
  assert.doesNotMatch(stage, /maskValue\(key, log\)/);
  assert.match(code, /needs.await-swift-ci.result == 'success'/);
  assert.match(code, /run: script\/build_and_run.sh --release/);
  assert.ok(code.indexOf('Verify notarization access') < code.indexOf('Build, sign, notarize'));
});

test('a verify-only dispatch is isolated from the release job, and only main publishes', () => {
  // A verify-only dispatch has its own job.  The release job must not run for
  // one: it would load the Developer ID, Sentry and Sparkle material and
  // build the whole bundle for a check that publishes nothing.
  assert.match(code, /needs\.await-swift-ci\.result == 'success' &&\s*inputs\.verify-only != true/);
  // And the credential check must not run for a dispatch that is going to
  // publish, or for an ordinary push.
  assert.match(code, /if: github\.event_name == 'workflow_dispatch' && inputs\.verify-only == true/);
  // Only a run on main may publish.  A dispatch from a branch must build and
  // verify, and stop there.
  assert.match(step(workflow, 'Decide whether this run can publish'), /GITHUB_REF" != "refs\/heads\/main[\s\S]*publish=false[\s\S]*exit 0/);
  assert.match(step(workflow, 'Decide whether this run can publish'), /Only a run on main publishes a release\./);
});
function preflight(exitCode, error, missing = false) {
  const dir = mkdtempSync(join(tmpdir(), 'notary-test-'));
  try {
    const bin = join(dir, 'bin'); mkdirSync(bin);
    const marker = join(dir, 'called');
    writeFileSync(join(bin, 'xcrun'), '#!/bin/bash\nprintf called > "$MOCK_MARKER"\n[[ "$1 $2" == "notarytool history" ]] || exit 99\nprintf "%s" "$MOCK_ERROR" >&2\nexit "$MOCK_EXIT"\n', {mode: 0o700});
    const key = join(dir, 'key'); writeFileSync(key, 'FAKE TEST KEY');
    const r = spawnSync('bash', [join(root, 'scripts/check-notary-access.sh')], {encoding:'utf8', env:{...process.env, PATH:bin+':'+process.env.PATH, RUNNER_TEMP:dir, ASC_KEY_ID: missing ? '' : 'FAKE-ID', ASC_ISSUER_ID:'FAKE-ISSUER', ASC_KEY_PATH:key, MOCK_EXIT:String(exitCode), MOCK_ERROR:error, MOCK_MARKER:marker}});
    assert.ok(!readdirSync(dir).some(p => p.startsWith('notary-access.')), 'temporary diagnostics cleaned');
    assert.ok(!(r.stdout+r.stderr).includes('PRIVATE_SENTINEL'), 'raw error never logged');
    if (missing) assert.ok(!readdirSync(dir).includes('called'));
    return r;
  } finally { rmSync(dir, {recursive:true, force:true}); }
}
test('read-only preflight accepts service auth without claiming artifact acceptance', () => {
  const r=preflight(0,''); assert.equal(r.status,0); assert.match(r.stdout,/artifact acceptance remains a separate/);
});
for (const [error, category] of [['HTTP 401 PRIVATE_SENTINEL','authentication rejected'], ['HTTP 403 PRIVATE_SENTINEL','service access rejected'], ['connection timed out PRIVATE_SENTINEL','connectivity failure'], ['cannot parse private key PRIVATE_SENTINEL','key format'], ['PRIVATE_SENTINEL','unclassified']]) {
  test(`preflight fails closed with sanitized ${category}`, () => {
    const r=preflight(7,error); assert.equal(r.status,1); assert.ok(r.stderr.includes(category)); assert.match(r.stderr,/exit 7/);
  });
}
test('missing credential fails before invoking Apple', () => {
  const r=preflight(0,'',true); assert.equal(r.status,1); assert.match(r.stderr,/missing ASC_KEY_ID/);
});
test('each Infisical step uses its scoped project and service token', () => {
  // Certs and ASC stay on Fleet-OPS.  Sentry comes from the CodeCaps project.
  assert.match(workflow, /secret-path: \/mac-certs\n\s+service-token: \$\{\{ secrets\.INFISICAL_MAC_CERTS_READ_TOKEN \}\}/);
  assert.match(workflow, /project-id: \$\{\{ secrets\.INFISICAL_FLEET_OPS_PROJECT_ID \}\}/);
  assert.match(iosShip, /project-id: \$\{\{ secrets\.INFISICAL_FLEET_OPS_PROJECT_ID \}\}/);
  assert.match(workflow, /service-token: \$\{\{ secrets\.INFISICAL_CODECAPS_READ_TOKEN \}\}/);
  assert.match(iosShip, /service-token: \$\{\{ secrets\.INFISICAL_CODECAPS_READ_TOKEN \}\}/);
  assert.match(workflow, /project-id: \$\{\{ secrets\.INFISICAL_PROJECT_ID \}\}/);
  assert.match(iosShip, /project-id: \$\{\{ secrets\.INFISICAL_PROJECT_ID \}\}/);
  const cert = step(workflow, 'Load the Developer ID certificate (Infisical, then repository secrets)');
  assert.match(cert, /secrets\.INFISICAL_FLEET_OPS_PROJECT_ID/);
  assert.match(cert, /secrets\.INFISICAL_MAC_CERTS_READ_TOKEN/);
  assert.match(cert, /GH_FALLBACK_MAC_CERT_P12_BASE64/);
  assert.doesNotMatch(cert, /SENTRY_/);
  // The loader compares physical paths, so a symlinked checkout still runs it
  // as the entry module instead of silently doing nothing.
  const loader = read('scripts/infisical-fetch.mjs');
  assert.match(loader, /function isEntryModule\(\)/);
  assert.match(loader, /realpathSync/);
  assert.doesNotMatch(loader, /pathToFileURL\(process\.argv\[1\]\)\.href === import\.meta\.url/);
});

test('the Sentry upload keeps the full-scope token away from the installer and refuses a DSN', () => {
  // The sentry-cli installer is fetched over the network and piped to sh, so
  // it must run in an empty environment:  a hijacked installer response must
  // not inherit SENTRY_AUTH_TOKEN.  The token stays a shell variable
  // and is handed only to sentry-cli, one invocation at a time.  A DSN in the
  // token slot is refused, because sentry-cli rejects it as authentication.
  // SENTRY_AUTH_TOKEN_FULLSCOPE is not loaded: that name lived in Fleet-OPS
  // prod /, which no scoped token reads.
  const sentry = step(code, 'Upload Sentry debug files');
  assert.match(sentry, /\| env -i [^\n]*\\\n[^\n]*INSTALL_DIR="\$cli_dir"[^\n]* sh /);
  assert.doesNotMatch(sentry, /export SENTRY_AUTH_TOKEN/);
  assert.doesNotMatch(sentry, /^\s+SENTRY_AUTH_TOKEN(_FULLSCOPE)?:/m);
  assert.doesNotMatch(sentry, /SENTRY_AUTH_TOKEN_FULLSCOPE/);
  assert.match(sentry, /TOKEN="\$\{SENTRY_AUTH_TOKEN:-\}"/);
  const handoffs = sentry.match(/SENTRY_AUTH_TOKEN="\$TOKEN"/g) ?? [];
  assert.equal(handoffs.length, 1);
  assert.match(sentry, /SENTRY_AUTH_TOKEN="\$TOKEN" SENTRY_PROJECT="\$project" \\\n\s+sentry-cli debug-files upload /);
  assert.match(sentry, /\*:\/\/\*\|\*@\*\)\n[^\n]*looks like a DSN[^\n]*\n\s+exit 1/);
});


test('Mac release versions use Chicago merge timestamps and the shared rebuild floor', () => {
  const mergeDate = new Date('2026-10-29T14:30:00Z');
  const stamp = chicagoMergeStamp(mergeDate);
  assert.equal(stamp, '202610290930');
  assert.match(stamp, /^[1-9][0-9]{11}$/);
  assert.equal(chicagoMergeStamp(new Date(mergeDate)), stamp, 'the same commit date plans deterministically');
  assert.equal(planSharedBuild({mergeStamp: stamp}), stamp);
  assert.equal(planSharedBuild({mergeStamp: stamp}), stamp, 'a repeat plan with unchanged inventory reuses the same shared build');
  assert.equal(planSharedBuild({mergeStamp: stamp, iosBuilds: [stamp]}), '202610290931');
  assert.equal(planSharedBuild({mergeStamp: stamp, macBuilds: [stamp]}), '202610290931');
  assert.equal(chicagoMergeStamp(new Date('2026-11-03T12:00:00Z')), '202611030600',
    'the conversion observes Chicago standard time after daylight saving ends');
});

test('Mac marketing version keeps the registry default unless ASC proves a higher approved version', () => {
  assert.equal(latestFixedMarketingVersion('0.1.0'), '0.1.0');
  assert.equal(latestFixedMarketingVersion('0.1.0', ''), '0.1.0');
  assert.equal(latestFixedMarketingVersion('0.1.0', '0.0.9'), '0.1.0');
  assert.equal(latestFixedMarketingVersion('0.1.0', '0.1.0'), '0.1.0');
  assert.equal(latestFixedMarketingVersion('0.1.0', '1.0'), '1.0',
    'ASC can return an approved two-component marketing version, which must be preserved');
  const approved = latestFixedMarketingVersion('0.1.0', '1.0.302');
  assert.equal(approved, '1.0.302');
  assert.equal(latestFixedMarketingVersion('0.1.0', '1.0.302'), approved,
    're-reading the same approved version does not bump or rewrite the train');
  assert.deepEqual(offlineBuildMetadata({mergeDate: new Date('2026-10-29T14:30:00Z')}), {
    marketingVersion: '0.1.0', buildVersion: '202610290930',
  });
  assert.throws(() => latestFixedMarketingVersion('0.1', '1.0.0'), /invalid marketing version/);
  assert.throws(() => latestFixedMarketingVersion('0.1', '1.0'), /invalid marketing version/);
  assert.throws(() => latestFixedMarketingVersion('0.1.0', 'not-a-version'), /invalid marketing version/);
  assert.throws(() => latestFixedMarketingVersion('0.1.0', '1.0.302.1'), /invalid marketing version/);
  assert.equal(parseAppcastFloor('<sparkle:version>210</sparkle:version><sparkle:version>202610290930</sparkle:version>'),
    '202610290930');
  assert.throws(() => parseAppcastFloor('<sparkle:version>1234567890123</sparkle:version>'), /no valid build floor/);
});

test('Mac shared build planning includes the registered paired app before its feed floor', () => {
  assert.deepEqual(releaseBuildPlannerArgs({bundleId: 'com.example.ios', pairedBundleId: 'com.example.mac'}, '73', '202611030600'),
    ['com.example.ios', 'com.example.mac', '73', '--merge-stamp', '202611030600']);
  assert.deepEqual(releaseBuildPlannerArgs({bundleId: 'com.example.ios', macBundleId: 'com.example.mac'}, '73', '202611030600'),
    ['com.example.ios', 'com.example.mac', '73', '--merge-stamp', '202611030600']);
  assert.deepEqual(releaseBuildPlannerArgs({bundleId: 'com.example.ios'}, '73', '202611030600'),
    ['com.example.ios', '73', '--merge-stamp', '202611030600']);
});

test('the build root resolves task-lane symlinks before invoking the version planner', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'codecaps-build-root-'));
  const alias = join(temporary, 'lane');
  try {
    symlinkSync(root, alias, 'dir');
    const script = 'ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd -P)"\nnode "$ROOT_DIR/scripts/mac-release-version.mjs" offline "$ROOT_DIR"\n';
    const result = spawnSync('bash', ['-c', script], {
      encoding: 'utf8', env: {...process.env, SCRIPT_PATH: join(alias, 'script', 'build_and_run.sh')},
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^0\.1\.0\t[1-9][0-9]{11}\n$/);
  } finally {
    rmSync(temporary, {recursive: true, force: true});
  }
});

test('the build script accepts approved short marketing versions and caches the one planner result', () => {
  const builder = read('script/build_and_run.sh');
  const start = builder.indexOf('VERSION_PLAN_READY=0\n');
  const end = builder.indexOf('\nshort_version() {', start);
  assert.ok(start >= 0 && end > start, 'extract only the version helper, never source the build script');
  const versionHelper = builder.slice(start, end);
  for (const marketingVersion of ['1.0', '1.0.302']) {
    const temp = mkdtempSync(join(tmpdir(), 'codecaps-version-shell-'));
    try {
      const bin = join(temp, 'bin');
      mkdirSync(bin);
      const nodeStub = join(bin, 'node');
      writeFileSync(nodeStub, '#!/bin/sh\nprintf called >> "$PLAN_CALLS"\nprintf "%s\\n" "$PLAN_OUTPUT"\n');
      chmodSync(nodeStub, 0o700);
      const calls = join(temp, 'calls');
      const script = `${versionHelper}\nMODE=--dev\nROOT_DIR=/fixture\nprepare_build_versions\nprepare_build_versions\nprintf '%s\\t%s\\n' "$BUILD_MARKETING_VERSION" "$BUILD_BUNDLE_VERSION"\n`;
      const result = spawnSync('bash', ['-c', script], {
        encoding: 'utf8', env: {...process.env, PATH: `${bin}:${process.env.PATH}`, PLAN_CALLS: calls,
          PLAN_OUTPUT: `${marketingVersion}\t202611030600`},
      });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim(), `${marketingVersion}\t202611030600`);
      assert.equal(readFileSync(calls, 'utf8'), 'called', 'the planner runs once and the cached plan serves subsequent calls');
    } finally {
      rmSync(temp, {recursive: true, force: true});
    }
  }
});

test('the Mac release builder fails closed on missing shared planning and no longer uses commit counts', () => {
  const builder = read('script/build_and_run.sh');
  const planner = read('scripts/mac-release-version.mjs');
  assert.match(builder, /mac-release-version\.mjs/);
  assert.match(builder, /no bundle was built/);
  assert.match(builder, /prepare_build_versions \|\| exit 1\n  local arch_flags=\(\)/,
    'build_and_stage must validate and cache the shared plan before starting Swift build actions');
  assert.doesNotMatch(builder, /git -C "\$ROOT_DIR" rev-list --count HEAD/);
  assert.match(planner, /plan-release-build/);
  assert.match(planner, /released-store-version/);
  assert.match(planner, /pairedBuildFeed/);
});
