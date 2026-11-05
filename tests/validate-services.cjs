const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { ts, projectFile } = require('./test-env.cjs');
const root = projectFile('entry/src/main/ets/common');
const directAdapterCalls = [];
const modules = new Map(), requests = [], responses = [], nativeLogins = [];
let nativeSessions = 0, nativeCloses = 0, nativeFailure = false;
const nativeResolves = [];
class FnosPlayback {
  constructor() { nativeSessions++; }
  static async login(base, username, password) { nativeLogins.push({ base, username }); return 'native-token'; }
  async resolve(url, token, id) { nativeResolves.push({ url, token, id }); if (nativeFailure) throw Error('native negotiation failed'); return { url: 'https://native.invalid/session.m3u8', isHls: true }; }
  async close() { nativeCloses++; }
}
// These adapters require native/cloud/OAuth SDKs and have dedicated suites. Keep
// the actual registry/facade and all providers under test below, isolate only
// these unrelated static imports rather than replacing the tested legacy path.
const isolated = { SmbAdapter: 'smb', CloudDriveAdapter: 'clouddrive', BaiduAdapter: 'baidu',
  GuangyaAdapter: 'guangya', LocalAdapter: 'local', CustomAdapter: 'custom' };
class Encoder { encodeInto(value) { return new TextEncoder().encode(value); } }
class Decoder { constructor(encoding, options) { this.value = new TextDecoder(encoding, options); } decodeWithStream(value) { return this.value.decode(value); } }
class Request { constructor(url, method, headers, body) { this.url = url; this.method = method; this.headers = headers; this.body = body; } }
function load(file) {
  file = path.resolve(file);
  if (path.basename(file) === 'FnosPlayback.ets') return { FnosPlayback };
  if (path.basename(file) === 'Dbg.ets') return { Dbg: { setApi() {}, setImage() {} } };
  if (path.basename(file) === 'Store.ets') return { Store: { refreshServerCredentials: async () => true } };
  for (const [name, kind] of Object.entries(isolated)) {
    if (path.basename(file) === name + '.ets') return { [name]: class {
      constructor() { this.kind = kind; this.catalog = { getViews: async server => { directAdapterCalls.push([kind, 'views', server.connectionMode]); throw Error('direct backend unavailable'); } }; }
      async login(server) { directAdapterCalls.push([kind, 'login', server.connectionMode]); throw Error('direct backend unavailable'); }
      async getPlaybackInfo(server) { directAdapterCalls.push([kind, 'playback', server.connectionMode]); throw Error('direct backend unavailable'); }
    } };
  }
  for (const name of ['BaiduAuthorization', 'GuangyaAuthorization']) {
    if (path.basename(file) === name + '.ets') return { [name]: class {} };
  }
  if (path.basename(file) === 'LocalSourceState.ets') return { LocalSourceState: { getResume: async () => [], reportProgress: async () => {} } };
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((result.diagnostics || []).length, 0, file);
  const requireForModule = name => {
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { warn() {} } };
    if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd: () => {
      const hash = crypto.createHash('sha256'); return { updateSync: value => hash.update(value.data), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) };
    } } };
    if (name === '@kit.ArkTS') return { url: { URL }, util: { TextEncoder: Encoder, TextDecoder: Decoder,
      Base64Helper: class { encodeToStringSync(value) { return Buffer.from(value).toString('base64'); } } } };
    if (name === '@kit.RemoteCommunicationKit') return { rcp: { Request, createSession: () => ({
      cancel() {}, close() {}, async fetch(request) {
        requests.push({ url: request.url, options: { method: request.method, header: request.headers, extraData: request.body } });
        assert(responses.length > 0, 'unexpected RCP call');
        const response = responses.shift(), value = response && response.raw !== undefined ? response.raw : JSON.stringify(response);
        return { statusCode: response && response.code !== undefined ? response.code : 200, headers: {}, body: new TextEncoder().encode(value).buffer };
      }
    }) } };
    if (name === '@kit.NetworkKit') return { http: {
      RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE' }, HttpDataType: { STRING: 'STRING' },
      createHttp: () => ({ destroy() {}, request: async (url, options) => {
        requests.push({ url, options });
        assert(responses.length > 0, 'unexpected HTTP call');
        const response = responses.shift();
        return { responseCode: response && response.code !== undefined ? response.code : 200,
          result: response && response.raw !== undefined ? response.raw : JSON.stringify(response) };
      } })
    } };
    return load(path.resolve(path.dirname(file), name + '.ets'));
  };
  vm.runInNewContext(result.outputText, { module, exports: module.exports, require: requireForModule, setTimeout, clearTimeout }, { filename: file });
  return module.exports;
}
(async () => {
  const { ServerConfig } = load(path.join(root, 'Models.ets'));
  const { MediaServices: services } = load(path.join(root, 'services/MediaServices.ets'));
  const { MediaServiceRegistry: registry } = load(path.join(root, 'services/MediaServiceRegistry.ets'));
  const server = kind => new ServerConfig(kind, kind, kind, 'example.invalid', 8005, 'user', 'compat-token', 'user-id', '', '');
  const fnos = server('fnos'), emby = server('emby'), jellyfin = server('jellyfin');
  assert(services.directStreamUrl(fnos, 'item').includes('/v/api/v1/media/range/item'));
  for (const value of [emby, jellyfin]) {
    assert(services.directStreamUrl(value, 'item').includes('/Videos/item/stream?Static=true'));
    assert(!services.directStreamUrl(value, 'item').includes('/v/api/'));
    assert.equal(services.createNativePlayback(value.kind), null);
    responses.push({ MediaSources: [{ Id: 'source', SupportsDirectPlay: true, DirectStreamUrl: '/Videos/item/stream?Static=true' }] });
    const info = await services.getPlaybackInfo(value, 'item', 'source', 0);
    assert(info.url.includes('/Videos/item/stream')); assert(requests.at(-1).url.includes('/Items/item/PlaybackInfo'));
    if (value.kind === 'jellyfin') {
      assert.match(services.streamHeaders(value).Authorization, /^MediaBrowser .*Token="compat-token"/);
      assert.equal(services.streamHeaders(value)['X-Emby-Token'], undefined);
    } else { assert.equal(services.streamHeaders(value)['X-Emby-Token'], 'compat-token'); }
  }
  const before = requests.length;
  assert((await services.getPlaybackInfo(fnos, 'item', 'source', 0)).url.includes('/v/api/v1/media/range/'));
  assert.equal(requests.length, before); assert.equal(nativeSessions, 0);
  responses.push({ AccessToken: 'compat-token', User: { Id: 'user-id' } });
  const logged = await services.login(fnos, 'not-saved');
  assert.equal(logged.nativeToken, 'native-token'); assert.equal(nativeLogins.length, 1);
  jellyfin.scheme = 'https'; jellyfin.basePath = '/jellyfin';
  responses.push({ AccessToken: 'compat-token', User: { Id: 'user-id' } }, { Items: [] });
  const jellyfinLogged = await services.login(jellyfin, 'not-saved'); assert.equal(nativeLogins.length, 1);
  assert.equal(jellyfinLogged.baseUrl(), 'https://example.invalid:8005/jellyfin');
  assert.equal(requests.at(-1).url, 'https://example.invalid:8005/jellyfin/Users/user-id/Views');
  assert.match(requests.at(-1).options.header.Authorization, /Token="compat-token"/);
  assert.equal(responses.length, 0, 'Connection detection reads libraries with the new account session');
  responses.push({ AccessToken: 'compat-token', User: { Id: 'user-id' } },
    { code: 403, raw: 'fixture-private-upstream-error' });
  await assert.rejects(services.login(jellyfin, 'not-saved'), error => {
    assert.match(error.message, /权限.*HTTP 403/);
    assert(!error.message.includes('fixture-private-upstream-error')); return true;
  });
  assert.equal(responses.length, 0, 'Password acceptance cannot hide a failed library-access check');
  services.createNativePlayback('fnos'); assert.equal(nativeSessions, 1);
  assert(services.backdropUrl(fnos, 'item', 400, 'tag', '').includes('/Images/Backdrop?'));
  assert(services.backdropUrl(emby, 'item', 400, 'tag', '').includes('/Images/Backdrop/0?'));
  assert.throws(() => services.directStreamUrl(server('unknown'), 'item'));
  const native = server('fnos-native');
  await assert.rejects(services.getPlaybackInfo(native, 'item', 'source', 0), /原生播放凭据/);
  native.nativeToken = 'real-native-session';
  const nativeInfo = await services.getPlaybackInfo(native, 'item', 'source', 0);
  assert.equal(nativeInfo.url, 'https://native.invalid/session.m3u8'); assert(nativeInfo.isHls);
  assert.equal(Object.keys(nativeInfo.headers).length, 0); assert.equal(nativeInfo.mediaSourceId, 'source');
  assert.equal(nativeResolves.at(-1).token, 'real-native-session');
  await nativeInfo.release(); assert.equal(nativeCloses, 1, 'Close callback targets the original native session');
  nativeFailure = true; await assert.rejects(services.getPlaybackInfo(native, 'item', 'source', 0), /negotiation failed/);
  assert.equal(nativeCloses, 2, 'Failed native negotiation closes the exact provisional session'); nativeFailure = false;

  const plex = server('plex'); plex.scheme = 'https';
  responses.push({ MediaContainer: { Metadata: [{ ratingKey: 'movie', title: 'Movie', type: 'movie',
    Media: [{ id: 'part', Part: [{ key: '/library/parts/11/file.mkv', size: 4000 }] }] }] } });
  const plexInfo = await services.getPlaybackInfo(plex, 'movie', 'part', 0);
  assert.equal(plexInfo.url, 'https://example.invalid:8005/library/parts/11/file.mkv');
  assert.equal(plexInfo.headers['X-Plex-Token'], 'compat-token'); assert.equal(services.imageHeaders(plex)['X-Plex-Token'], 'compat-token');
  responses.push({ MediaContainer: { size: 0 } }); await services.reportPlaybackState(plex, 'movie', 350000000, 1250000000, 'paused');
  assert(requests.at(-1).url.includes('state=paused')); assert(requests.at(-1).url.includes('time=35000'));
  const reportRequests = requests.length; await services.reportPlaybackState(emby, 'movie', 350000000, 1250000000, 'playing');
  assert.equal(requests.length, reportRequests, 'Plex timeline is never synthesized for other providers');

  const iptv = server('iptv'); iptv.authMode = 'password'; iptv.sourceUrl = 'https://playlist.invalid/main.m3u';
  responses.push({ raw: '#EXTM3U\n#EXTINF:-1,Channel\nhttps://outside.invalid/live.m3u8\n' });
  const channels = await services.getItems(iptv, 'iptv:all', 0, 10, false);
  assert.equal(channels[0].name, 'Channel');
  const live = await services.getPlaybackInfo(iptv, channels[0].id, '', 0);
  assert.equal(live.url, 'https://outside.invalid/live.m3u8'); assert(live.isLive);
  assert.equal(Object.keys(live.headers).length, 0, 'External channel never inherits playlist credentials');

  const dav = server('webdav'); dav.scheme = 'https'; dav.rootPath = '/media'; dav.authMode = 'password'; dav.token = 'Basic ' + Buffer.from('viewer:only-webdav').toString('base64');
  responses.push({ code: 207, raw: '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/media/movie.mkv</d:href><d:propstat><d:prop><d:displayname>Movie</d:displayname><d:resourcetype/><d:getcontentlength>4000</d:getcontentlength><d:getcontenttype>video/mkv</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>' });
  const davInfo = await services.getPlaybackInfo(dav, 'dav:' + encodeURIComponent('/media/movie.mkv'), '', 0);
  assert.equal(davInfo.url, 'https://example.invalid:8005/media/movie.mkv'); assert.equal(davInfo.headers.Authorization, dav.token);
  assert.equal(requests.at(-1).options.method, 'PROPFIND');
  const rootEntry = '<d:response><d:href>/media/</d:href><d:propstat><d:prop><d:displayname>Media</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  const fileEntry = '<d:response><d:href>/media/movie.mkv</d:href><d:propstat><d:prop><d:displayname>Movie</d:displayname><d:resourcetype/><d:getcontentlength>4000</d:getcontentlength><d:getcontenttype>video/mkv</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  const multistatus = entries => ({ code: 207, raw: '<d:multistatus xmlns:d="DAV:">' + entries + '</d:multistatus>' });
  for (const kind of ['smb', 'custom']) {
    const aggregate = server(kind); aggregate.scheme = 'https'; aggregate.rootPath = '/media'; aggregate.authMode = 'password'; aggregate.connectionMode = 'aggregate'; aggregate.userId = '';
    const offset = requests.length; const oldDirectCalls = directAdapterCalls.length;
    assert.equal(registry.forServer(aggregate).kind, 'webdav');
    responses.push(multistatus(rootEntry)); await services.login(aggregate, 'only-aggregate-password');
    assert.equal(aggregate.kind, kind); assert.equal(aggregate.connectionMode, 'aggregate'); assert(aggregate.token.startsWith('Basic '));
    responses.push(multistatus(rootEntry)); assert.equal((await services.getViews(aggregate))[0].type, 'folders');
    responses.push(multistatus(rootEntry + fileEntry)); const files = await services.getItems(aggregate, 'dav:' + encodeURIComponent('/media/'), 0, 10, false);
    assert.equal(files[0].name, 'Movie');
    responses.push(multistatus(fileEntry)); const resolved = await services.getPlaybackInfo(aggregate, files[0].id, '', 0);
    assert.equal(resolved.url, 'https://example.invalid:8005/media/movie.mkv'); assert.equal(resolved.headers.Authorization, aggregate.token);
    assert.equal(services.streamHeaders(aggregate).Authorization, aggregate.token); assert.equal(services.directStreamUrl(aggregate, files[0].id), resolved.url);
    assert(requests.slice(offset).every(request => request.options.method === 'PROPFIND'));
    assert.equal(directAdapterCalls.length, oldDirectCalls, 'Aggregate never invokes the SMB/native/custom backend');
    const direct = server(kind); assert.equal(registry.forServer(direct).kind, kind); const count = requests.length;
    await assert.rejects(services.getViews(direct), /direct backend unavailable/);
    await assert.rejects(services.getPlaybackInfo(direct, 'item', '', 0), /direct backend unavailable/);
    assert.equal(requests.length, count, 'Direct failure never silently sends WebDAV requests');
  }
  for (const kind of ['clouddrive', 'baidu', 'guangya']) { const aggregate = server(kind); aggregate.connectionMode = 'aggregate'; assert.equal(registry.forServer(aggregate).kind, 'webdav'); assert.equal(aggregate.kind, kind); }
  const bad = server('smb'); bad.connectionMode = 'invented'; assert.throws(() => services.getViews(bad), /连接方式/);
  const disallowed = server('plex'); disallowed.connectionMode = 'aggregate'; assert.throws(() => registry.forServer(disallowed), /不支持聚合/);
  assert.equal(responses.length, 0);
  console.log('PASS: real registry/facade and legacy dispatch; exact-session FnOS cleanup; Plex Part/header/timeline; IPTV empty external headers; WebDAV PROPFIND; SMB/Custom aggregate real PROPFIND/login/list/playback with original source scope; cloud aggregate whitelist; direct errors do not fallback; invalid modes rejected. Unrelated direct native/cloud imports isolated; HTTP/RCP are SDK mocks. No real network/device calls.');
})().catch(error => { console.error(error); process.exitCode = 1; });
