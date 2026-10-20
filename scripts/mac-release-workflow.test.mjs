// Credential-free contract and mocked notarization preflight tests.
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync, readdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
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
  'Load ASC credentials (Fleet-OPS prod /asc)',
  'Stage the ASC private key (Fleet-OPS prod /asc)',
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
test('Sparkle uses the existing fleet ASC loader, never repository ASC secrets', () => {
  assert.doesNotMatch(code, /secrets\.ASC_/);
  // One loader, two workflows.  The release path and the iOS ship path must
  // carry the same text, so a fix to one is a fix to the other.
  for (const name of LOADERS) {
    assert.equal(stripGuard(step(workflow, name)), step(iosShip, name), `mac-release and ios-ship disagree on "${name}"`);
    assert.match(step(workflow, name), /if: github.event_name != 'pull_request'/);
  }
  // The credential check job runs the same loader as the release job, so a
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
  // The bare Infisical CLI is gone: it prints the value to stdout, and its
  // only install path is macOS-only.
  for (const file of [workflow, iosShip]) {
    assert.doesNotMatch(file, /infisical secrets get/);
    assert.doesNotMatch(file, /infisical\/get-cli/);
  }
  assert.match(loader, /run: node scripts\/stage-asc-key\.mjs/);
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
  // No new code may talk to the vault directly: the values come from the
  // approved composite action, and the only thing a script does is stage
  // one of them to a file.
  for (const file of [workflow, iosShip]) {
    assert.doesNotMatch(file, /listSecretsRaw|loginUniversalAuth/);
  }
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
