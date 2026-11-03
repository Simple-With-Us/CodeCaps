import {readFileSync, statSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {nextSharedBuild} from './ios-fleet/shared-build.mjs';

const DEFAULT_MARKETING_VERSION = '0.1.0';
const root = fileURLToPath(new URL('../', import.meta.url));

function parseVersion(value, {allowShort = false} = {}) {
  const pattern = allowShort ? /^\d+(?:\.\d+){0,2}$/ : /^\d+(?:\.\d+){2}$/;
  if (typeof value !== 'string' || !pattern.test(value)) {
    throw new Error('invalid marketing version');
  }
  return value.split('.').map(part => BigInt(part)).concat([0n, 0n]).slice(0, 3);
}

function compareVersions(left, right, {allowShort = false} = {}) {
  const a = parseVersion(left, {allowShort});
  const b = parseVersion(right, {allowShort});
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
  }
  return 0;
}

export function chicagoMergeStamp(date) {
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) throw new Error('invalid merge date');
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Chicago', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(date).map(part => [part.type, part.value]));
  const stamp = `${parts.year}${parts.month}${parts.day}${parts.hour}${parts.minute}`;
  if (!/^[1-9]\d{11}$/.test(stamp)) throw new Error('invalid Chicago merge stamp');
  return stamp;
}

export function latestFixedMarketingVersion(fixedVersion, releasedVersion = '') {
  parseVersion(fixedVersion);
  if (!releasedVersion) return fixedVersion;
  parseVersion(releasedVersion, {allowShort: true});
  return compareVersions(releasedVersion, fixedVersion, {allowShort: true}) > 0 ? releasedVersion : fixedVersion;
}

export function releaseBuildPlannerArgs(app, floor, mergeStamp) {
  const pairedBundleId = app.pairedBundleId || app.macBundleId || '';
  return [app.bundleId, ...(pairedBundleId ? [pairedBundleId] : []), String(floor), '--merge-stamp', mergeStamp];
}

export function planSharedBuild({mergeStamp, iosBuilds = [], macBuilds = [], extraFloors = []}) {
  return nextSharedBuild({iosBuilds, macBuilds, extraFloors, complete: true, mergeStamp}).build;
}

export function offlineBuildMetadata({mergeDate, fixedVersion = DEFAULT_MARKETING_VERSION}) {
  const mergeStamp = chicagoMergeStamp(mergeDate);
  return {marketingVersion: latestFixedMarketingVersion(fixedVersion), buildVersion: planSharedBuild({mergeStamp})};
}

function registry(rootDir) {
  const data = JSON.parse(readFileSync(join(rootDir, 'scripts/ios-fleet/apps.json'), 'utf8'));
  const app = data?.apps?.codecaps;
  if (typeof app?.fixedMarketingVersion !== 'string'
      || typeof app?.bundleId !== 'string' || typeof app?.pairedBuildFeed !== 'string') {
    throw new Error('CodeCaps release registry is incomplete');
  }
  parseVersion(app.fixedMarketingVersion);
  return app;
}

function mergeDate(rootDir) {
  const result = spawnSync('git', ['-C', rootDir, 'show', '-s', '--format=%cI', 'HEAD'], {encoding: 'utf8'});
  if (result.error || result.status !== 0) throw new Error('could not read the merge commit date');
  const date = new Date(result.stdout.trim());
  if (!Number.isFinite(date.getTime())) throw new Error('could not parse the merge commit date');
  return date;
}

function privateAuth() {
  const keyId = process.env.ASC_KEY_ID || '';
  const issuerId = process.env.ASC_ISSUER_ID || '';
  const keyPath = process.env.ASC_KEY_PATH || '';
  if (!keyId || !issuerId || !keyPath) throw new Error('release requires the staged ASC key and identifiers');
  let info;
  try { info = statSync(keyPath); } catch { throw new Error('release ASC key is unavailable'); }
  if (!info.isFile() || info.size === 0) throw new Error('release ASC key is unavailable');
  let key;
  try { key = readFileSync(keyPath, 'utf8'); } catch { throw new Error('release ASC key is unavailable'); }
  if (!key.trim()) throw new Error('release ASC key is unavailable');
  return {keyId, issuerId, key};
}

function runASC(rootDir, command, args, auth) {
  const child = spawnSync(process.execPath, [join(rootDir, 'scripts/ios-fleet/asc-api.mjs'), command, ...args], {
    encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
    env: {...process.env, ASC_KEY_ID: auth.keyId, ASC_ISSUER_ID: auth.issuerId, ASC_KEY_P8: auth.key},
  });
  if (child.error || child.status !== 0) throw new Error(`ASC ${command} query failed`);
  return child.stdout.trim();
}

export function parseAppcastFloor(xml) {
  const versions = [...xml.matchAll(/<sparkle:version>\s*([0-9]+)\s*<\/sparkle:version>/g)]
    .map(match => match[1]);
  if (versions.length === 0 || versions.some(value => value.length > 12 || BigInt(value) < 1n)) {
    throw new Error('paired Sparkle feed has no valid build floor');
  }
  return versions.reduce((highest, value) => BigInt(value) > BigInt(highest) ? value : highest);
}

function appcastFloor(url) {
  if (!url.startsWith('https://')) throw new Error('paired Sparkle feed must use HTTPS');
  const child = spawnSync('curl', [
    '-fsSL', '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '10',
    '--max-time', '30', '--max-filesize', '5000000', url,
  ], {encoding: 'utf8', maxBuffer: 5 * 1024 * 1024});
  if (child.error || child.status !== 0) throw new Error('paired Sparkle feed is unavailable');
  return parseAppcastFloor(child.stdout);
}

export function releaseMetadata({rootDir = root, date = mergeDate(rootDir), auth = privateAuth(), feedFloor} = {}) {
  const app = registry(rootDir);
  const mergeStamp = chicagoMergeStamp(date);
  const floor = feedFloor ?? appcastFloor(app.pairedBuildFeed);
  if (!/^[1-9]\d{0,11}$/.test(String(floor))) throw new Error('invalid paired build floor');
  const releasedVersion = runASC(rootDir, 'released-store-version', [app.bundleId, 'IOS'], auth);
  const marketingVersion = latestFixedMarketingVersion(app.fixedMarketingVersion, releasedVersion);
  const buildVersion = runASC(rootDir, 'plan-release-build', releaseBuildPlannerArgs(app, floor, mergeStamp), auth);
  if (!/^[1-9]\d{11}$/.test(buildVersion)) throw new Error('ASC planner returned an invalid shared build');
  return {marketingVersion, buildVersion};
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    const mode = process.argv[2] || 'release';
    const rootDir = process.argv[3] || root;
    const result = mode === 'offline'
      ? offlineBuildMetadata({mergeDate: mergeDate(rootDir), fixedVersion: registry(rootDir).fixedMarketingVersion})
      : mode === 'release'
        ? releaseMetadata({rootDir})
        : (() => { throw new Error('mode must be offline or release'); })();
    process.stdout.write(`${result.marketingVersion}\t${result.buildVersion}\n`);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'version planning failed';
    process.stderr.write(`Mac release version planning failed: ${message}\n`);
    process.exitCode = 1;
  }
}
