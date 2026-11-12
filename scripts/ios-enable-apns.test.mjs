import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { childEnvironment, credentialEnvironment, provisionPush, pushProfileName } from './ios-enable-apns.mjs';

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

// The credential the consumer hands to the App Store Connect client.
//
// The private key is a secret, and the approved sources are the process
// environment, a captured `fleet-secrets get NAME` and bootstrap-only
// Keychain credentials.  A caller-supplied file is not one of them, so
// nothing here reads a key file.

test('the credential comes from the environment, and a path is not a source', () => {
  // A throwaway key, generated here and never committed.
  const key = generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey
    .export({ type: 'pkcs8', format: 'pem' });
  const environment = credentialEnvironment({ ASC_KEY_P8: key });
  assert.deepEqual(Object.keys(environment), ['ASC_KEY_P8']);
  // A path on disk is not an approved source, so it is not read.
  assert.deepEqual(credentialEnvironment({ ASC_KEY_PATH: '/tmp/whatever.p8' }), {});
  // Nothing in the environment means nothing to hand over: the client
  // resolves the credential from fleet-secrets on its own.
  assert.deepEqual(credentialEnvironment({}), {});
});

test('a key that is set but is not a key is refused with the variable named', () => {
  // A silent drop would leave the child without a credential and the
  // operator with a permission message that points at nothing.
  assert.throws(
    () => credentialEnvironment({ ASC_KEY_P8: 'not a private key at all' }),
    /ASC_KEY_P8 is set but does not hold a PEM private key/
  );
});

test('the child environment is an allowlist, not a copy of the parent environment', () => {
  const child = childEnvironment({
    PATH: '/usr/bin',
    HOME: '/tmp/home',
    ASC_KEY_ID: 'SYNTHETICKEYID1',
    ASC_ISSUER_ID: 'synthetic-issuer',
    UNRELATED_RUNTIME_SECRET: 'unrelated-runtime-secret-4f1c9a'
  });
  assert.equal(child.UNRELATED_RUNTIME_SECRET, undefined, 'an unrelated secret reached the child');
  assert.deepEqual(Object.keys(child).sort(), ['ASC_ISSUER_ID', 'ASC_KEY_ID', 'HOME', 'PATH']);
});
