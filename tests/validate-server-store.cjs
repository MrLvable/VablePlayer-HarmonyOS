'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const { models, Store, values, writes } = require('./source-storage-env.cjs')();
function legacy(overrides = {}) {
  return { id: 'fixture-server', kind: 'fnos', name: 'Fixture NAS', host: '192.0.2.8', port: 8005,
    username: 'fixture-user', token: 'fixture-compat-secret', userId: 'fixture-account', ...overrides };
}
let passed = 0;
async function test(name, body) { await body(); passed++; console.log('PASS ' + name); }
(async () => {
  await Store.init({});
  await test('legacy schema missing display fields renders server titles safely without rewriting or losing identity', async () => {
    const old = legacy(), raw = JSON.stringify([old]); values.set('servers_json', raw); writes.length = 0;
    const list = await Store.loadServers(); assert.equal(list.length, 1); const server = list[0];
    assert.equal(server.serverName.length > 0 ? server.serverName : server.name, old.name);
    assert.equal(server.version.length, 0); assert.equal(server.nativeToken, '');
    for (const key of Object.keys(old)) assert.equal(server[key], old[key], key);
    assert.equal(server.baseUrl(), 'http://192.0.2.8:8005'); assert.equal(values.get('servers_json'), raw);
    assert.equal(writes.length, 0, 'Read-only migration must not rewrite preferences');
  });
  await test('null and wrong-type optional labels normalize while valid authentication and provider fields survive', async () => {
    values.set('servers_json', JSON.stringify([legacy({ name: null, serverName: null, version: 17, nativeToken: 'fixture-native-secret' })]));
    const server = (await Store.loadServers())[0];
    assert.equal(server.name, ''); assert.equal(server.serverName, ''); assert.equal(server.version, '');
    assert.equal(server.nativeToken, 'fixture-native-secret'); assert.equal(server.token, 'fixture-compat-secret');
    assert.equal(server.kind, 'fnos'); assert.equal(server.userId, 'fixture-account');
  });
  await test('three provider records and unknown provider identity round-trip without token or account changes', async () => {
    const expected = ['fnos', 'emby', 'jellyfin', 'future-provider'].map((kind, index) => legacy({
      id: 'fixture-' + index, kind, nativeToken: 'fixture-native-' + index, serverName: 'Fixture Server', version: '1.2.3' }));
    values.set('servers_json', JSON.stringify(expected)); const list = await Store.loadServers();
    await Store.saveServers(list); const restored = await Store.loadServers();
    assert.equal(restored.length, expected.length);
    for (let index = 0; index < expected.length; index++) {
      for (const key of Object.keys(expected[index])) assert.equal(restored[index][key], expected[index][key], key);
    }
  });
  await test('malformed rows do not abort adjacent valid servers or fabricate a connection destination', async () => {
    values.set('servers_json', JSON.stringify([null, 3, legacy({ id: '' }), legacy({ host: null }),
      legacy({ port: '8005' }), legacy({ port: 0 }), legacy({ port: 65536 }), legacy({ kind: null }), legacy()]));
    const result = await Store.loadServers(); assert.equal(result.length, 1); assert.equal(result[0].id, 'fixture-server');
    for (const raw of ['null', '{}', 'invalid JSON']) { values.set('servers_json', raw); assert.equal((await Store.loadServers()).length, 0); }
  });
  await test('constructor never overwrites safe display defaults with absent or malformed values', async () => {
    const server = new models.ServerConfig('id', 'emby', undefined, '192.0.2.8', 8096, 'user', 'fixture-token', 'account', undefined, null);
    assert.equal(server.name.length + server.serverName.length + server.version.length, 0);
    assert.equal(server.kind, 'emby'); assert.equal(server.port, 8096); assert.equal(server.token, 'fixture-token');
  });
  console.log('PASS: ' + passed + ' actual Store/Models groups; fixture-only preferences, no device or production credentials.');
})().catch(error => { console.error(error); process.exitCode = 1; });
