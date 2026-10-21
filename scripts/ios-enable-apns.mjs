#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

import { clientEnvironment, normalizePrivateKey } from './ios-fleet/asc-key.mjs';

export const bundleIdentifier = 'com.simplewithus.codecaps.ios';
export const pushProfileName = 'CodeCaps Companion AppStore';

// This repo's Apple API scripts are dependency-free, so validate the JSON:API
// boundary with small strict validators instead of adding a runtime schema package.
function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`Apple returned an invalid ${label}.`);
  }
  return value;
}

function requiredString(value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`Apple returned an invalid ${label}.`);
  }
  return value;
}

function resource(value, label) {
  const item = object(value, label);
  requiredString(item.id, `${label} id`);
  const attributes = object(item.attributes, `${label} attributes`);
  return { ...item, attributes };
}

function collection(response, label, validateAttributes) {
  const body = object(response, `${label} response`);
  if (!Array.isArray(body.data)) throw new Error(`Apple returned an invalid ${label} list.`);
  return body.data.map((item) => {
    const validated = resource(item, label);
    validateAttributes(validated.attributes);
    return validated;
  });
}

function bundleResources(response) {
  return collection(response, 'bundle identifier', attributes => {
    requiredString(attributes.identifier, 'bundle identifier');
  });
}

function capabilityResources(response) {
  return collection(response, 'bundle capability', attributes => {
    requiredString(attributes.capabilityType, 'bundle capability type');
  });
}

function profileResources(response) {
  if (response?.links?.next != null) {
    throw new Error('Apple returned a paginated profile list; verify all pages before provisioning.');
  }
  return collection(response, 'provisioning profile', attributes => {
    requiredString(attributes.name, 'provisioning profile name');
    requiredString(attributes.profileType, 'provisioning profile type');
    requiredString(attributes.profileState, 'provisioning profile state');
    if (attributes.profileContent != null && typeof attributes.profileContent !== 'string') {
      throw new Error('Apple returned an invalid provisioning profile content field.');
    }
  });
}

function certificateResources(response) {
  return collection(response, 'certificate', attributes => {
    requiredString(attributes.expirationDate, 'certificate expiration date');
  });
}

function createdProfileResource(response) {
  const body = object(response, 'created profile response');
  const created = resource(body.data, 'created profile');
  if (created.attributes.profileType !== 'IOS_APP_STORE') {
    throw new Error('Apple returned a created profile with an unexpected type.');
  }
  if (created.attributes.name !== pushProfileName) {
    throw new Error('Apple returned a created profile with an unexpected name.');
  }
  if (created.attributes.profileContent != null && typeof created.attributes.profileContent !== 'string') {
    throw new Error('Apple returned invalid created profile content.');
  }
  return created;
}

function inspectSafely(inspectProfile, content) {
  try {
    return typeof content === 'string' && inspectProfile(content) === true;
  } catch {
    return false;
  }
}

function validCertificateIds(response) {
  const certificates = certificateResources(response);
  return certificates
    .filter(item => Number.isFinite(Date.parse(item.attributes.expirationDate))
      && Date.parse(item.attributes.expirationDate) > Date.now())
    .map(item => ({ type: 'certificates', id: item.id }));
}

