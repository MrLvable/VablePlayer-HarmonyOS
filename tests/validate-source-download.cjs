'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict'), crypto = require('node:crypto');
const { ts, projectFile } = require('./test-env.cjs');
const read = path => fs.readFileSync(projectFile('entry/src/main/ets/' + path), 'utf8');
const compile = source => { const result = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true }); assert.equal(result.diagnostics.length, 0); return result.outputText; };
const files = new Map(), prefs = new Map(), requests = [], operations = [], timers = new Map();
let nextFd = 0, timerId = 0, sdkFailure = false, sdkGate = null;
const opened = new Map();
const disk = {
  OpenMode: { READ_ONLY: 0 },
  accessSync: path => files.has(path) || path === '/app/files/downloads', mkdirSync() {},
  statSync: path => { operations.push(path); assert(files.has(path), 'missing ' + path); return { size: files.get(path).length }; },
  openSync: path => { operations.push(path); assert(files.has(path)); opened.set(++nextFd, path); return { fd: nextFd }; },
  readSync: (fd, buffer, options) => { const bytes = files.get(opened.get(fd)).slice(0, options.length); new Uint8Array(buffer).set(bytes); return bytes.length; },
  closeSync() {},
  unlinkSync: path => { operations.push(path); files.delete(path); },
  renameSync: (from, to) => { operations.push(from, to); assert(files.has(from)); files.set(to, files.get(from)); files.delete(from); }
};
class Task { constructor() { this.handlers = new Map(); this.deleted = false; } on(name, callback) { this.handlers.set(name, callback); } delete() { this.deleted = true; } }
const request = { downloadFile: async (_context, options) => {
  const task = new Task(); requests.push({ ...options, task });
  if (sdkFailure) throw { code: 99, message: 'sensitive-url-must-not-be-shown' };
  if (sdkGate) await sdkGate.promise;
  return task;
} };
const storage = { get: async (key, fallback) => prefs.get(key) ?? fallback, set: async (key, value) => { prefs.set(key, value); } };
const modules = new Map();
function load(path) {
  if (modules.has(path)) return modules.get(path);
  const module = { exports: {} }; modules.set(path, module.exports);
  const sdk = name => {
    if (name === '@kit.BasicServicesKit') return { request };
    if (name === '@kit.CoreFileKit') return { fileIo: disk };
    if (name === './Store') return { Store: storage };
    if (name === '../Models') return load('common/Models.ets');
    if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd: () => {
      const hash = crypto.createHash('sha256'); return { updateSync: value => hash.update(value.data), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) };
    } } };
    if (name === '@kit.ArkTS') return { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } };
    throw Error(name);
  };
  vm.runInNewContext(compile(read(path)), { module, exports: module.exports, require: sdk, setTimeout: fn => { timers.set(++timerId, fn); return timerId; }, clearTimeout: id => timers.delete(id), ArrayBuffer, Uint8Array });
  return module.exports;
}
const { DownloadManager: Manager, DownloadRecord: Record, DownloadState: State } = load('common/DownloadManager.ets');
const M = load('common/Models.ets');
const Identity = load('common/services/SourceIdentity.ets').SourceIdentity;
const Leases = load('common/SourcePlaybackLeases.ets').SourcePlaybackLeases;
const Policy = load('common/SourcePlaybackPolicy.ets').SourcePlaybackPolicy;
const ctx = { filesDir: '/app/files' }, turn = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function record(id) { return Object.assign(new Record(), { itemId: id, title: 'Title', subtitle: 'Episode', url: 'https://cdn.invalid/file.mkv?signature=runtime-secret', authToken: 'must-not-persist', headers: { Referer: 'https://upstream.invalid/', 'X-Only-Provider': 'runtime-header' } }); }
const mediaBytes = () => { const bytes = new Uint8Array(65536); bytes.set([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70]); return bytes; };
function complete(taskRequest) { files.set(taskRequest.filePath, mediaBytes()); taskRequest.task.handlers.get('complete')(); }
const index = read('pages/Index.ets');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(index); assert(match, name);
  const begin = index.indexOf('{', match.index); let depth = 1, end = begin + 1;
  for (; depth && end < index.length; end++) { if (index[end] === '{') depth++; else if (index[end] === '}') depth--; }
  return index.slice(match.index, end).replace(/^  private /, '  ');
}
let playback, negotiationGate = null; const toasts = [], negotiations = [];
const context = {
  exports: {}, DownloadRecord: Record, DownloadState: State, DownloadManager: Manager,
  SourceIdentity: Identity, SourcePlaybackLeases: Leases, SourcePlaybackPolicy: Policy,
  getContext: () => ctx, promptAction: { showToast: value => toasts.push(value.message) }, Push: { notifyDownloadDone() {} },
  MediaServices: { getItemDetail: async () => ({ sources: [] }), getPlaybackInfo: async (server, id) => { negotiations.push({ server, id }); if (negotiationGate) await negotiationGate.promise; return playback; },
    directStreamUrl: () => { throw Error('synchronous direct URL is forbidden'); }, streamHeaders: () => ({ 'Provider-Default': 'fallback' }) }
};
vm.runInNewContext(compile(`class Entry { current=null;detail=null;detailItem=null;downloads=[];homeScrollMounted=true;pushEnabled=false;${method('downloadCurrent')}\n${method('startDownload')} } exports.Entry=Entry;`), context);
const Entry = context.exports.Entry;
function fixture() {
  toasts.length = 0; requests.length = 0; negotiations.length = 0; sdkGate = null; negotiationGate = null; sdkFailure = false;
  playback = Object.assign(new M.PlaybackInfo(), { url: 'https://cdn.invalid/new.mkv?sig=private', headers: {} });
  const entry = new Entry(); entry.current = new M.ServerConfig('source', 'webdav', 'Source', 'nas.invalid', 443, 'viewer', 'must-not-leak', 'account', '', ''); entry.current.scheme = 'https';
  const item = Object.assign(new M.MediaItem(), { id: 'https://private.invalid/path/with?credential=runtime', name: 'Movie', type: 'Video' });
  entry.detailItem = item; return { entry, item };
}
(async () => {
  for (const id of ['../escape', '/absolute', 'folder/file', '..\\escape', 'a:b', 'a%2fb', '.', '..', '', 'x'.repeat(193)]) {
    const before = operations.length; assert.throws(() => Manager.localPath(ctx, id), /标识/); assert.equal(Manager.isDownloaded(ctx, id), false); assert.equal(Manager.remove(ctx, id), false); assert.equal(operations.length, before);
  }
  assert.equal(Manager.localPath(ctx, 'legacy-safe_1'), '/app/files/downloads/legacy-safe_1.mp4');
  const rec = record('download-one'); rec.headers = {}; await Manager.start(ctx, rec, () => {});
  assert.equal(Object.keys(requests.at(-1).header).length, 0, 'Explicit empty headers cannot fall back to old NAS token');
  const first = requests.at(-1); complete(first); await turn();
  let saved = JSON.parse(prefs.get('download_records'));
  assert.equal(saved[0].state, State.DONE); assert.equal(saved[0].filePath, Manager.readyPath(ctx, rec.itemId));
  for (const key of ['url', 'authToken', 'headers', 'error']) assert.equal(Object.hasOwn(saved[0], key), false);
  assert(!prefs.get('download_records').includes('runtime-secret')); assert(!prefs.get('download_records').includes('must-not-persist'));
  const withHeaders = record('download-two'); await Manager.start(ctx, withHeaders, () => {}); assert.equal(requests.at(-1).header['X-Only-Provider'], 'runtime-header'); complete(requests.at(-1));
  await turn(); assert(!prefs.get('download_records').includes('runtime-header')); Manager.remove(ctx, 'download-one'); await turn(); assert(!prefs.get('download_records').includes('must-not-persist'));
  files.set(Manager.readyPath(ctx, 'legacy-id'), mediaBytes());
  prefs.set('download_records', JSON.stringify([{ itemId: 'legacy-id', title: 'Old', subtitle: 'Old episode', filePath: '/arbitrary/ignored', state: 2, url: 'https://private.invalid/?token=old-secret', authToken: 'old-secret', headers: { Authorization: 'old-secret' } }, { itemId: '../escape', title: 'Bad' }]));
  const restored = await Manager.restore(ctx); assert.equal(restored.length, 1); assert.equal(restored[0].itemId, 'legacy-id'); assert.equal(restored[0].url, ''); assert.equal(restored[0].authToken, ''); assert.equal(restored[0].headers, null); assert.equal(restored[0].filePath, '/app/files/downloads/legacy-id.mp4.ready');
  assert(!prefs.get('download_records').includes('old-secret')); assert(!prefs.get('download_records').includes('arbitrary'));

  let f = fixture(); sdkGate = deferred(); f.entry.downloadCurrent(); await turn(); assert.equal(requests.length, 1); assert.equal(toasts.length, 0, 'No success toast before the system task starts');
  sdkGate.resolve(); await turn(); assert(toasts.includes('已加入下载')); assert.equal(Object.keys(requests[0].header).length, 0);
  const oneId = f.entry.downloads[0].itemId; assert(/^source-[a-f0-9]{64}$/.test(oneId)); assert(!oneId.includes('private'));
  requests[0].task.handlers.get('fail')(1);
  const scopedIds = [oneId];
  for (const mutate of [s => { s.userId = 'another-account'; }, s => { s.rootPath = '/other-directory'; }]) {
    f = fixture(); mutate(f.entry.current); await f.entry.startDownload(f.item); scopedIds.push(f.entry.downloads[0].itemId); requests[0].task.handlers.get('fail')(1);
  }
  assert.equal(new Set(scopedIds).size, 3, 'Same remote item ID in different account/root scopes cannot collide');
  for (const mode of ['hls', 'live', 'fd', 'session', 'unsupported']) {
    f = fixture(); let closed = 0;
    if (mode === 'hls') playback.isHls = true;
    if (mode === 'live') playback.isLive = true;
    if (mode === 'fd') playback.url = 'fd://99';
    if (mode === 'session') playback.release = async () => { closed++; };
    if (mode === 'unsupported') playback.url = 'smb://raw/path';
    await f.entry.startDownload(f.item); assert.equal(requests.length, 0, mode); assert(!toasts.includes('已加入下载'), mode); assert.equal(closed, mode === 'session' ? 1 : 0);
  }
  for (const leave of ['account', 'unmount']) {
    f = fixture(); let staleClosed = 0; playback.release = async () => { staleClosed++; }; negotiationGate = deferred();
    const waiting = f.entry.startDownload(f.item); await turn();
    if (leave === 'account') f.entry.current = null; else f.entry.homeScrollMounted = false;
    negotiationGate.resolve(); await waiting; assert.equal(staleClosed, 1, leave); assert.equal(requests.length, 0, leave);
  }
  f = fixture(); sdkFailure = true; await f.entry.startDownload(f.item); assert(!toasts.includes('已加入下载')); assert(toasts.some(value => value.includes('创建失败'))); assert(!toasts.join(' ').includes('sensitive-url'));
  assert.equal(timers.size, 0);
  assert(operations.every(path => path.startsWith('/app/files/downloads/')), 'All file operations remain in the download directory');
  console.log('PASS: real DownloadManager explicit/empty negotiated headers, opaque account/root-scoped IDs, safe legacy path compatibility, traversal rejection, SDK-start-before-toast, unsupported live/HLS/fd/session refusal with exact-session cleanup, stale negotiation cleanup, no fake success on SDK failure, completed/restore/forget snapshots exclude URL/token/header/error secrets. Actual Index methods and product modules with memory SDK/filesystem/preferences; no device/network/build.');
})().catch(error => { console.error(error); process.exitCode = 1; });
