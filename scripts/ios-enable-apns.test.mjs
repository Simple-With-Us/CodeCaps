import test from 'node:test';
import assert from 'node:assert/strict';
import { provisionPush, pushProfileName } from './ios-enable-apns.mjs';

function fixture({ enabled = false, ready = false } = {}) {
  const writes = [];
  let capability = enabled;
  const request = async (method, path, body) => {
    if (method === 'POST') {
      writes.push({ path, body });
      if (path.endsWith('bundleIdCapabilities')) { capability = true; return {}; }
      if (path === '/v1/profiles') return { data: { attributes: { profileContent: 'production-profile' } } };
      throw new Error('Unexpected write.');
    }
    if (path.startsWith('/v1/bundleIds?')) return { data: [{ id: 'app' }] };
    if (path.includes('/bundleIdCapabilities')) return { data: capability ? [{ attributes: { capabilityType: 'PUSH_NOTIFICATIONS' } }] : [] };
    if (path.includes('/profiles?')) return { data: [{ id: 'original', attributes: {
      name: ready ? pushProfileName : 'CodeCaps Companion AppStore', profileState: 'ACTIVE',
      profileType: 'IOS_APP_STORE', profileContent: 'production-profile'
    } }] };
    if (path.includes('/certificates')) return { data: [{ id: 'cert', attributes: { expirationDate: '2099-01-01' } }] };
    throw new Error('Unexpected request.');
  };
  return { request, writes };
}

test('enables push and creates a new profile with existing certificates', async () => {
  const f = fixture();
  await provisionPush(f.request, value => value === 'production-profile');
  assert.equal(f.writes.length, 2);
  assert.equal(f.writes[0].body.data.relationships.bundleId.data.id, 'app');
  assert.equal(f.writes[1].body.data.attributes.name, pushProfileName);
  assert.deepEqual(f.writes[1].body.data.relationships.certificates.data, [{ type: 'certificates', id: 'cert' }]);
});

test('verified capability and profile are idempotent', async () => {
  const f = fixture({ enabled: true, ready: true });
  await provisionPush(f.request, () => true);
  assert.equal(f.writes.length, 0);
});

test('rejects an existing profile without production push rather than replacing it', async () => {
  const f = fixture({ enabled: true, ready: true });
  await assert.rejects(provisionPush(f.request, () => false), /lacks required entitlements/);
  assert.equal(f.writes.length, 0);
});

test('missing App ID never writes to another app', async () => {
  await assert.rejects(provisionPush(async () => ({ data: [] }), () => true), /uniquely identified/);
});
