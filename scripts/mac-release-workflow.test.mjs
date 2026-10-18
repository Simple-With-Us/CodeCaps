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
test('Sparkle uses the existing fleet ASC loader, never repository ASC secrets', () => {
  assert.doesNotMatch(code, /secrets\.ASC_/);
  const name = 'Load ASC credentials (Fleet-OPS prod /asc)';
  const normalize = s => s.replaceAll('verify the CI identity has read access to project ${ASC_INFISICAL_PROJECT_ID} path /asc.', 'verify the CI identity has read access to Fleet-OPS prod /asc.');
  assert.equal(step(workflow, name).replace("        if: github.event_name != 'pull_request'\n", ''), normalize(step(read('.github/workflows/ios-ship.yml'), name)));
  const loader = step(workflow, name);
  assert.doesNotMatch(loader, /echo .*\$\{ASC_INFISICAL_PROJECT_ID\}/);
  assert.match(loader, /Missing \$name in Fleet-OPS prod \/asc; verify the CI identity has read access to Fleet-OPS prod \/asc\./);
  assert.match(loader, /Missing ASC key material in Fleet-OPS prod \/asc; verify the CI identity has read access to Fleet-OPS prod \/asc\./);
  assert.match(step(workflow, name), /if: github.event_name != 'pull_request'/);
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
  assert.match(code, /run: node --test scripts\/mac-release-workflow.test.mjs/);
  assert.match(code, /needs.await-swift-ci.result == 'success'/);
  assert.match(code, /run: script\/build_and_run.sh --release/);
  assert.ok(code.indexOf('Verify notarization access') < code.indexOf('Build, sign, notarize'));
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
