// Offline tests for the macOS release build planner.
//
// The merge stamp is set explicitly (a temp git repo with a fixed committer
// date), so no test depends on the clock, the network, or the state of this
// checkout.
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync, copyFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

import {
  fetchAppcast,
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
  // The version numbers are resolved and checked once, before the build,
  // because a check that runs inside a command substitution only fails the
  // subshell and the build carries on with an empty version string.
  assert.match(script, /resolve_versions/);
  assert.doesNotMatch(script, /<string>\$\(short_version\)<\/string>/);
  assert.doesNotMatch(script, /<string>\$\(bundle_version\)<\/string>/);
});

test('a build number below the merge stamp of HEAD is refused', () => {
  const script = readFileSync(join(root, 'script/build_and_run.sh'), 'utf8');
  // The release planner floors on max(S, M+1);  the build refuses a number
  // below S, because a build number that goes backwards strands every
  // installed copy on the old build.
  assert.match(script, /is below the merge stamp/);
  assert.match(script, /\[1-9]\[0-9]\{11\}/);
});

test('the planner runs when it is invoked through a path with a space in it', () => {
  // import.meta.url is an absolute, percent-encoded file URL and
  // process.argv[1] is a plain path, so a path with a space in it makes the
  // two differ:  the planner would never run and would exit quietly with no
  // output at all.
  const dir = mkdtempSync(join(tmpdir(), 'mac build plan '));
  try {
    // The planner looks for its config two levels up from itself, so the copy
    // keeps the scripts/ layout.
    mkdirSync(join(dir, 'scripts', 'ios-fleet'), {recursive: true});
    const script = join(dir, 'scripts', 'plan-mac-release-build.mjs');
    copyFileSync(join(root, 'scripts/plan-mac-release-build.mjs'), script);
    copyFileSync(join(root, 'scripts/ios-fleet/shared-build.mjs'), join(dir, 'scripts/ios-fleet/shared-build.mjs'));
    copyFileSync(join(root, 'scripts/ios-fleet/apps.json'), join(dir, 'scripts/ios-fleet/apps.json'));
    const out = execFileSync('node', [script, '--marketing-version'], {encoding: 'utf8'});
    assert.equal(out.trim(), marketingVersion());
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});

test('a redirect to an unexpected host is refused', async () => {
  const fetchImpl = async (url) => ({
    status: 302,
    ok: false,
    headers: new Map([['location', 'https://evil.invalid/appcast.xml']]),
    text: async () => '',
  });
  await assert.rejects(
    () => fetchAppcast('https://github.com/Simple-With-Us/CodeCaps/releases/latest/download/appcast.xml', fetchImpl),
    /redirected to an unexpected host/,
  );
});

test('the GitHub asset host is followed, and the appcast is read', async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    if (calls.length === 1) {
      return {
        status: 302,
        ok: false,
        headers: new Map([['location', 'https://release-assets.githubusercontent.com/asset/appcast.xml']]),
        text: async () => '',
      };
    }
    return {
      status: 200,
      ok: true,
      headers: new Map([['content-length', '24']]),
      text: async () => '<sparkle:version>1</sparkle:version>',
    };
  };
  const appcast = await fetchAppcast('https://github.com/Simple-With-Us/CodeCaps/releases/latest/download/appcast.xml', fetchImpl);
  assert.equal(calls.length, 2);
  assert.deepEqual(publishedBuilds(appcast), ['1']);
});

test('a feed over the size limit is refused instead of being read whole', async () => {
  const chunk = new Uint8Array(1_000_000);
  const fetchImpl = async () => ({
    status: 200,
    ok: true,
    headers: new Map(),
    body: {
      getReader() {
        let sent = 0;
        return {
          async read() {
            sent += 1;
            if (sent > 6) return {done: true, value: undefined};
            return {done: false, value: chunk};
          },
          async cancel() {},
        };
      },
    },
    text: async () => '',
  });
  await assert.rejects(
    () => fetchAppcast('https://github.com/Simple-With-Us/CodeCaps/releases/latest/download/appcast.xml', fetchImpl),
    /larger than 5000000 bytes/,
  );
});

test('a feed that declares too many bytes is refused before it is read', async () => {
  let read = false;
  const fetchImpl = async () => ({
    status: 200,
    ok: true,
    headers: new Map([['content-length', '9000000']]),
    body: null,
    text: async () => {
      read = true;
      return '';
    },
  });
  await assert.rejects(
    () => fetchAppcast('https://github.com/Simple-With-Us/CodeCaps/releases/latest/download/appcast.xml', fetchImpl),
    /declares 9000000 bytes/,
  );
  assert.equal(read, false);
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
