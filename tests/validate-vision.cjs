'use strict';
// Execute the real non-UI Vision modules. Fake only platform storage, clock and provider I/O.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const root = projectFile('entry/src/main/ets/common');
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const tick = async () => { for (let i = 0; i < 50; i++) await Promise.resolve(); };
function fixture() {
  const modules = new Map(), saved = new Map(), timers = new Map(), calls = [], options = new Map(), remote = new Map(), progress = new Map(), episodes = new Map();
  let serial = 0, ignoreWrites = false, getOptionHook = null, lockHook = null;
  const option = id => Object.assign({ id, error: '', hidden: false, locked: false, aggregateEnabled: true }, options.get(id));
  const store = { get: async (key, fallback) => saved.has(key) ? saved.get(key) : fallback, set: async (key, value) => { if (!ignoreWrites) saved.set(key, value); } };
  function load(file) {
    file = path.resolve(file); const name = path.basename(file);
    if (name === 'Store.ets') return { Store: store };
    if (name === 'ServerOptions.ets') return { ServerOptions: {
      all: async () => [...options.keys()].map(option),
      get: async id => getOptionHook ? getOptionHook(id) : option(id),
      isLocked: async id => { calls.push(['lock', id]); return lockHook ? lockHook(id) : option(id).locked; }
    } };
    if (name === 'ProgressRepository.ets') return { ProgressRepository: { loadAll: async () => {
      calls.push(['progress-all']); const records = [];
      for (const [scope, value] of progress) {
        const separator = scope.indexOf(':'); const rows = typeof value === 'function' ? await value() : value;
        for (const row of rows) records.push(Object.assign({}, row, { serverId: scope.substring(0, separator), userId: scope.substring(separator + 1) }));
      }
      return records;
    } } };
    if (name === 'MediaServiceRegistry.ets') return { MediaServiceRegistry: { forServer: server => ({ catalog: {
      getResume: async (actual, limit) => { calls.push(['resume', actual.id, actual.userId, limit]); const value = remote.get(actual.id) || []; return typeof value === 'function' ? value(actual) : value; },
      getEpisodes: async (actual, series, season) => { calls.push(['episodes', actual.id, series, season]); const value = episodes.get(actual.id + ':' + series) || []; return typeof value === 'function' ? value() : value; },
      cancel: () => calls.push(['cancel', server.id])
    } }) } };
    if (name === 'MediaServices.ets') return { MediaServices: {
      imageUrl: (server, id) => 'https://images.invalid/' + server.id + '/' + id,
      imageHeaders: server => ({ Authorization: server.token })
    } };
    if (modules.has(file)) return modules.get(file).exports;
    const module = { exports: {} }; modules.set(file, module);
    const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.equal(result.diagnostics.length, 0, file);
    const requireModule = name => {
      if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => crypto.randomUUID(), TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } }, url: { URL } };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd: () => { const hash = crypto.createHash('sha256'); return { updateSync: blob => hash.update(blob.data), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) }; } } };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    };
    vm.runInNewContext(result.outputText, { module, exports: module.exports, require: requireModule, Date, URL, Uint8Array,
      setTimeout: (callback, delay) => { assert.equal(delay, 16, 'All UI publication is deferred to the next frame'); const id = ++serial; timers.set(id, callback); return id; },
      clearTimeout: id => timers.delete(id) }, { filename: file });
    return module.exports;
  }
  const { ServerConfig, MediaItem } = load(path.join(root, 'Models.ets'));
  const { VisionStore } = load(path.join(root, 'vision/VisionStore.ets'));
  const { VisionController } = load(path.join(root, 'vision/VisionController.ets'));
  const { VisionRow } = load(path.join(root, 'vision/VisionModels.ets'));
  const { SourceIdentity } = load(path.join(root, 'services/SourceIdentity.ets'));
  const server = (id = 'a', uid = 'user-a') => new ServerConfig(id, 'fnos', 'NAS ' + id, 'nas-' + id + '.invalid', 8005, 'u', 'fixture-token', uid);
  const item = (id = 'film', extra = {}) => Object.assign(new MediaItem(), { id, type: 'Movie', name: 'Film ' + id, runtimeTicks: 1000 * 10000, progressTicks: 100 * 10000, imageTag: 'actual-tag' }, extra);
  const record = (id, extra = {}) => Object.assign({ itemId: id, itemType: 'Movie', title: 'Local ' + id, episodeTitle: '', seriesId: '', imageTag: '', positionMs: 240, durationMs: 1000, seasonNumber: 0, episodeNumber: 0, completed: false, updatedAt: 10 }, extra);
  const frame = async () => { await tick(); const pending = [...timers.values()]; timers.clear(); pending.forEach(fn => fn()); await tick(); };
  const flush = async () => { for (let i = 0; i < 3; i++) await frame(); };
  return { VisionStore, VisionController, VisionRow, SourceIdentity, server, item, record, saved, options, calls, remote, progress, episodes, frame, flush,
    noWrite: value => { ignoreWrites = value; }, getOption: fn => { getOptionHook = fn; }, lock: fn => { lockHook = fn; }, option };
}
let groups = 0;
async function group(name, run) { await run(); groups++; console.log('PASS ' + name); }
(async () => {
  await group('wait-later is persistent, idempotent and isolated by account and endpoint', async () => {
    const f = fixture(), a = f.server(), b = f.server('a', 'different-user'), movie = f.item();
    await Promise.all([f.VisionStore.setWatchLater(a, movie, true), f.VisionStore.setWatchLater(a, movie, true)]);
    assert.equal((await f.VisionStore.load([a])).watchLater.length, 1);
    assert.equal((await f.VisionStore.load([b])).watchLater.length, 0);
    b.userId = a.userId; b.basePath = '/another'; assert.equal((await f.VisionStore.load([b])).watchLater.length, 0);
    assert.equal(await f.VisionStore.isWatchLater(a, movie.id), true);
    assert.equal(await f.VisionStore.toggleWatchLater(a, movie), false);
    assert.equal((await f.VisionStore.load([a])).watchLater.length, 0);
  });
  await group('saved snapshots never contain source credentials, movie paths or signed artwork', async () => {
    const f = fixture(), a = f.server(); a.password = 'private-pass'; a.nativeToken = 'private-native';
    const movie = f.item('opaque-id', { path: 'https://nas.invalid/movie?token=private', imageTag: 'https://image.invalid/a?token=private', backdropTag: 'https://user:private@image.invalid/a' });
    await f.VisionStore.setWatchLater(a, movie, true); const raw = f.saved.get('vision_library_v1');
    assert(!/private|fixture-token|nas-a\.invalid|nativeToken|password/.test(raw));
    const copy = (await f.VisionStore.load([a])).watchLater[0].item;
    assert.equal(copy.imageTag, ''); assert.equal(copy.backdropTag, ''); assert.equal(copy.path, ''); assert.equal(copy.id, 'opaque-id');
    assert.throws(() => f.VisionStore.snapshot(f.item('https://host.invalid/a?token=secret')), /不可安全保存/);
  });
  await group('playlist edits are real serialized writes and account-filtered entries', async () => {
    const f = fixture(), a = f.server(), b = f.server('a', 'other');
    const list = await f.VisionStore.createPlaylist(' Weekend ', a);
    const other = await f.VisionStore.createPlaylist('Other private list', b);
    await Promise.all([f.VisionStore.addToPlaylist(list, a, f.item('one')), f.VisionStore.addToPlaylist(list, a, f.item('one')), f.VisionStore.addToPlaylist(other, b, f.item('two'))]);
    await assert.rejects(f.VisionStore.addToPlaylist(list, b, f.item('wrong')), /当前账号/);
    let snapshot = await f.VisionStore.load([a]); assert.equal(snapshot.playlists[0].name, 'Weekend'); assert.equal(snapshot.playlists[0].entries.length, 1);
    await f.VisionStore.renamePlaylist(list, 'Renamed', a); await f.VisionStore.removeFromPlaylist(list, snapshot.playlists[0].entries[0].key, a);
    snapshot = await f.VisionStore.load([a]); assert.equal(snapshot.playlists[0].name, 'Renamed'); assert.equal(snapshot.playlists[0].entries.length, 0);
    assert.equal((await f.VisionStore.load([b])).playlists[0].entries.length, 1);
    await assert.rejects(f.VisionStore.renamePlaylist(list, 'Leaked rename', b), /当前账号/);
    await f.VisionStore.deletePlaylist(list, b); assert.equal((await f.VisionStore.load([a])).playlists.length, 1);
    await f.VisionStore.deletePlaylist(list, a); assert.equal((await f.VisionStore.load([a])).playlists.length, 0);
    await assert.rejects(f.VisionStore.createPlaylist('  ', a), /名称/);
  });
  await group('corrupt records and silent persistence failures are visible without overwriting history', async () => {
    const f = fixture(); f.saved.set('vision_library_v1', '{broken');
    await assert.rejects(f.VisionStore.setWatchLater(f.server(), f.item(), true), /原记录已保留/);
    assert.equal(f.saved.get('vision_library_v1'), '{broken'); f.saved.clear(); f.noWrite(true);
    await assert.rejects(f.VisionStore.setWatchLater(f.server(), f.item(), true), /未能完整保存/);
  });
  await group('legacy shared playlists migrate into separate owners while unknown empty names remain private', async () => {
    const f = fixture(), a = f.server(), b = f.server('b');
    await f.VisionStore.setWatchLater(a, f.item('one'), true); await f.VisionStore.setWatchLater(b, f.item('two'), true);
    const raw = JSON.parse(f.saved.get('vision_library_v1')); raw.version=1;
    raw.playlists=[{id:'legacy-shared',name:'Old list',createdAt:1,entries:raw.watchLater},{id:'legacy-empty',name:'Unattributed private name',createdAt:1,entries:[]}];
    f.saved.set('vision_library_v1',JSON.stringify(raw));
    const listA=(await f.VisionStore.load([a])).playlists,listB=(await f.VisionStore.load([b])).playlists;
    assert.equal(listA.length,1);assert.equal(listB.length,1);assert.notEqual(listA[0].id,listB[0].id);
    assert.equal(listA[0].entries[0].item.id,'one');assert.equal(listB[0].entries[0].item.id,'two');
    await f.VisionStore.renamePlaylist(listA[0].id,'Only account A',a);
    assert.equal((await f.VisionStore.load([a])).playlists[0].name,'Only account A');
    assert.equal((await f.VisionStore.load([b])).playlists[0].name,'Old list');
    const migrated=JSON.parse(f.saved.get('vision_library_v1'));assert.equal(migrated.version,2);
    assert(migrated.playlists.some(list=>list.name==='Unattributed private name'),'Unowned legacy data is preserved, never assigned to an arbitrary current account');
  });
  await group('inactive view does no provider work and all publication waits for a frame', async () => {
    const f = fixture(), a = f.server(), frames = [], c = new f.VisionController(s => frames.push(s));
    c.configure([a], false); await f.flush(); assert.equal(f.calls.length, 0); assert.equal(frames.length, 0);
    c.configure([a], true, 0, 2); assert.equal(frames.length, 0); await tick(); assert.equal(frames.length, 0);
    await f.flush(); assert.equal(frames.length > 0, true); assert.equal(f.calls.filter(x => x[0] === 'resume').length, 1);
    c.configure([a], true, 0, 2); await f.flush(); assert.equal(f.calls.filter(x => x[0] === 'resume').length, 1);
    c.destroy();
  });
  await group('watching merges real remote rows and exact local account progress', async () => {
    const f = fixture(), a = f.server(), frames = []; f.remote.set('a', [f.item('remote'), f.item('done', { played: true }), f.item('nearly', { progressTicks: 980 * 10000 })]);
    f.progress.set('a:user-a', [f.record('remote', { positionMs: 350, updatedAt: 20 }), f.record('local'), f.record('finished', { completed: true })]);
    f.progress.set('a:other-user', [f.record('wrong-account')]);
    const c = new f.VisionController(s => frames.push(s)); c.configure([a], true, 0, 2); await f.flush(); const rows = frames.at(-1).watching;
    assert.equal(rows.length, 2); assert.equal(rows[0].item.id, 'remote'); assert.equal(rows[0].positionMs, 350); assert.equal(rows[1].item.id, 'local');
    assert.equal(f.calls.filter(x => x[0] === 'progress-all').length, 1); c.destroy();
  });
  await group('remote failure keeps useful local data and exposes source error', async () => {
    const f = fixture(), frames = []; f.remote.set('a', () => { throw Error('network'); }); f.progress.set('a:user-a', [f.record('local')]);
    const c = new f.VisionController(s => frames.push(s)); c.configure([f.server()], true, 0, 2); await f.flush();
    assert.equal(frames.at(-1).watching[0].item.id, 'local'); assert(frames.at(-1).errors.some(x => /服务器继续观看读取失败/.test(x))); c.destroy();
  });
  await group('watching deduplicates repeated provider items and uses newest exact local progress only', async () => {
    const f=fixture(),a=f.server(),frames=[];
    f.remote.set('a',[f.item('one'),f.item('one'),f.item('not-playable',{type:'Series'}),f.item('completed')]);
    f.progress.set('a:user-a',[f.record('one',{positionMs:600,updatedAt:20}),f.record('one',{positionMs:200,updatedAt:10}),
      f.record('completed',{completed:true,updatedAt:30}),f.record('completed',{completed:false,updatedAt:2})]);
    const controller=new f.VisionController(state=>frames.push(state));controller.configure([a],true,0,2);await f.flush();
    assert.equal(frames.at(-1).watching.length,1);assert.equal(frames.at(-1).watching[0].positionMs,600);
    assert.equal(frames.at(-1).watching[0].item.isPlayable(),true);controller.destroy();
  });
  await group('completed local tombstones suppress stale remote resume within exact source/account only', async () => {
    const f = fixture(), a = f.server(), b = f.server('b'), frames = [];
    f.remote.set('a', [f.item('done'), f.item('nearly'), f.item('other-account')]); f.remote.set('b', [f.item('done')]);
    f.progress.set('a:user-a', [f.record('done', { completed: true }), f.record('nearly', { positionMs: 980 })]);
    f.progress.set('a:other-user', [f.record('other-account', { completed: true })]);
    const ctl = new f.VisionController(s => frames.push(s)); ctl.configure([a, b], true, 0, 2); await f.flush();
    const rows = frames.at(-1).watching;
    assert.equal(rows.length, 1); assert(!rows.some(row => row.server.id === 'b'));
    assert(rows.some(row => row.server.id === 'a' && row.item.id === 'other-account'));
    assert.equal(f.calls.filter(x => x[0] === 'progress-all').length, 1, 'One bounded repository read for the current source');
    ctl.configure([b], true, 0, 2); await f.flush(); assert.equal(frames.at(-1).watching[0].item.id, 'done'); ctl.destroy();
  });
  await group('only the current source is read; hidden/locked refuse access and aggregation-off does not block it', async () => {
    const f = fixture(), frames = [], a = f.server('visible'), b = f.server('hidden'), c = f.server('locked'), d = f.server('disabled');
    f.options.set('hidden', { hidden: true }); f.options.set('locked', { locked: true }); f.options.set('disabled', { aggregateEnabled: false });
    for (const s of [a, b, c, d]) { f.remote.set(s.id, [f.item(s.id)]); await f.VisionStore.setWatchLater(s, f.item(s.id), true); }
    const ctl = new f.VisionController(s => frames.push(s)); ctl.configure([a, b, c, d], true, 0, 2); await f.flush();
    assert.equal(f.calls.filter(x => x[0] === 'resume').length, 1); assert.equal(frames.at(-1).watching[0].server.id, 'visible'); assert.equal(frames.at(-1).watchLater.length, 1);
    ctl.configure([b], true, 0, 2); await f.flush(); assert.equal(frames.at(-1).watching.length, 0); assert.equal(await ctl.canOpen(new f.VisionRow(b, f.item())), false);
    ctl.configure([c], true, 0, 2); await f.flush(); assert.equal(frames.at(-1).watching.length, 0);
    ctl.configure([d], true, 0, 2); await f.flush(); assert.equal(frames.at(-1).watching[0].server.id, 'disabled'); assert.equal(await ctl.canOpen(new f.VisionRow(d, f.item())), true); ctl.destroy();
  });
  await group('calendar uses provider episode dates only, never fabricated recommendations', async () => {
    const f = fixture(), a = f.server(), frames = [], now = new Date();
    const today = [now.getFullYear(), String(now.getMonth() + 1).padStart(2, '0'), String(now.getDate()).padStart(2, '0')].join('-');
    await f.VisionStore.setWatchLater(a, f.item('series', { type: 'Series', progressTicks: 0 }), true);
    f.episodes.set('a:series', [f.item('today', { type: 'Episode', premiereDate: today + 'T00:00:00Z' }), f.item('old', { type: 'Episode', premiereDate: '2000-01-01' }), f.item('undated', { type: 'Episode' })]);
    const ctl = new f.VisionController(s => frames.push(s)); ctl.configure([a], true, 0, 1); await f.flush();
    assert.equal(frames.at(-1).calendar.length, 1); assert.equal(frames.at(-1).calendar[0].item.id, 'today'); assert.equal(frames.at(-1).calendarBusy, false);
    f.episodes.set('a:series', [f.item('unknown', { type: 'Episode' })]); await ctl.refresh(); await f.flush(); assert.equal(frames.at(-1).calendarUnknown, true); assert.equal(frames.at(-1).calendar.length, 0);
    f.episodes.set('a:series', () => { throw Error('network'); }); await ctl.refresh(); await f.flush(); assert.match(frames.at(-1).calendarError, /无法读取/); ctl.destroy();
  });
  await group('late resume and calendar work cannot publish after account switch or section change', async () => {
    const f = fixture(), a = f.server(), b = f.server('b'), frames = [], late = deferred(); f.remote.set('a', () => late.promise); f.remote.set('b', [f.item('new')]);
    const ctl = new f.VisionController(s => frames.push(s)); ctl.configure([a], true, 0, 2); await f.frame(); ctl.configure([b], true, 0, 2); await f.flush();
    late.resolve([f.item('old')]); await f.flush(); assert.equal(frames.at(-1).watching[0].item.id, 'new'); assert(f.calls.some(x => x[0] === 'cancel' && x[1] === 'a'));
    await f.VisionStore.setWatchLater(b, f.item('series', { type: 'Series' }), true); const lateCalendar = deferred(); f.episodes.set('b:series', () => lateCalendar.promise);
    await ctl.refresh(); ctl.selectSection(1); await f.frame(); ctl.selectSection(0); await f.frame(); const count = frames.length;
    lateCalendar.resolve([f.item('old-date')]); await f.flush(); assert.equal(frames.at(-1).section, 0); assert.equal(frames.length, count); ctl.destroy();
  });
  await group('action fresh-lock gate rejects expired PIN and delayed checks after source swap', async () => {
    const f = fixture(), a = f.server(), b = f.server('b'), frames = [], ctl = new f.VisionController(s => frames.push(s)); ctl.configure([a], true, 0, 2); await f.flush();
    const row = new f.VisionRow(a, f.item()); f.options.set('a', { locked: true }); assert.equal(await ctl.canOpen(row), false);
    f.options.set('a', { locked: false }); const late = deferred(); f.lock(() => late.promise); const opening = ctl.canOpen(row); await tick();
    ctl.configure([b], true, 0, 2); await f.flush(); late.resolve(false); assert.equal(await opening, false);
    ctl.destroy(); assert.equal(await ctl.canOpen(new f.VisionRow(b, f.item())), false);
  });
  await group('section change while lock check is pending cannot open old action', async () => {
    const f = fixture(), a = f.server(), ctl = new f.VisionController(() => {}); ctl.configure([a], true, 0, 2); await f.flush();
    const late = deferred(); f.getOption(() => late.promise); const opening = ctl.canOpen(new f.VisionRow(a, f.item())); await tick(); ctl.selectSection(0);
    late.resolve(f.option('a')); assert.equal(await opening, false); assert.equal(f.calls.filter(x => x[0] === 'lock').length, 0); ctl.destroy();
  });
  await group('playlist controller CRUD uses the active account and fresh lock before each mutation', async () => {
    const f=fixture(),a=f.server(),b=f.server('b'),frames=[],ctl=new f.VisionController(state=>frames.push(state));
    ctl.configure([a],true,0,3);await f.flush();const id=await ctl.createPlaylist('A only');await f.flush();
    assert.equal(frames.at(-1).playlists[0].name,'A only');await ctl.addToPlaylist(id,new f.VisionRow(a,f.item('one')));await f.flush();
    ctl.openPlaylist(id);await f.flush();assert.equal(ctl.playlistRows()[0].item.id,'one');
    f.options.set('a',{locked:true});await assert.rejects(ctl.renamePlaylist(id,'Blocked'),/锁定/);
    f.options.set('a',{locked:false});ctl.configure([b],true,0,3);await f.flush();assert.equal(frames.at(-1).playlists.length,0);
    await assert.rejects(ctl.renamePlaylist(id,'Wrong account'),/当前账号/);assert.equal((await f.VisionStore.load([a])).playlists[0].name,'A only');
    ctl.destroy();await assert.rejects(ctl.createPlaylist('after exit'),/不可用/);
  });
  await group('reference structure is four personal sections and provider headers stay provider-specific', async () => {
    const f = fixture(), a = f.server(), ctl = new f.VisionController(() => {}), row = new f.VisionRow(a, f.item());
    assert.equal(ctl.imageHeaders(row).Authorization, a.token); assert.match(ctl.imageUrl(row), /images.invalid/);
    const page = fs.readFileSync(projectFile('entry/src/main/ets/components/VisionPage.ets'), 'utf8');
    const controller = fs.readFileSync(path.join(root, 'vision/VisionController.ets'), 'utf8');
    assert(page.includes("Text('HosVision')")); assert(page.includes("['待看', '日历', '在看', '播放列表']"));
    assert(!/TmdbClient|\/discover|\/trending/.test(controller)); assert(!/ClickEvent|FontWeight\.Light\)/.test(page)); ctl.destroy();
  });
  await group('component account Watch masks old modal and content without writing State during render', async () => {
    const f = fixture(), source = fs.readFileSync(projectFile('entry/src/main/ets/components/VisionPage.ets'), 'utf8');
    const method = name => {
      const start = source.indexOf('private ' + name + '('); assert(start >= 0, name);
      const brace = source.indexOf('{', start); let depth = 1, end = brace + 1;
      while (depth > 0 && end < source.length) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
      return source.substring(start, end);
    };
    const compiled = ts.transpileModule('class PageHarness {' + method('inputsChanged') + method('current') + '} module.exports = PageHarness;', { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
    const module = { exports: {} }; vm.runInNewContext(compiled.outputText, { module, VisionController: f.VisionController });
    const page = new module.exports(), a = f.server(), b = f.server('a', 'other-account'); const configurations = [];
    Object.assign(page, { servers: [a], active: true, frame: { scope: f.VisionController.scope([a]) }, inputScope: f.VisionController.scope([a]), actionGeneration: 4,
      resetDialogOnNextFrame: false, mounted: true, controller: { configure: (...args) => configurations.push(args) }, revision: 0, initialSection: 0, dialog: 'rename', nameInput: 'Private list' });
    page.servers = [b]; page.inputsChanged(); assert.equal(page.current(), false); assert.equal(page.actionGeneration, 5); assert.equal(page.resetDialogOnNextFrame, true);
    assert.equal(page.dialog, 'rename', 'Watch changes plain mask only; deferred frame owns State updates'); assert.equal(configurations.length, 1);
    assert(source.includes('if (!this.current()) { Column() { LoadingProgress()'), 'All content branches share scope gate');
    assert(source.includes('return this.current() && !this.resetDialogOnNextFrame && this.dialog.length > 0;'), 'System sheet rejects stale scope before deferred cleanup');
  });
  console.log(`PASS ${groups} Vision groups (actual storage/controller modules; no device or live provider credentials)`);
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
