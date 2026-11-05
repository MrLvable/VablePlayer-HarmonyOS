'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { ts, projectFile } = require('./test-env.cjs');
const root = projectFile('entry/src/main/ets/common');
const modules = new Map(), calls = [], sockets = [], timers = new Map();
let timerId = 0, nextSession = 1, nextRead = null, nextOpen = null;
let rows = [], fileSize = 3 * 1024 * 1024 * 1024 + 123;
const native = {
  stat: async (options, p) => { calls.push(['stat', options, p]); return { type: p.endsWith('.mkv') ? 0 : 1, isDirectory: !p.endsWith('.mkv'), size: p.endsWith('.mkv') ? fileSize : 0, modifiedTime: 1234 }; },
  listDirectory: async (options, p) => { calls.push(['list', options, p]); return rows; },
  openRead: async (options, p) => { calls.push(['open', options, p]); if (nextOpen) { const action = nextOpen; nextOpen = null; return action(); } return { sessionId: nextSession++, size: fileSize, modifiedTime: 1234 }; },
  readAt: async (id, offset, length, requestId) => {
    calls.push(['read', id, offset, length, requestId]);
    assert(length <= 256 * 1024, 'Bridge must bound every native read, including open-ended GET');
    if (nextRead) { const action = nextRead; nextRead = null; return action(); }
    const out = new Uint8Array(Math.min(length, fileSize - offset));
    for (let i = 0; i < out.length; i++) out[i] = (offset + i) % 251;
    return out.buffer;
  },
  cancelRead: id => calls.push(['cancel', id]),
  close: async id => { calls.push(['close', id]); }
};
const local = { getResume: async () => [], getFavorites: async () => [], addFavorite: async () => {}, removeFavorite: async () => {}, isFavorite: async () => false, reportProgress: async () => {} };
function load(file) {
  file = path.resolve(file);
  if (path.basename(file) === 'LocalSourceState.ets') return { LocalSourceState: local };
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal(output.diagnostics.length, 0, file);
  const requireModule = name => {
    if (name === 'libnas_smb.so') return { default: native };
    if (name === '@kit.ArkTS') return { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } };
    if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: {
      createRandom: () => ({ generateRandomSync: count => ({ data: new Uint8Array(count).fill(17) }) }),
      createMd: () => { const hash = crypto.createHash('sha256'); return { updateSync: blob => hash.update(blob.data), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) }; }
    } };
    if (name === '@kit.NetworkKit') return { socket: { constructTCPSocketServerInstance: () => {
      const server = { handlers: {}, listens: [], closed: 0, on(event, fn) { this.handlers[event] = fn; }, async listen(value) { this.listens.push(value); }, async getLocalAddress() { return { port: 19001 }; }, async close() { this.closed++; } };
      sockets.push(server); return server;
    } } };
    return load(path.resolve(path.dirname(file), name + '.ets'));
  };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, require: requireModule, Uint8Array, ArrayBuffer,
    setTimeout: fn => { const id = ++timerId; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id) }, { filename: file });
  return module.exports;
}
const { ServerConfig } = load(path.join(root, 'Models.ets'));
const { SmbNative } = load(path.join(root, 'services/SmbNative.ets'));
const { SmbRangeBridge } = load(path.join(root, 'services/SmbRangeBridge.ets'));
const { SmbCatalog } = load(path.join(root, 'services/SmbCatalog.ets'));
const { SmbAdapter } = load(path.join(root, 'services/SmbAdapter.ets'));
const server = new ServerConfig('source', 'smb', 'Share', '192.0.2.10', 445, 'user', '', '');
server.shareName = 'video'; server.rootPath = '/Movies'; server.password = 'private-test-only';
const tick = async () => { for (let i = 0; i < 16; i++) await Promise.resolve(); };
const connection = () => ({ handlers: {}, sent: [], closed: 0, sendGate: null,
  on(event, fn) { this.handlers[event] = fn; },
  async send(value) { this.sent.push(value.data); if (typeof value.data !== 'string' && this.sendGate) await this.sendGate; },
  async close() { this.closed++; },
  request(text) { const data = new TextEncoder().encode(text); this.handlers.message({ message: data.buffer }); }
});
const request = async (bridge, url, method, range = '', extra = '') => {
  const client = connection(); sockets.at(-1).handlers.connect(client);
  client.request(method + ' ' + new URL(url).pathname + ' HTTP/1.1\r\nHost: 127.0.0.1\r\n' + (range ? 'Range: ' + range + '\r\n' : '') + extra + '\r\n');
  await tick(); return client;
};
let groups = 0;
(async () => {
  const options = SmbNative.options(server);
  assert.equal(options.server, '192.0.2.10:445'); assert.equal(options.password, 'private-test-only');
  assert.equal(options.server.includes(options.password), false);
  server.authMode = 'anonymous'; assert.equal(SmbNative.options(server).password, ''); server.authMode = 'password';
  server.host = '2001:db8::1'; assert.equal(SmbNative.options(server).server, '[2001:db8::1]:445'); server.host = '192.0.2.10'; groups++;

  assert.equal(SmbNative.fromId(server, SmbNative.id('/Movies/中文 a.mkv')), '/Movies/中文 a.mkv');
  assert.throws(() => SmbNative.fromId(server, SmbNative.id('/Outside/a.mkv')), /根目录/);
  assert.throws(() => SmbNative.fromId(server, 'smb:%2FMovies%2F..%2Fsecret'), /标识/);
  assert.throws(() => SmbNative.path('/Movies/./x'), /相对/); groups++;

  const catalog = new SmbCatalog();
  rows = [{ name: 'A.mkv', type: 0, isDirectory: false, size: fileSize, modifiedTime: 1 },
    { name: 'Season folder', type: 1, isDirectory: true, size: 0, modifiedTime: 2 },
    { name: 'readme.txt', type: 0, isDirectory: false, size: 9, modifiedTime: 3 },
    { name: 'unfollowed link', type: 2, isDirectory: false, size: 0, modifiedTime: 0 }];
  const items = await catalog.getItems(server, SmbNative.id('/Movies'), 0, 20, false);
  assert.equal(items.length, 3); assert.equal(items[0].type, 'Folder'); assert.equal(items.find(i => i.name === 'A.mkv').type, 'Video');
  assert.equal(items.find(i => i.name === 'readme.txt').isPlayable(), false);
  assert.equal(items.every(i => !i.hasPrimaryImage && i.seriesId === '' && !i.indexNumberKnown), true);
  const detail = await catalog.getItemDetail(server, SmbNative.id('/Movies/A.mkv'));
  assert.equal(detail.sources[0].sizeBytes, fileSize); assert.equal(detail.sources[0].streams.length, 0); assert.equal(detail.item.favoriteKnown, true);
  await assert.rejects(catalog.getLatest(server, '', 10), /目录浏览/); groups++;

  const originalList = native.listDirectory;
  native.listDirectory = async () => { throw new Error('SMB_CONNECT_OR_AUTH_FAILED'); };
  await assert.rejects(catalog.getItems(server, SmbNative.id('/Movies'), 0, 10, false), /AUTH_FAILED/);
  native.listDirectory = originalList; groups++;

  const bridge = new SmbRangeBridge(); const url = await bridge.start(server, '/Movies/A.mkv');
  assert.equal(new URL(url).hostname, '127.0.0.1'); assert.equal(new URL(url).pathname.includes('private-test-only'), false);
  assert.equal(sockets.at(-1).listens[0].address, '127.0.0.1'); assert.equal(sockets.at(-1).listens[0].port, 0);
  const beforeHead = calls.filter(c => c[0] === 'read').length;
  const head = await request(bridge, url, 'HEAD');
  assert.match(head.sent[0], /200 OK/); assert.match(head.sent[0], new RegExp('Content-Length: ' + fileSize));
  assert.equal(calls.filter(c => c[0] === 'read').length, beforeHead); assert.equal(head.closed, 1); groups++;

  const bounded = await request(bridge, url, 'GET', 'bytes=0-7');
  assert.match(bounded.sent[0], /206 Partial Content/); assert.match(bounded.sent[0], /Content-Range: bytes 0-7\//);
  assert.equal(bounded.sent[1].byteLength, 8); assert.deepEqual([...new Uint8Array(bounded.sent[1])], [0,1,2,3,4,5,6,7]);
  const offset = 2 * 1024 * 1024 * 1024 + 19;
  const seek = await request(bridge, url, 'GET', 'bytes=' + offset + '-' + (offset + 15));
  assert.equal(calls.filter(c => c[0] === 'read').at(-1)[2], offset); assert.equal(seek.sent[1].byteLength, 16); groups++;

  const suffix = await request(bridge, url, 'GET', 'bytes=-12'); assert.equal(suffix.sent[1].byteLength, 12);
  for (const bad of ['bytes=0-1,4-5', 'bytes=-0', 'bytes=9007199254740992-', 'bytes=10-3', 'bytes=' + fileSize + '-']) {
    const response = await request(bridge, url, 'GET', bad); assert.match(response.sent[0], /416 Range Not Satisfiable/);
  }
  const duplicate = await request(bridge, url, 'GET', 'bytes=0-1', 'Range: bytes=2-3\r\n'); assert.match(duplicate.sent[0], /416/);
  const wrong = await request(bridge, url.replace('/smb/', '/bad/'), 'HEAD'); assert.match(wrong.sent[0], /404/);
  const method = await request(bridge, url, 'POST'); assert.match(method.sent[0], /405/); groups++;

  nextRead = () => Promise.resolve(new ArrayBuffer(0));
  const short = await request(bridge, url, 'GET', 'bytes=0-7');
  assert.equal(short.sent.length, 1); assert.equal(short.closed, 1, 'Premature EOF stops instead of spinning'); groups++;

  let releaseSend; const openEnded = connection(); openEnded.sendGate = new Promise(resolve => { releaseSend = resolve; });
  sockets.at(-1).handlers.connect(openEnded);
  const countBefore = calls.filter(c => c[0] === 'read').length;
  openEnded.request('GET ' + new URL(url).pathname + ' HTTP/1.1\r\nRange: bytes=0-\r\n\r\n');
  await tick(); assert.equal(calls.filter(c => c[0] === 'read').length - countBefore, 1);
  assert.equal(openEnded.sent[1].byteLength, 256 * 1024, 'No entire file allocation');
  openEnded.handlers.close(); releaseSend(); await tick();
  assert.equal(calls.filter(c => c[0] === 'read').length - countBefore, 1, 'Client close stops read-ahead'); groups++;

  let resolveRead; nextRead = () => new Promise(resolve => { resolveRead = resolve; });
  const pending = connection(); sockets.at(-1).handlers.connect(pending);
  pending.request('GET ' + new URL(url).pathname + ' HTTP/1.1\r\nRange: bytes=100-199\r\n\r\n');
  await tick(); const id = calls.filter(c => c[0] === 'read').at(-1)[4]; pending.handlers.close();
  assert.equal(calls.some(c => c[0] === 'cancel' && c[1] === id), true);
  resolveRead(new ArrayBuffer(100)); await tick(); assert.equal(pending.sent.length, 1, 'Cancelled data never sent');
  const afterSeek = await request(bridge, url, 'GET', 'bytes=500-507'); assert.equal(afterSeek.sent[1].byteLength, 8, 'Seek close keeps shared session usable'); groups++;

  const first = connection(), second = connection(), third = connection();
  const listener = sockets.at(-1); listener.handlers.connect(first); listener.handlers.connect(second); listener.handlers.connect(third);
  assert.equal(third.closed, 1, 'At most two clients');
  first.handlers.close(); second.handlers.close();
  const sessionId = calls.filter(c => c[0] === 'open').length;
  await bridge.close(); await bridge.close();
  assert.equal(calls.filter(c => c[0] === 'close' && c[1] === sessionId).length, 1);
  assert.equal(timers.size, 0); groups++;

  let resolveOpen; nextOpen = () => new Promise(resolve => { resolveOpen = resolve; });
  const lateBridge = new SmbRangeBridge(); const opening = lateBridge.start(server, '/Movies/A.mkv'); await tick();
  const serversBefore = sockets.length; await lateBridge.close();
  resolveOpen({ sessionId: 101, size: fileSize, modifiedTime: 0 });
  await assert.rejects(opening, /关闭/); assert.equal(sockets.length, serversBefore);
  assert.equal(calls.filter(c => c[0] === 'close' && c[1] === 101).length, 1); groups++;

  const adapter = new SmbAdapter(); const info = await adapter.getPlaybackInfo(server, SmbNative.id('/Movies/A.mkv'), '', 0);
  assert.equal(Object.keys(info.headers).length, 0); assert.equal(typeof info.release, 'function');
  await info.release(); assert.throws(() => adapter.streamUrl(server, 'any'), /生命周期/); groups++;

  const closingBridge = new SmbRangeBridge(); const closingUrl = await closingBridge.start(server, '/Movies/A.mkv');
  let finishRead; nextRead = () => new Promise(resolve => { finishRead = resolve; });
  const current = connection(); sockets.at(-1).handlers.connect(current);
  current.request('GET ' + new URL(closingUrl).pathname + ' HTTP/1.1\r\nRange: bytes=0-7\r\n\r\n');
  await tick(); const closingId = calls.filter(c => c[0] === 'read').at(-1)[4];
  await closingBridge.close();
  assert.equal(calls.some(c => c[0] === 'cancel' && c[1] === closingId), true);
  finishRead(new ArrayBuffer(8)); await tick(); assert.equal(current.sent.length, 1); groups++;

  console.log('PASS SMB direct: ' + groups + ' groups; actual ETS methods with native/socket mocks. Native arm64 linkage and live-server/device acceptance are separate.');
})().catch(error => { console.error(error); process.exitCode = 1; });
