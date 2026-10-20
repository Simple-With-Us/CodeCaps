import test from 'node:test';
import assert from 'node:assert/strict';
import { provisionPush, pushProfileName } from './ios-enable-apns.mjs';

function profile(id, { name = pushProfileName, state = 'INVALID', content = 'production-profile' } = {}) {
  return { id, attributes: { name, profileState: state, profileType: 'IOS_APP_STORE', profileContent: content } };
}

function fixture({ enabled = false, ready = false, sourceState = 'INVALID', profiles, certificates } = {}) {
  const writes = [];
  let capability = enabled;
  const list = profiles ?? [profile('original', {
    state: ready ? 'ACTIVE' : sourceState,
    content: ready ? 'production-profile' : 'old-profile'
  })];
  const certificatesByProfile = certificates ?? { original: [{ id: 'cert', attributes: { expirationDate: '2099-01-01' } }] };
  const request = async (method, path, body) => {
    if (method === 'POST') {
      writes.push({ path, body });
      if (path.endsWith('bundleIdCapabilities')) { capability = true; return {}; }
      if (path === '/v1/profiles') return { data: { id: 'created', attributes: { name: pushProfileName,
        profileType: 'IOS_APP_STORE', profileContent: 'production-profile' } } };
      throw new Error('Unexpected write.');
    }
    if (path.startsWith('/v1/bundleIds?')) return { data: [
      { id: 'app', attributes: { identifier: 'com.simplewithus.codecaps.ios' } },
      { id: 'widget', attributes: { identifier: 'com.simplewithus.codecaps.ios.widgets' } }
    ] };
    if (path.includes('?')) throw new Error('Relationship endpoint must not have pagination parameters.');
    if (path.includes('/bundleIdCapabilities')) return { data: capability ? [{ id: 'push', attributes: { capabilityType: 'PUSH_NOTIFICATIONS' } }] : [] };
    if (path.endsWith('/profiles')) return { data: list };
    const certificateMatch = path.match(/\/v1\/profiles\/([^/]+)\/certificates$/);
    if (certificateMatch) return { data: certificatesByProfile[certificateMatch[1]] ?? [] };
    throw new Error('Unexpected request.');
  };
  return { request, writes };
}

test('enables push and creates a new profile with an existing valid certificate', async () => {
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

test('a paginated profile list cannot create a duplicate profile', async () => {
  const f = fixture();
  const request = async (method, path, body) => {
    const response = await f.request(method, path, body);
    return path.endsWith('/profiles')
      ? { ...response, links: { next: 'https://api.appstoreconnect.apple.com/v1/next-page' } }
      : response;
  };
  await assert.rejects(provisionPush(request, () => false), /paginated profile list/);
  assert.equal(f.writes.length, 0);
});

test('rejects an active existing profile without production push rather than creating a shadow', async () => {
  const f = fixture({ enabled: true, ready: true });
  await assert.rejects(provisionPush(f.request, () => false), /lacks required entitlements/);
  assert.equal(f.writes.length, 0);
});

test('missing App ID never writes to another app', async () => {
  await assert.rejects(provisionPush(async () => ({ data: [] }), () => true), /uniquely identified/);
});

test('malformed Apple resources are rejected before their ids or attributes are used', async () => {
  const f = fixture();
  const request = async (method, path, body) => {
    const value = await f.request(method, path, body);
    if (path.startsWith('/v1/bundleIds?')) return { data: [{ attributes: { identifier: 'com.simplewithus.codecaps.ios' } }] };
    return value;
  };
  await assert.rejects(provisionPush(request, () => true), /invalid bundle identifier id/);
  assert.equal(f.writes.length, 0);
});

test('malformed capability and profile attributes are rejected before mutation', async () => {
  for (const [badPath, response, expected] of [
    ['/bundleIdCapabilities', { data: [{ id: 'x', attributes: {} }] }, /invalid bundle capability type/],
    ['/profiles', { data: [{ id: 'x', attributes: { profileType: 'IOS_APP_STORE' } }] }, /invalid provisioning profile name/]
  ]) {
    const f = fixture({ enabled: true });
    const request = async (method, path, body) => path.includes(badPath) ? response : f.request(method, path, body);
    await assert.rejects(provisionPush(request, () => true), expected);
    assert.equal(f.writes.length, 0);
  }
});

test('check mode reports inspector exceptions as false per profile and does not write', async () => {
  const f = fixture({ profiles: [profile('bad', { content: 'not-a-profile' }), profile('good', {
    name: 'CodeCaps Companion Widgets AppStore', state: 'ACTIVE', content: 'also-not-a-profile'
  })] });
  const result = await provisionPush(f.request, () => { throw new Error('openssl parse failure'); }, { checkOnly: true });
  assert.deepEqual(result.profiles.map(item => item.pushReady), [false, false]);
  assert.equal(result.profile, null);
  assert.equal(f.writes.length, 0);
});

test('uses a later same-name donor when the first donor has only expired certificates', async () => {
  const f = fixture({ enabled: true, profiles: [profile('expired'), profile('usable')], certificates: {
    expired: [{ id: 'old-cert', attributes: { expirationDate: '2000-01-01' } }],
    usable: [{ id: 'new-cert', attributes: { expirationDate: '2099-01-01' } }]
  } });
  await provisionPush(f.request, value => value === 'production-profile');
  assert.deepEqual(f.writes[0].body.data.relationships.certificates.data, [{ type: 'certificates', id: 'new-cert' }]);
});

test('rejects malformed certificates and created profile data safely', async () => {
  const f = fixture({ enabled: true, certificates: { original: [{ id: 'bad', attributes: {} }] } });
  await assert.rejects(provisionPush(f.request, () => true), /invalid certificate expiration date/);
  assert.equal(f.writes.length, 0);

  const g = fixture({ enabled: true });
  const request = async (method, path, body) => {
    if (method === 'POST' && path === '/v1/profiles') {
      g.writes.push({ path, body });
      return { data: { attributes: { profileContent: 'production-profile' } } };
    }
    return g.request(method, path, body);
  };
  await assert.rejects(provisionPush(request, () => true), /invalid created profile id/);
});

test('an invalid replacement profile is rejected rather than accepted as ready', async () => {
  const f = fixture({ enabled: true });
  const request = async (method, path, body) => {
    if (method === 'POST' && path === '/v1/profiles') {
      f.writes.push({ path, body });
      return { data: { id: 'created', attributes: { name: pushProfileName,
        profileType: 'IOS_APP_STORE', profileContent: 'invalid-profile' } } };
    }
    return f.request(method, path, body);
  };
  await assert.rejects(provisionPush(request, () => false), /preserve it and do not create another/);
  assert.equal(f.writes.filter(write => write.path === '/v1/profiles').length, 1);
});
