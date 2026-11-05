'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const read = path => fs.readFileSync(projectFile('entry/src/main/ets/' + path), 'utf8');
const compile = source => {
  const result = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal(result.diagnostics.length, 0); return result.outputText;
};
function load(path, extra = {}) {
  const module = { exports: {} };
  vm.runInNewContext(compile(read(path)), { module, exports: module.exports, ...extra });
  return module.exports;
}
const timers = new Map(); let timerId = 0;
const Leases = load('common/SourcePlaybackLeases.ets', {
  setTimeout: (fn, ms) => { assert.equal(ms, 60000); timers.set(++timerId, fn); return timerId; },
  clearTimeout: id => timers.delete(id)
}).SourcePlaybackLeases;
const Policy = load('common/SourcePlaybackPolicy.ets').SourcePlaybackPolicy;
const M = load('common/Models.ets');
const pageSource = read('pages/PlayerPage.ets');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(pageSource); assert(match, name);
  const begin = pageSource.indexOf('{', match.index); let depth = 1, end = begin + 1;
  for (; depth && end < pageSource.length; end++) { if (pageSource[end] === '{') depth++; else if (pageSource[end] === '}') depth--; }
  return pageSource.slice(match.index, end).replace(/^  private /, '  ');
}
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const turn = () => new Promise(resolve => setImmediate(resolve));
let detail, info, historyCalls = 0, directCalls = 0, subtitleError = false;
const service = {
  getItemDetail: async () => detail,
  getPlaybackInfo: async () => info,
  directStreamUrl: server => { directCalls++; if (server.kind !== 'emby' && server.kind !== 'jellyfin') throw Error('sync streaming forbidden'); return 'https://media.invalid/stream?Static=true'; },
  streamHeaders: () => ({ 'Provider-Default': 'only-provider' }),
  subtitleUrl: () => { if (subtitleError) throw Error('no subtitle URL'); return '/external'; }
};
const Navigation = load('common/PlaybackNavigation.ets', { require: name => {
  if (name === './Models') return M;
  if (name === './services/MediaServices') return { MediaServices: service };
  if (name === './ProgressRepository') return { ProgressRepository: { loadForAccount: async () => { historyCalls++; return []; } } };
  if (name === './SourcePlaybackLeases') return { SourcePlaybackLeases: Leases };
  if (name === './SourcePlaybackPolicy') return { SourcePlaybackPolicy: Policy };
  throw Error(name);
} }).PlaybackNavigation;
function targetFixture(kind = 'smb') {
  const server = new M.ServerConfig('s', kind, kind, 'media.invalid', 443, '', 'legacy-secret', '', '', '');
  const item = new M.MediaItem(); item.id = 'one'; item.type = 'Video'; item.name = 'one';
  const source = new M.MediaSource(); source.id = 'version';
  detail = new M.ItemDetail(); detail.item = item; detail.sources = [source];
  info = new M.PlaybackInfo(); info.url = 'https://media.invalid/signed?sig=unchanged'; info.headers = {};
  return { server, item, source };
}
const events = []; let gate, resolveTarget, routeParams = {}, allowAiSource = true;
class ProxyMock {
  async start() { events.push('legacy-proxy'); return 'http://127.0.0.1/range'; }
  async close() { events.push('proxy-close'); }
}
const context = {
  exports: {}, SourcePlaybackLeases: Leases, SourcePlaybackPolicy: Policy, RangeStreamProxy: ProxyMock,
  PlaybackPreferences:{current:()=>({autoNext:true,doubleTapPause:true,ratio:'默认',subtitleScale:1})},
  PlaybackNavigation: { resolve: async () => resolveTarget.promise },
  hilog: { info() {}, warn() {} }, fs: { closeSync: () => events.push('fd-close') },
  promptAction: { showToast() {} }, MediaItem: M.MediaItem,
  media: { SeekMode: { SEEK_PREV_SYNC: 1 }, VideoScaleType: {} }, audio: { InterruptMode: {} },
  MpvAdapter: class {}, ProgressRepository: { upsert: async () => events.push('saved') },
  NativeAudioExtractor: { supportsSource: (url, isHls) => { events.push(['ai-source', url, isHls]); return allowAiSource; }, sourceError: () => 'AI source not supported' },
  router: { back: () => events.push('back'), getParams: () => routeParams },
  setTimeout, clearTimeout, console,
  MediaServices: { reportPlaybackState: async (...args) => events.push(['report', ...args]), imageUrl: () => '' },
};
const methods = ['currentPlayer', 'closePlayback', 'releaseAll', 'playbackHeaders', 'doSetupMpv',
  'navigatePlayback', 'requestSeek', 'canInteractWithTimeline', 'saveLocalProgress', 'saveNow',
  'ensurePlaybackQueue', 'handlePlaybackCompleted', 'startPreparedPlayback', 'reportProviderState', 'aboutToAppear', 'aiPlaybackInput'];