/// Enable only this app's push capability and create a replacement profile without deleting old profiles.
export async function provisionPush(request, inspectProfile, { checkOnly = false } = {}) {
  const bundles = bundleResources(await request('GET', `/v1/bundleIds?filter[identifier]=${bundleIdentifier}&limit=200`));
  // Apple can return prefix matches, including the widget's App ID.
  const exact = bundles.filter(x => x.attributes.identifier === bundleIdentifier);
  if (exact.length !== 1) throw new Error('CodeCaps iOS App ID was not uniquely identified.');
  const bundle = exact[0];
  // These relationship endpoints reject pagination parameters.
  const capabilities = capabilityResources(await request('GET', `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`));
  const profiles = profileResources(await request('GET', `/v1/bundleIds/${bundle.id}/profiles`));
  const distribution = profiles.filter(x => x.attributes.profileType === 'IOS_APP_STORE');
  const active = distribution.filter(x => x.attributes.profileState === 'ACTIVE');
  const ready = active.find(x => x.attributes.name === pushProfileName);
  const capabilityReady = capabilities.some(x => x.attributes.capabilityType === 'PUSH_NOTIFICATIONS');
  if (checkOnly) return {
    capability: capabilityReady,
    profile: ready && inspectSafely(inspectProfile, ready.attributes.profileContent) ? pushProfileName : null,
    profiles: distribution.map(x => ({ name: x.attributes.name, state: x.attributes.profileState,
      pushReady: inspectSafely(inspectProfile, x.attributes.profileContent) }))
  };
  if (!capabilityReady) {
    await request('POST', '/v1/bundleIdCapabilities', { data: {
      type: 'bundleIdCapabilities', attributes: { capabilityType: 'PUSH_NOTIFICATIONS' },
      relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } }
    } });
  }
  const verified = capabilityResources(await request('GET', `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`));
  if (!verified.some(x => x.attributes.capabilityType === 'PUSH_NOTIFICATIONS')) {
    throw new Error('Apple did not confirm the Push Notifications capability.');
  }
  if (ready && inspectSafely(inspectProfile, ready.attributes.profileContent)) return { capability: true, profile: pushProfileName };
  if (ready) throw new Error('Existing push profile lacks required entitlements; preserve it for investigation.');
  // A capability change may invalidate an old profile while its certificate
  // remains valid.  Reuse a valid certificate from any same-name donor profile.
  // If a prior replacement is active but unusable, the guard above fails closed
  // instead of creating another same-name profile that signing could select.
  const candidates = distribution.filter(x => x.attributes.name === 'CodeCaps Companion AppStore');
  if (!candidates.length) throw new Error('Existing CodeCaps distribution profile is missing; cannot select its signing certificate.');
  let ids = [];
  for (const candidate of candidates) {
    ids = validCertificateIds(await request('GET', `/v1/profiles/${candidate.id}/certificates`));
    if (ids.length) break;
  }
  if (!ids.length) throw new Error('Existing CodeCaps distribution profile has no valid certificate.');
  const created = createdProfileResource(await request('POST', '/v1/profiles', { data: {
    type: 'profiles', attributes: { name: pushProfileName, profileType: 'IOS_APP_STORE' },
    relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } }, certificates: { data: ids } }
  } }));
  if (!inspectSafely(inspectProfile, created.attributes.profileContent)) {
    throw new Error('New distribution profile did not include production APNs and the CodeCaps App Group; preserve it and do not create another same-name profile.');
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

// The credential the App Store Connect client runs with.
//
// The client resolves its credential from the process environment, from
// fleet-secrets and from the bootstrap Keychain.  A path on disk is not an
// approved secret source (Kody rule 42), so this wrapper never reads one:
// ASC_KEY_PATH is not a credential source here, and the key is taken from
// the environment and handed to the child in the child's environment.
//
// The key never reaches a command line, a log, the environment file or a
// temporary file.  It does reach the child's environment, where the client
// looks for it, and the environment of a same-user process is readable on
// this platform (`ps eww`, `ps -E`):  the handoff keeps the key out of argv,
// out of stdout and out of every log line, and claims nothing more.
//
// A key that is set but is not a PEM private key is refused here, with the
// variable named.  A silent drop would leave the child without a credential
// and the operator with a permission message that says nothing about the
// input that was wrong.
export function credentialEnvironment(env = process.env) {
  const raw = typeof env.ASC_KEY_P8 === 'string' ? env.ASC_KEY_P8 : '';
  if (!raw.trim()) return {};
  const pem = normalizePrivateKey(raw);
  if (!pem) throw new Error('ASC_KEY_P8 is set but does not hold a PEM private key');
  return { ASC_KEY_P8: pem };
}

// The child's environment.
//
// It is an allowlist, not a copy of this process's environment:  a wholesale
// copy forwards every credential on the operator's machine, including the
// ones that have nothing to do with App Store Connect.
export function childEnvironment(env = process.env) {
  return clientEnvironment(env, credentialEnvironment(env));
}

async function run() {
  const client = fileURLToPath(new URL('./ios-fleet/asc-api.mjs', import.meta.url));
  // The child gets the credential and the variables it needs, and nothing
  // else.  The credential is in the child's environment because that is where
  // the client looks for it.
  let childEnv;
  try {
    childEnv = childEnvironment();
  } catch (error) {
    console.error(`ios-enable-apns: ${error.message}`);
    process.exitCode = 1;
    return;
  }
  const request = async (method, path, body) => {
    const args = [client, method, path];
    if (body) args.push(JSON.stringify(body));
    try {
      return JSON.parse(execFileSync(process.execPath, args, {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 8 * 1024 * 1024, env: childEnv
      }));
    } catch (error) {
      //  The client's own diagnostic names what it could not resolve, so it
      //  is carried over instead of being replaced by a generic permission
      //  message that points at nothing.
      const stderrText = error.stderr?.toString() ?? '';
      const auth = stderrText.split('\n').filter(line => line.startsWith('asc-auth:')).join(' ');
      let codes = '';
      try {
        const failure = JSON.parse(error.stdout?.toString() ?? '{}');
        const errors = Array.isArray(failure.errors) ? failure.errors : [];
        codes = errors.map(item => {
          if (!item || typeof item.code !== 'string' || typeof item.title !== 'string') return null;
          return `${item.code}: ${item.title}`;
        }).filter(Boolean).join('; ');
      } catch { /* Keep profile contents and credential material out of errors. */ }
      const reason = auth || codes || 'Check ASC credential access and API permissions.';
      throw new Error(`Apple provisioning request failed: ${method} ${path.split('?')[0]}.  ${reason}`);
    }
  };
  const checkOnly = process.argv.includes('--check');
  provisionPush(request, inspectProductionProfile, { checkOnly }).then(result => {
    if (checkOnly) console.log(JSON.stringify(result));
    else console.log(`CodeCaps Push Notifications enabled; verified profile: ${result.profile}.`);
  }).catch(error => { console.error(error.message); process.exitCode = 1; });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run();
}
