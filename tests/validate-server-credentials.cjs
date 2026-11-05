'use strict';
const assert = require('node:assert/strict');
const fixture = require('./source-storage-env.cjs');
let passed = 0;
async function test(name, body) { await body(); passed++; console.log('PASS ' + name); }
function profile(env, id = 'fixture-server', kind = 'webdav') {
  const server = new env.models.ServerConfig(id, kind, 'Fixture', '192.0.2.8', 8080,
    'fixture-user', 'fixture-token', 'fixture-account');
  server.password = 'fixture-password'; server.authMode = 'password'; return server;
}
(async () => {
  await test('actual assets split long Unicode secrets and signed URLs without a plaintext Preferences fallback', async () => {
    const env = fixture(), secrets = new env.ServerSecretValues();
    secrets.password = '测试🔑'.repeat(300); secrets.sourceUrl = 'https://example.invalid/list?token=' + 'q'.repeat(6000);
    const ref = await env.ServerCredentials.write(secrets), read = await env.ServerCredentials.read(ref);
    assert.equal(read.password, secrets.password); assert.equal(read.sourceUrl, secrets.sourceUrl);
    assert(env.assets.size > 3); assert.equal(env.values.size, 0);
    await env.ServerCredentials.remove(ref); assert.equal(env.assets.size, 0);
  });
  await test('a partial asset write cleans only the new version and retains the previous readable credential', async () => {
    const env = fixture(), old = new env.ServerSecretValues(); old.token = 'fixture-old-token';
    const ref = await env.ServerCredentials.write(old), count = env.assets.size;
    const next = new env.ServerSecretValues(); next.password = 'x'.repeat(2000);
    env.control.failAddAt = env.control.addCalls + 2;
    await assert.rejects(env.ServerCredentials.write(next), /安全凭据保存失败/);
    assert.equal(env.assets.size, count); assert.equal((await env.ServerCredentials.read(ref)).token, old.token);
  });
  await test('missing chunks and cross-namespace references are rejected rather than producing an empty successful login', async () => {
    const env = fixture(), value = new env.ServerSecretValues(); value.token = 'fixture-secret';
    const ref = await env.ServerCredentials.write(value); env.assets.delete('nasplayer.server.' + ref + '.p0');
    await assert.rejects(env.ServerCredentials.read(ref), /不完整/);
    await assert.rejects(env.ServerCredentials.read('nasplayer.ai.translation.v1'), /引用无效/);
  });
  await test('explicit profile save migrates all credentials and resource URLs to assets, and load hydrates them', async () => {
    const env = fixture(); await env.Store.init({}); const server = profile(env);
    server.scheme = 'https'; server.basePath = '/dav'; server.rootPath = '/movies';
    server.sourceUrl = 'https://example.invalid/list?secret=fixture'; server.epgUrl = 'https://example.invalid/epg?key=fixture';
    server.clientSecret = 'fixture-client-secret'; server.refreshToken = 'fixture-refresh';
    await env.Store.upsert(server);
    const raw = env.values.get('servers_json');
    for (const value of [server.token, server.password, server.sourceUrl, server.epgUrl, server.clientSecret, server.refreshToken]) {
      assert(!raw.includes(value), 'Secret must not occur in public profile JSON');
    }
    const restored = (await env.Store.loadServers())[0];
    for (const key of ['token', 'password', 'sourceUrl', 'epgUrl', 'clientSecret', 'refreshToken', 'basePath', 'rootPath', 'scheme']) {
      assert.equal(restored[key], server[key], key);
    }
    assert.equal(restored.baseUrl(), 'https://192.0.2.8:8080/dav');
  });
  await test('blank compatible edit preserves credentials while changing endpoint, without losing IPv6 or subpaths', async () => {
    const env = fixture(); await env.Store.init({}); const first = profile(env); await env.Store.upsert(first);
    const edit = profile(env); edit.token = ''; edit.password = ''; edit.host = '2001:db8::9'; edit.basePath = '/media';
    await env.Store.upsert(edit); const saved = (await env.Store.loadServers())[0];
    assert.equal(saved.password, first.password); assert.equal(saved.token, first.token);
    assert.equal(saved.baseUrl(), 'http://[2001:db8::9]:8080/media');
  });
  await test('new account/provider never inherits the old secret, and explicit clear retains new values and resource URLs', async () => {
    const env = fixture(); await env.Store.init({}); const first = profile(env); await env.Store.upsert(first);
    const edit = profile(env); edit.username = 'other-account'; edit.token = ''; edit.password = '';
    await env.Store.upsert(edit); assert.equal((await env.Store.loadServers())[0].token, '');
    edit.clearCredentials = true; edit.authMode = 'anonymous'; edit.token = 'fixture-new-explicit-token';
    edit.sourceUrl = 'https://example.invalid/live?token=fixture'; await env.Store.upsert(edit);
    const saved = (await env.Store.loadServers())[0]; assert.equal(saved.token, edit.token); assert.equal(saved.sourceUrl, edit.sourceUrl);
  });
  await test('a failed Preferences commit restores the prior public row and leaves its old encrypted credential intact', async () => {
    const env = fixture(); await env.Store.init({}); const server = profile(env); await env.Store.upsert(server);
    const previous = env.values.get('servers_json'), oldCount = env.assets.size;
    server.token = 'fixture-replacement-token'; env.control.failFlush = 1;
    await assert.rejects(env.Store.upsert(server), /配置保存失败/);
    assert.equal(env.values.get('servers_json'), previous); assert.equal(env.assets.size, oldCount);
    assert.equal((await env.Store.loadServers())[0].token, 'fixture-token');
  });
  await test('vault unavailability fails save safely and preserves visible profile identity on load', async () => {
    const env = fixture(); await env.Store.init({}); const server = profile(env); await env.Store.upsert(server);
    const previous = env.values.get('servers_json'); env.control.locked = true; server.token = 'fixture-changed';
    await assert.rejects(env.Store.upsert(server)); assert.equal(env.values.get('servers_json'), previous);
    const read = (await env.Store.loadServers())[0]; assert.equal(read.id, server.id); assert(read.credentialError.length > 0);
    assert.equal(read.token, ''); assert(!env.values.get('servers_json').includes('fixture-changed'));
  });
  await test('concurrent adds serialize read-modify-write and remove deletes the retired asset version', async () => {
    const env = fixture(); await env.Store.init({});
    await Promise.all([env.Store.upsert(profile(env, 'one')), env.Store.upsert(profile(env, 'two'))]);
    assert.equal((await env.Store.loadServers()).length, 2);
    await env.Store.remove('one'); assert.equal((await env.Store.loadServers()).length, 1);
    await env.Store.remove('two'); assert.equal(env.assets.size, 0);
  });
  await test('addressless local and IPTV profiles survive restart with their real source URI', async () => {
    const env = fixture(); await env.Store.init({});
    for (const kind of ['local', 'iptv', 'custom']) {
      const server = profile(env, kind, kind); server.host = ''; server.port = 0; server.token = ''; server.password = '';
      server.sourceUrl = kind === 'local' ? 'file://docs/storage/fixture' : 'https://example.invalid/' + kind;
      await env.Store.upsert(server);
    }
    const saved = await env.Store.loadServers(); assert.equal(saved.length, 3); assert(saved.every(server => server.sourceUrl.length > 0));
  });
  await test('credential refresh is compare-and-swap, preserves a newer name, and rejects a stale token rotation', async () => {
    const env = fixture(); await env.Store.init({}); const original = profile(env); await env.Store.upsert(original);
    const refresh = (await env.Store.loadServers())[0], expected = refresh.credentialRef;
    const rename = (await env.Store.loadServers())[0]; rename.name = 'New display name'; await env.Store.upsert(rename);
    refresh.token = 'fixture-rotated'; assert.equal(await env.Store.refreshServerCredentials(refresh, expected), true);
    assert.equal((await env.Store.loadServers())[0].name, rename.name);
    assert.equal(await env.Store.refreshServerCredentials(refresh, expected), false);
    assert.equal((await env.Store.loadServers())[0].token, 'fixture-rotated');
  });
  console.log('PASS: ' + passed + ' actual AssetStore/Repository groups with SDK mocks; no device or production credentials.');
})().catch(error => { console.error(error); process.exitCode = 1; });
