#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

export const bundleIdentifier = 'com.simplewithus.codecaps.ios';
export const pushProfileName = 'CodeCaps Companion AppStore';

/// Enable only this app's push capability and create a replacement profile without deleting old profiles.
export async function provisionPush(request, inspectProfile, { checkOnly = false } = {}) {
  const bundles = await request('GET', `/v1/bundleIds?filter[identifier]=${bundleIdentifier}&limit=200`);
  // Apple can return prefix matches, including the widget's App ID.
  const exact = (bundles.data ?? []).filter(x => x.attributes?.identifier === bundleIdentifier);
  if (exact.length !== 1) throw new Error('CodeCaps iOS App ID was not uniquely identified.');
  const bundle = exact[0];
  // These relationship endpoints reject pagination parameters.
  const capabilities = await request('GET', `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`);
  const profiles = await request('GET', `/v1/bundleIds/${bundle.id}/profiles`);
  const distribution = (profiles.data ?? []).filter(x => x.attributes?.profileType === 'IOS_APP_STORE');
  const active = distribution.filter(x => x.attributes?.profileState === 'ACTIVE');
  const ready = active.find(x => x.attributes?.name === pushProfileName);
  if (checkOnly) return {
    capability: capabilities.data?.some(x => x.attributes?.capabilityType === 'PUSH_NOTIFICATIONS') ?? false,
    profile: ready && inspectProfile(ready.attributes.profileContent) ? pushProfileName : null,
    profiles: distribution.map(x => ({ name: x.attributes.name, state: x.attributes.profileState,
      pushReady: inspectProfile(x.attributes.profileContent) }))
  };
  if (!capabilities.data?.some(x => x.attributes?.capabilityType === 'PUSH_NOTIFICATIONS')) {
    await request('POST', '/v1/bundleIdCapabilities', { data: {
      type: 'bundleIdCapabilities', attributes: { capabilityType: 'PUSH_NOTIFICATIONS' },
      relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } }
    } });
  }
  const verified = await request('GET', `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`);
  if (!verified.data?.some(x => x.attributes?.capabilityType === 'PUSH_NOTIFICATIONS')) {
    throw new Error('Apple did not confirm the Push Notifications capability.');
  }
  if (ready && inspectProfile(ready.attributes.profileContent)) return { capability: true, profile: pushProfileName };
  if (ready) throw new Error('Existing push profile lacks required entitlements; preserve it for investigation.');
  // A capability change may invalidate the old profile while its certificate
  // remains valid.  Reuse that certificate without deleting the old profile.
  const source = distribution.find(x => x.attributes?.name === 'CodeCaps Companion AppStore');
  if (!source) throw new Error('Existing CodeCaps distribution profile is missing; cannot select its signing certificate.');
  const certificates = await request('GET', `/v1/profiles/${source.id}/certificates`);
  const ids = (certificates.data ?? []).filter(x => Date.parse(x.attributes?.expirationDate) > Date.now())
    .map(x => ({ type: 'certificates', id: x.id }));
  if (!ids.length) throw new Error('Existing CodeCaps distribution profile has no valid certificate.');
  const created = await request('POST', '/v1/profiles', { data: {
    type: 'profiles', attributes: { name: pushProfileName, profileType: 'IOS_APP_STORE' },
    relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } }, certificates: { data: ids } }
  } });
  if (!inspectProfile(created.data?.attributes?.profileContent)) {
    throw new Error('New distribution profile did not include production APNs and the CodeCaps App Group.');
  }
  return { capability: true, profile: pushProfileName };
}

function inspectProductionProfile(encoded) {
  if (!encoded) return false;
  const xml = execFileSync('/usr/bin/openssl', ['cms', '-verify', '-inform', 'DER', '-noverify'], {
    input: Buffer.from(encoded, 'base64'), stdio: ['pipe', 'pipe', 'ignore'], maxBuffer: 4 * 1024 * 1024
  }).toString('utf8');
  return /<key>aps-environment<\/key>\s*<string>production<\/string>/.test(xml)
    && xml.includes('group.com.simplewithus.codecaps')
    && xml.includes(`.${bundleIdentifier}</string>`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const client = fileURLToPath(new URL('./ios-fleet/asc-api.mjs', import.meta.url));
  const request = async (method, path, body) => {
    const args = [client, method, path];
    if (body) args.push(JSON.stringify(body));
    try {
      return JSON.parse(execFileSync(process.execPath, args, {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 8 * 1024 * 1024
      }));
    } catch (error) {
      let codes = '';
      try {
        const failure = JSON.parse(error.stdout?.toString() ?? '{}');
        codes = (failure.errors ?? []).map(item => `${item.code}: ${item.title}`).join('; ');
      } catch { /* Keep profile contents and credential material out of errors. */ }
      throw new Error(`Apple provisioning request failed: ${method} ${path.split('?')[0]}.${codes ? '  ' + codes : '  Check ASC credential access and API permissions.'}`);
    }
  };
  const checkOnly = process.argv.includes('--check');
  provisionPush(request, inspectProductionProfile, { checkOnly }).then(result => {
    if (checkOnly) console.log(JSON.stringify(result));
    else console.log(`CodeCaps Push Notifications enabled; verified profile: ${result.profile}.`);
  }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