vm.runInNewContext(compile(`class Page {
  panelMounted=true; playbackGen=1; navigationGen=1; pendingRelease=null; playbackLeaseId='';
  player=null; mpvSurfaceAdapter=null; rangeDataSource=null; fallbackPlayback=null; streamProxy=null;
  fdReadOnly=null; session=null; pipCtl=null; activeDataDescriptor=null; panelServer=null;
  isLiveStream=false; isPlaying=true; playPos=12000; duration=60000; serviceKind='iptv';
  initialHeadersProvided=true; initialStreamHeaders={}; authToken='must-not-leak';
  videoUrl='https://media.invalid/stream'; streamRetryCount=0; itemId='one'; title='one'; reqSeriesId='';
  reqServerId='s'; reqUserId='u'; reqItemType='Video'; subtitle=''; reqImageTag='';
  reqSeason=0; reqEpisode=0; episodes=[]; desiredResumeMs=12000; resumeSeeked=false; pendingSelectedSourceId='';
  resolvingNavigation=false; switchingPlayback=false; errMsg=''; completionHandledGen=-1;
  locked=false; barOpacity=1; seekPending=false; lastSeekTarget=-1; lastSeekAt=0;
  subtitles=[]; curSubtitle=-1; sourceRouteError=false; initialHeadersProvided=true; externalSubtitleCues=[];externalSubtitleImportGen=0;externalSubtitleName='';
  stopAiSubtitles(){} logStreamStats(){} stopTimer(){} stopWatchdog(){} saveNow(){}
  rememberEpisodeProgress(){} closeSidePanel(){} async navigationServer(){return {id:'s',kind:'iptv'}}
  applyPlaybackTarget(target){events.push('applied');this.videoUrl=target.url;this.useMpvEngine=true;}
  async createMpvSurface(){events.push('surface')} async setupPlayer(){events.push('setup')}
  wirePlayerEvents(){} setupSession(){} suspendAiForSeek(){} resumeAiAfterSeek(){}
  async initializePreparedTracks(){} buildInfo(){return ''} autoOrient(){} playCurrent(){events.push('play')}
  async handlePlaybackFailure(){events.push('live-reconnect')} showBarTemporarily(){}
  setOrientation(){} setPlayerStatusBarVisible(){} scheduleHideBar(){} loadPanelServer(){}
  getUIContext(){return {getHostContext:()=>({cacheDir:'/cache'})}}
  ${methods.map(method).join('\n')}
} exports.Page=Page;`), Object.assign(context, { events }));
const Page = context.exports.Page;
function pageWithLease(release) {
  const page = new Page(); page.playbackLeaseId = Leases.register(release); assert(Leases.claim(page.playbackLeaseId)); return page;
}
(async () => {
  assert.equal(Leases.register(null), ''); assert.equal(Leases.claim('missing'), false);
  let count = 0; gate = deferred();
  const id = Leases.register(async () => { count++; await gate.promise; });
  assert(Leases.claim(id)); assert(!Leases.claim(id)); assert.equal(timers.size, 0);
  const closing = Leases.release(id); assert.equal(closing, Leases.release(id)); await turn(); assert.equal(count, 1);
  gate.resolve(); await closing; await Leases.release(id); assert.equal(count, 1);
  const expired = Leases.register(async () => { count++; });
  const expire = [...timers.values()][0]; expire(); await turn(); assert(!Leases.claim(expired)); assert.equal(count, 2);
  const failed = Leases.register(async () => { count++; throw Error('provider failed'); });
  await assert.rejects(Leases.release(failed)); await Leases.release(failed); assert.equal(count, 3);

  for (const kind of ['fnos', 'fnos-native', 'emby', 'jellyfin', 'plex', 'webdav', 'clouddrive', 'guangya', 'baidu', 'smb', 'iptv', 'custom', 'local']) {
    assert(Policy.useMpv(kind, 'https://media.invalid/a.mkv?sig=1')); assert(Policy.useMpv(kind, 'fd://28'));
    assert.equal(Policy.useMpv(kind, '/data/storage/downloads/old-video.mkv'), false);
    assert.equal(Object.keys(Policy.headers(kind, {}, 'secret')).length, 0);
    assert.equal(Object.keys(Policy.headers(kind, null, 'secret')).length, 0);
    assert.equal(Object.keys(Policy.headers(kind, undefined, 'secret')).length, kind === 'fnos' ? 2 : 0);
  }
  for (const url of ['', 'smb://server/share/a', 'file://media/local', 'ftp://server/a', 'fd://-1', 'fd://abc', 'javascript:bad']) assert.throws(() => Policy.useMpv('custom', url));
  const explicit = { Authorization: 'provider' }; const copied = Policy.headers('plex', explicit, 'legacy'); copied.Authorization = 'changed'; assert.equal(explicit.Authorization, 'provider');

  events.length = 0;
  const initialId = Leases.register(async () => events.push('initial-close'));
  routeParams = { url: 'fd://91', serviceKind: 'local', streamHeaders: {}, playbackLeaseId: initialId, itemType: 'Video', token: 'must-not-leak' };
  let initial = new Page(); initial.aboutToAppear(); await turn();
  assert.equal(initial.playbackLeaseId, initialId); assert(!Leases.claim(initialId)); assert(initial.useMpvEngine);
  initial.player = {}; initial.duration = 60000;
  allowAiSource = false;
  for (const url of ['smb://media.invalid/share/source.mkv', 'file://media/local']) {
    initial.videoUrl = url; assert.throws(() => initial.aiPlaybackInput('auto'), /AI source not supported/);
  }
  allowAiSource = true;
  for (const url of ['https://media.invalid/source.mkv', 'http://media.invalid/source.mkv', 'fd://91', '/data/storage/download.mkv', 'http://127.0.0.1/source.mkv', 'http://[::1]:8080/source.mkv']) {
    initial.videoUrl = url; assert.equal(Object.keys(initial.aiPlaybackInput('auto').headers).length, 0);
    assert(events.some(event => Array.isArray(event) && event[0] === 'ai-source' && event[1] === url));
  }
  allowAiSource = false; initial.videoUrl='https://media.invalid/vod.m3u8'; initial.activeIsHls=true;
  initial.externalSubtitleCues=[{id:'file',startMs:1000,endMs:2000,text:'external'}];
  assert.equal(initial.aiPlaybackInput('auto').timedCues[0].text,'external','External timed text bypasses audio/source extraction capability gate');
  initial.externalSubtitleCues=[];initial.activeIsHls=false;allowAiSource=true;
  initial.player = null;
  const duplicate = new Page(); duplicate.aboutToAppear(); await turn(); assert(duplicate.sourceRouteError); assert(!events.includes('initial-close'), 'A rejected duplicate claim cannot close the actual owner');
  initial.releaseAll('exit'); await initial.pendingRelease; assert(events.includes('initial-close'));
  events.length = 0; routeParams = { url: 'https://media.invalid/stream', serviceKind: 'iptv', streamHeaders: {}, playbackLeaseId: 'expired', itemType: 'Channel' };
  initial = new Page(); initial.aboutToAppear(); await turn(); assert(initial.sourceRouteError); assert(!events.includes('surface'));
  const unsupportedId = Leases.register(async () => events.push('unsupported-close'));
  routeParams = { url: 'smb://raw/path', serviceKind: 'smb', playbackLeaseId: unsupportedId };
  initial = new Page(); initial.aboutToAppear(); await turn(); assert(initial.sourceRouteError); assert(events.includes('unsupported-close'));
  routeParams = { url: '/data/storage/legacy-download.mp4', serviceKind: 'fnos' };
  initial = new Page(); initial.aboutToAppear(); assert.equal(initial.useMpvEngine, false);
  routeParams = { url: 'https://media.invalid/vod.m3u8', serviceKind: 'iptv', itemType: 'Channel', isLive: false, startTicks: 300000000 };
  initial = new Page(); initial.aboutToAppear(); assert.equal(initial.isLiveStream, false, 'Explicit VOD wins over a legacy Channel hint'); assert.equal(initial.desiredResumeMs, 30000);

  let f = targetFixture(); let target = await Navigation.resolve(f.server, f.item, '', 12000, false);
  assert.equal(directCalls, 0); assert.equal(target.url, info.url); assert.equal(Object.keys(target.headers).length, 0); assert(target.useMpv);
  info.headers = null; target = await Navigation.resolve(f.server, f.item, '', 0, false); assert.equal(target.headers['Provider-Default'], 'only-provider');
  for (const failure of ['selection', 'protocol', 'subtitle']) {
    f = targetFixture(); let released = 0; info.release = async () => { released++; };
    if (failure === 'selection') info.mediaSourceId = 'other';
    if (failure === 'protocol') info.url = 'smb://not-negotiated';
    if (failure === 'subtitle') { const sub = new M.MediaStream(); sub.type = 'Subtitle'; sub.isExternal = true; f.source.streams = [sub]; subtitleError = true; }
    await assert.rejects(Navigation.resolve(f.server, f.item, f.source.id, 0, false)); assert.equal(released, 1, failure);
    subtitleError = false;
  }
  f = targetFixture('iptv'); f.item.type = 'Channel'; info.isLive = true; const beforeHistory = historyCalls;
  target = await Navigation.resolve(f.server, f.item, '', -1, false); assert(target.isLive); assert.equal(target.positionMs, 0); assert.equal(historyCalls, beforeHistory);
  info.isLive = false; target = await Navigation.resolve(f.server, f.item, '', 0, false); assert.equal(target.isLive, false, 'Negotiated VOD stays seekable');
  f = targetFixture('emby'); info.url = service.directStreamUrl(f.server); target = await Navigation.resolve(f.server, f.item, f.source.id, 0, true); assert(target.url.endsWith('&MediaSourceId=version'));
  f = targetFixture('fnos-native'); await assert.rejects(Navigation.resolve(f.server, f.item, f.source.id, 0, true), /当前飞牛/);

  events.length = 0; gate = deferred();
  let p = pageWithLease(async () => { events.push('provider-close'); });
  p.player = { release: async () => { events.push('engine-release'); await gate.promise; events.push('engine-joined'); } };
  p.streamProxy = new ProxyMock(); p.fdReadOnly = {};
  p.releaseAll('exit'); await turn(); assert.deepEqual(events.filter(x => typeof x === 'string'), ['engine-release']);
  gate.resolve(); await p.pendingRelease; assert(events.indexOf('engine-joined') < events.indexOf('proxy-close')); assert(events.indexOf('engine-joined') < events.indexOf('provider-close')); assert(events.indexOf('engine-joined') < events.indexOf('fd-close'));
  events.length = 0; gate = deferred();
  p = pageWithLease(async () => { events.push('provider-close'); }); p.player = { release: async () => { await gate.promise; events.push('joined'); } };
  p.releaseAll('retry', true); const retryGeneration = p.playbackGen; p.releaseAll('leave-during-retry'); assert(p.playbackGen > retryGeneration);
  await turn(); assert(!events.includes('provider-close')); gate.resolve(); await p.pendingRelease; assert.deepEqual(events.filter(x => typeof x === 'string'), ['joined', 'provider-close']);
  events.length = 0; p = pageWithLease(async () => { events.push('provider-close'); }); p.player = { release: async () => { events.push('joined'); } };
  p.releaseAll('retry', true); await p.pendingRelease; assert(!events.includes('provider-close')); assert(p.playbackLeaseId); p.releaseAll('exit'); await p.pendingRelease; assert(events.includes('provider-close'));
  events.length = 0; p = pageWithLease(async () => { events.push('provider-close'); }); const retainedId = p.playbackLeaseId;
  const failedEngine = { release: async () => { throw Error('join not confirmed'); } }; p.player = failedEngine;
  p.releaseAll('exit'); await assert.rejects(p.pendingRelease); await turn(); assert.equal(p.player, failedEngine); assert.equal(p.playbackLeaseId, retainedId); assert(!events.includes('provider-close'));
  failedEngine.release = async () => {}; p.releaseAll('second-exit'); await p.pendingRelease;

  for (const kind of ['iptv', 'smb', 'local', 'plex', 'fnos-native']) {
    events.length = 0; p = new Page(); p.serviceKind = kind; p.streamRetryCount = 1;
    p.mpvSurfaceAdapter = { isReleased: false, open: async (_url, headers) => { assert.equal(Object.keys(headers).length, 0); events.push('opened'); } };
    await p.doSetupMpv(1); assert(events.includes('opened')); assert(!events.includes('legacy-proxy'), kind);
  }
  events.length = 0; p = new Page(); p.serviceKind = 'fnos'; p.videoUrl = 'http://nas/v/api/v1/media/range/item'; p.streamRetryCount = 1;
  p.mpvSurfaceAdapter = { isReleased: false, open: async () => {} }; await p.doSetupMpv(1); assert(events.includes('legacy-proxy'));

  for (const stale of ['leave', 'replace', 'old-engine-failure']) {
    events.length = 0; resolveTarget = deferred(); p = new Page();
    const lease = Leases.register(async () => events.push('unused-close'));
    const switching = p.navigatePlayback({ id: 'two' }, '', 0, false); await turn();
    if (stale === 'leave') { p.panelMounted = false; p.navigationGen++; }
    if (stale === 'replace') p.navigationGen++;
    if (stale === 'old-engine-failure') p.player = { release: async () => { throw Error('join failed'); } };
    resolveTarget.resolve({ leaseId: lease, url: 'fd://7', sourceId: '', headers: {}, useMpv: true });
    await switching; assert(events.includes('unused-close'), stale); assert(!events.includes('applied'), stale);
  }
  events.length = 0; resolveTarget = deferred(); p = new Page();
  const transferred = Leases.register(async () => events.push('transferred-close'));
  const switching = p.navigatePlayback({ id: 'two' }, '', 0, false); await turn();
  resolveTarget.resolve({ leaseId: transferred, url: 'fd://7', sourceId: '', headers: {}, useMpv: true }); await switching;
  assert(events.includes('applied')); assert.equal(p.playbackLeaseId, transferred); assert(!Leases.claim(transferred)); assert(!events.includes('transferred-close'));
  p.releaseAll('exit'); await p.pendingRelease; assert(events.includes('transferred-close'));

  events.length = 0; p = new Page(); p.isLiveStream = true; p.player = { seek: () => { throw Error('live seek'); }, duration: 12345 };
  assert.equal(p.requestSeek(5000), false); assert.equal(p.canInteractWithTimeline(), false); await p.saveLocalProgress(); p.saveNow(); assert(!events.includes('saved'));
  await p.handlePlaybackCompleted(1, p.player); assert(events.includes('live-reconnect')); assert(!events.includes('back'));
  p.episodes = [{ id: 'one', type: 'Channel' }, { id: 'two', type: 'Channel' }]; assert.equal((await p.ensurePlaybackQueue()).length, 2);
  await p.startPreparedPlayback(1, p.player); assert.equal(p.duration, 0); assert.equal(p.desiredResumeMs, 0); assert(events.includes('play'));
  events.length = 0; p = new Page(); p.panelServer = { id: 's', kind: 'plex' }; p.reportProviderState('paused'); await turn();
  let report = events.find(x => Array.isArray(x)); assert.equal(report[2], 'one'); assert.equal(report[3], 120000000); assert.equal(report[4], 600000000); assert.equal(report[5], 'paused');
  p.isLiveStream = true; p.reportProviderState('playing'); await turn(); report = events.filter(x => Array.isArray(x)).at(-1); assert.equal(report[3], 0); assert.equal(report[4], 0);
  assert.equal(timers.size, 0, 'Every negotiated but unconsumed test lease is released');
  console.log('PASS: 13-provider engine/header policy; actual lease expiry/claim/idempotency; negotiated URLs, empty/default headers, selection/protocol/subtitle rollback, live history guard; real Player native-join-before-provider/fd/proxy close, retry ownership and terminal upgrade, failed-join retention, legacy-only proxy, stale/failed navigation cleanup and ownership transfer, live seek/resume/EOF/queue guards, explicit Plex playback state. No network, device or build calls.');
})().catch(error => { console.error(error); process.exitCode = 1; });
