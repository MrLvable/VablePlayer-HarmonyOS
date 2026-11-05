'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict'), crypto = require('node:crypto');
const { ts, projectFile } = require('./test-env.cjs');
const modules = new Map(), preferences = new Map(), calls = [];
const root = projectFile('entry/src/main/ets/common');
class Request { constructor(url, method, headers, body) { Object.assign(this, { url, method, headers, body }); } }
class Encoder { encodeInto(value) { return new TextEncoder().encode(value); } }
class Decoder { constructor(label, options) { this.decoder = new TextDecoder(label, options); } decodeWithStream(value) { return this.decoder.decode(value); } }
const tree = new Map([
  ['/proxy/media/', { name: 'Media', dir: true, children: ['/proxy/media/Sub%20Folder/', '/proxy/media/%E7%89%87%E5%90%8D.mkv'] }],
  ['/proxy/media/Sub%20Folder/', { name: 'Sub Folder', dir: true, children: ['/proxy/media/Sub%20Folder/Episode.mp4'] }],
  ['/proxy/media/%E7%89%87%E5%90%8D.mkv', { name: '片名.mkv', dir: false }],
  ['/proxy/media/Sub%20Folder/Episode.mp4', { name: 'Episode.mp4', dir: false }]
]);
function response(href) {
  const value = tree.get(href); assert(value, href);
  return '<d:response><d:href>' + href + '</d:href><d:propstat><d:prop><d:displayname>' + value.name + '</d:displayname><d:resourcetype>' + (value.dir ? '<d:collection/>' : '') + '</d:resourcetype><d:getcontentlength>5000000</d:getcontentlength><d:getcontenttype>' + (value.dir ? 'httpd/unix-directory' : 'video/mp4') + '</d:getcontenttype><d:getlastmodified>Tue, 27 Oct 2026 03:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
}
const rcp = { Request, createSession: () => ({ cancel() {}, close() {}, async fetch(request) {
  calls.push(request); assert.equal(request.method, 'PROPFIND');
  assert.equal(request.headers.Authorization, 'Basic ' + Buffer.from('viewer:runtime-secret').toString('base64'));
  const current = new URL(request.url).pathname, value = tree.get(current); assert(value, current);
  const entries = [current].concat(request.headers.Depth === '1' ? value.children ?? [] : []);
  const text = '<d:multistatus xmlns:d="DAV:">' + entries.map(response).join('') + '</d:multistatus>';
  return { statusCode: 207, headers: {}, body: new TextEncoder().encode(text).buffer };
} }) };
function load(file) {
  file = path.resolve(file); if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal(output.diagnostics.length, 0, file);
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Uint8Array, ArrayBuffer, require(name) {
    if (name === '../Store') return { Store: { get: async (key, fallback) => preferences.get(key) ?? fallback, set: async (key, value) => { preferences.set(key, value); } } };
    if (name === '@kit.RemoteCommunicationKit') return { rcp };
    if (name === '@kit.ArkTS') return { url: { URL }, util: { TextEncoder: Encoder, TextDecoder: Decoder, Base64Helper: class { encodeToStringSync(value) { return Buffer.from(value).toString('base64'); } } } };
    if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd: () => { const hash = crypto.createHash('sha256'); return { updateSync: value => hash.update(value.data), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) }; } } };
    return load(path.resolve(path.dirname(file), name + '.ets'));
  } }, { filename: file });
  return module.exports;
}
const { ServerConfig } = load(path.join(root, 'Models.ets'));
const { WebDavCatalog: Catalog } = load(path.join(root, 'services/WebDavCatalog.ets'));
const server = new ServerConfig('dav-source', 'webdav', 'DAV', 'nas.invalid', 8443, 'viewer', '', 'viewer', '', '');
server.scheme = 'https'; server.basePath = '/proxy'; server.rootPath = '/media'; server.authMode = 'password';
const id = pathname => 'dav:' + encodeURIComponent(pathname);
(async () => {
  const catalog = new Catalog(); await catalog.login(server, 'runtime-secret');
  const views = await catalog.getViews(server); assert.equal(views[0].id, id('/proxy/media/'));
  const rows = await catalog.getItems(server, views[0].id, 0, 20, false);
  const folder = rows.find(item => item.isFolder()), file = rows.find(item => item.isPlayable());
  assert.equal(folder.id, id('/proxy/media/Sub%20Folder/')); assert.equal(file.id, id('/proxy/media/%E7%89%87%E5%90%8D.mkv'));
  assert(!file.id.includes('nas.invalid')); assert(!file.id.includes('runtime-secret')); assert(!file.id.includes('?'));
  const child = (await new Catalog().getItems(server, folder.id, 0, 20, false))[0];
  assert.equal(child.id, id('/proxy/media/Sub%20Folder/Episode.mp4'));
  const rootAgain = await new Catalog().getItems(server, views[0].id, 0, 20, false); assert.equal(rootAgain.length, 2);
  const found = await new Catalog().search(server, 'episode', 20); assert.equal(found[0].id, child.id);
  const detail = await new Catalog().getItemDetail(server, file.id); assert.equal(detail.item.id, file.id); assert.equal(detail.sources[0].id, file.id);
  const info = await new Catalog().playback(server, file.id, file.id);
  assert.equal(info.url, 'https://nas.invalid:8443/proxy/media/%E7%89%87%E5%90%8D.mkv'); assert.equal(info.mediaSourceId, file.id); assert.equal(info.headers.Authorization, server.token);
  assert.equal(new Catalog().stream(server, file.id), info.url);
  await assert.rejects(new Catalog().playback(server, file.id, child.id), /视频源/);

  // Real DirectCatalogBase + LocalSourceState + serialized Preferences, without a state stub.
  await catalog.addFavorite(server, file.id); assert.equal(await new Catalog().isFavorite(server, file.id), true);
  let favorites = await new Catalog().getFavorites(server, 20); assert.equal(favorites.length, 1); assert.equal(favorites[0].id, file.id); assert(favorites[0].isPlayable());
  const replay = await new Catalog().playback(server, favorites[0].id, ''); assert.equal(replay.url, info.url);
  await new Catalog().reportProgress(server, file.id, 150000000, false);
  const resume = await new Catalog().getResume(server, 20); assert.equal(resume[0].id, file.id); assert.equal(resume[0].progressTicks, 150000000);
  for (const snapshot of preferences.values()) {
    assert(!snapshot.includes('runtime-secret')); assert(!snapshot.includes(server.token)); assert(!snapshot.includes('nas.invalid')); assert(!snapshot.includes('https://'));
  }
  const other = new ServerConfig(server.id, server.kind, server.name, server.host, server.port, server.username, server.token, 'other-user', '', '');
  other.scheme = server.scheme; other.basePath = server.basePath; other.rootPath = server.rootPath; other.authMode = server.authMode;
  assert.equal((await new Catalog().getFavorites(other, 20)).length, 0, 'Same opaque path remains account scoped');
  await new Catalog().removeFavorite(server, file.id); favorites = await new Catalog().getFavorites(server, 20); assert.equal(favorites.length, 0);
  assert.equal((await new Catalog().getResume(server, 20)).length, 1, 'Unfavoriting preserves real history');

  for (const invalid of ['https://nas.invalid:8443/proxy/media/file.mkv', 'dav:%', 'dav:relative', id('//evil.invalid/file'), id('/proxy/media/../outside.mp4'), id('/proxy/media/%2e%2e/outside.mp4'), id('/proxy/media/a%2fb.mp4'), id('/proxy/media2/sibling.mp4'), id('/proxy/media/file.mkv?token=secret'), id('/proxy/media/file.mkv#fragment')]) {
    const before = calls.length; await assert.rejects(new Catalog().getItemDetail(server, invalid), /WebDAV/); assert.equal(calls.length, before, invalid);
  }
  assert.throws(() => new Catalog().subtitleUrl(server, file.id, file.id, 0, 'srt'), /不提供/);
  console.log('PASS: real WebDAV opaque canonical IDs across roots/folders/back/search/detail/source/playback; proxy/UTF-8 path round-trip; real DirectCatalogBase+LocalSourceState favorites/restart replay/history/remove/account scope, no URL/auth in preferences; invalid IDs, query/fragment/traversal/encoded separators/root siblings rejected before HTTP. Only SDK transport/preferences mocked; no device/network/build.');
})().catch(error => { console.error(error); process.exitCode = 1; });
