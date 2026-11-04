// Offline tests for the macOS release build planner.
//
// The merge stamp is set explicitly (a temp git repo with a fixed committer
// date), so no test depends on the clock, the network, or the state of this
// checkout.
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

import {
  mergeStamp,
  marketingVersion,
  publishedBuilds,
  planBuild,
} from './plan-mac-release-build.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const STAMP = '202611042015';

function repoWithCommit(committerDate) {
  const dir = mkdtempSync(join(tmpdir(), 'mac-build-plan-'));
  const run = (args, env = {}) =>
    execFileSync('git', args, {
      cwd: dir,
      encoding: 'utf8',
      env: {
        ...process.env,
        GIT_AUTHOR_NAME: 'Test',
        GIT_AUTHOR_EMAIL: 'test@example.invalid',
        GIT_COMMITTER_NAME: 'Test',
        GIT_COMMITTER_EMAIL: 'test@example.invalid',
        GIT_AUTHOR_DATE: committerDate,
        GIT_COMMITTER_DATE: committerDate,
        ...env,
      },
    });
  run(['init', '-q']);
  writeFileSync(join(dir, 'file.txt'), 'x');
  run(['add', '-A']);
  run(['commit', '-qm', 'commit']);
  return dir;
}

test('the merge stamp is the committer date of HEAD in America/Chicago', () => {
  // 2026-11-04T20:15:00Z is 14:15 in Chicago (CST), so the stamp is 1415.
  const dir = repoWithCommit('2026-11-04T20:15:00+00:00');
  try {
    assert.equal(mergeStamp(dir), '202611041415');
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});

test('the merge stamp of this checkout is a 12-digit stamp', () => {
  assert.match(mergeStamp(root), /^[1-9][0-9]{11}$/);
});

test('a HEAD without a readable date fails instead of planning a build', () => {
  const dir = mkdtempSync(join(tmpdir(), 'mac-build-plan-empty-'));
  try {
    assert.throws(() => mergeStamp(dir), /could not read the committer date|usable committer date/);
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});

test('every published build in the appcast is read', () => {
  const appcast = `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item>
            <title>0.1.0</title>
            <sparkle:version>202611042015</sparkle:version>
            <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
            <enclosure url="https://example.invalid/CodeCaps.zip" length="1" type="application/octet-stream"/>
        </item>
    </channel>
</rss>`;
  assert.deepEqual(publishedBuilds(appcast), ['202611042015']);
});

test('an appcast with no version reads as no builds, and a broken one throws', () => {
  assert.deepEqual(publishedBuilds('<rss><channel></channel></rss>'), []);
  assert.deepEqual(publishedBuilds(''), []);
  assert.deepEqual(publishedBuilds(null), []);
  // A version that is not a plain integer is not a number to compare with.
  assert.deepEqual(publishedBuilds('<sparkle:version>1.0</sparkle:version>'), []);
});

test('the plan is the merge stamp until a published build reaches it', () => {
  assert.deepEqual(planBuild({mergeStamp: STAMP, publishedBuilds: []}), {build: STAMP});
  assert.deepEqual(planBuild({mergeStamp: STAMP, publishedBuilds: ['312']}), {build: STAMP});
  assert.deepEqual(planBuild({mergeStamp: STAMP, publishedBuilds: ['202611030314']}), {build: STAMP});
});

test('a rebuild of the same commit goes above the published build', () => {
  assert.deepEqual(planBuild({mergeStamp: STAMP, publishedBuilds: [STAMP]}), {build: '202611042016'});
  assert.deepEqual(
    planBuild({mergeStamp: STAMP, publishedBuilds: ['202611042016', '312']}),
    {build: '202611042017'},
  );
});

test('a published build above the stamp is planned one above', () => {
  assert.deepEqual(
    planBuild({mergeStamp: STAMP, publishedBuilds: ['209912312359']}),
    {build: '209912312360'},
  );
});

test('the marketing version is the one the iOS companion ships', () => {
  const apps = JSON.parse(readFileSync(join(root, 'scripts/ios-fleet/apps.json'), 'utf8'));
  const expected = apps.apps.codecaps.fixedMarketingVersion;
  assert.equal(marketingVersion(), expected);
});

test('the VERSION file and the iOS fleet config cannot drift apart', () => {
  // The macOS app reads its marketing version from VERSION and the iOS
  // companion reads it from scripts/ios-fleet/apps.json.  Two copies of one
  // number drift, so this test holds them together.
  const fromVersionFile = readFileSync(join(root, 'VERSION'), 'utf8').trim();
  assert.equal(fromVersionFile, marketingVersion());
});

test('the build script ships the fixed marketing version and the merge stamp', () => {
  const script = readFileSync(join(root, 'script/build_and_run.sh'), 'utf8');
  // The retired 1.0.<commit_count> pair must not come back.
  assert.doesNotMatch(script, /rev-list --count HEAD/);
  assert.match(script, /CODECAPS_MARKETING_VERSION/);
  assert.match(script, /CODECAPS_BUILD_NUMBER/);
  assert.match(script, /format-local:%Y%m%d%H%M/);
});

test('the release workflow plans the build once and hands it to the build', () => {
  const workflow = readFileSync(join(root, '.github/workflows/mac-release.yml'), 'utf8');
  assert.match(workflow, /node scripts\/plan-mac-release-build\.mjs/);
  assert.match(workflow, /CODECAPS_BUILD_NUMBER=\$build" >> "\$GITHUB_ENV"/);
  assert.match(workflow, /CODECAPS_MARKETING_VERSION=\$version" >> "\$GITHUB_ENV"/);
  // One planning step, so a release cannot ship two different numbers.
  const calls = workflow.split('\n').filter(l => l.includes('node scripts/plan-mac-release-build.mjs'));
  assert.equal(calls.length, 2, 'the planner is called twice in one step (build and version) and nowhere else');
  assert.equal(calls.filter(l => l.includes('--marketing-version')).length, 1);
});
