/* Contract checks only: SDK mocked, no native/device playback claim. */
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert/strict');
const { ts, projectFile, mpvTypesFile } = require('./test-env.cjs');
const sourcePath = path.resolve(process.argv[2] || projectFile('entry/src/main/ets/common/MpvPlaybackHandle.ets'));
const result = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
assert.equal(result.diagnostics.length, 0, 'No TypeScript syntax diagnostics');
let timerId = 0;
const timers = new Map();
const setTimer = (fn, delay) => { const id = ++timerId; timers.set(id, { fn, delay }); return id; };
const clearTimer = id => timers.delete(id);
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
async function expire(delay) {
  const found = Array.from(timers).filter(([, timer]) => timer.delay === delay);
  assert.equal(found.length, 1, 'Exactly one pending ' + delay + 'ms timeout');
  timers.delete(found[0][0]); found[0][1].fn(); await flush();
}
const E = { MPV_EVENT_START_FILE: 6, MPV_EVENT_FILE_LOADED: 8, MPV_EVENT_SEEK: 20, MPV_EVENT_PLAYBACK_RESTART: 21, MPV_EVENT_END_FILE: 7, MPV_EVENT_SHUTDOWN: 1 };
class PlayerConfig { constructor(options) { Object.assign(this, options); } }
class Media { constructor(url, options) { this.url = url; this.options = options; } }
let rejectCacheReadback = false;
const createdPlayers = [];
class Player {
  constructor(config) {
    createdPlayers.push(this); this.config = config; this.observers = []; this.calls = [];
    this.values = new Map([['pause', true], ['paused-for-cache', false]]);
    this.reported = new Map();
    this.ignoredWrites = new Set();
    this.state = { position: 0, duration: 120, videoParams: { w: 1920, h: 1080, dw: 1920, dh: 1080 }, bufferingPercentage: 0, buffer: 0, speed: 1, volume: 100, eof: false };
    this.native = {
      addEventObserver: o => this.observers.push(o),
      removeEventObserver: o => { this.observers = this.observers.filter(item => item !== o); },
      requestLogMessages: level => this.calls.push(['log', level]),
      observeProperty: (key, format) => this.calls.push(['observe', key, format]),
      setProperty: (key, value) => { this.calls.push(['set', key, value]); if (!this.ignoredWrites.has(key)) this.values.set(key, value === '32MiB' ? 33554432 : value === '8MiB' ? 8388608 : value); },
      getProperty: key => rejectCacheReadback && key === 'demuxer-max-bytes' ? 0 : (this.values.get(key) || 0),
      getPropertyBool: key => this.values.get(key) === true,
      getPropertyString: key => {
        if (this.reported.has(key)) return String(this.reported.get(key));
        if (key.startsWith('current-tracks/') || ['aid', 'sid', 'vid'].includes(key)) return '';
        const value = this.values.get(key);
        return value === undefined ? '' : value === true ? 'yes' : value === false ? 'no' : String(value);
      },
      command: args => this.calls.push(['command', ...args])
    };
  }
  open(media, play) {
    this.calls.push(['open']); this.opened = media; this.playFlag = play;
    if (this.values.get('sid') === 'no') this.reported.set('sid', 'no');
  }
  ready() { this.config.onReady(); }
  event(id) { this.observers.slice().forEach(o => o.onEvent(id, 'mock-event')); }
  property(key, value) {
    this.values.set(key, value);
    this.reported.set(key, value);
    if (key === 'aid' || key === 'vid' || key === 'sid') {
      const currentKey = 'current-tracks/' + (key === 'aid' ? 'audio' : key === 'vid' ? 'video' : 'sub') + '/id';
      if (value === 'no' || value === 'auto') this.reported.delete(currentKey);
      else this.reported.set(currentKey, value);
    }
    if (key === 'time-pos/full' && Number.isFinite(value) && value >= 0) this.state.position = value;
    if (key === 'cache-buffering-state') this.state.bufferingPercentage = value;
    this.observers.slice().forEach(o => o.onPropertyChanged(key, value));
  }
  play() { this.native.setProperty('pause', false); }
  pause() { this.native.setProperty('pause', true); }
  seek(seconds) { this.seekTarget = seconds; this.calls.push(['seek', seconds]); }
  setSpeed(value) { this.state.speed = value; }
  setVolume(value) { this.state.volume = value; }
  destroy() { this.calls.push(['destroy']); this.destroyed = (this.destroyed || 0) + 1; }
}
const moduleObject = { exports: {} };
vm.runInNewContext(result.outputText, {
  module: moduleObject, exports: moduleObject.exports,
  require: name => { assert.equal(name, '@mpv-ohos/mpv-arkts'); return { Player, PlayerConfig, Media, MpvLogLevel: { None: 0 }, MpvEvent: E, MpvFormat: { MPV_FORMAT_STRING: 1, MPV_FORMAT_NODE: 6 } }; },
  setTimeout: setTimer, clearTimeout: clearTimer
}, { filename: sourcePath });
const Handle = moduleObject.exports.MpvPlaybackHandle;
const adapterPath = path.resolve(process.argv[3] || projectFile('entry/src/main/ets/common/MpvAdapter.ets'));
const adapterResult = ts.transpileModule(fs.readFileSync(adapterPath, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
assert.equal(adapterResult.diagnostics.length, 0, 'Adapter TypeScript syntax');
// Strictly check the new technical getter against query signatures extracted
// from the installed package's actual MpvLib declarations, without building the app.
const adapterAst = ts.createSourceFile(adapterPath, fs.readFileSync(adapterPath, 'utf8'), ts.ScriptTarget.ES2020, true);
const nativePath = mpvTypesFile();
const nativeAst = ts.createSourceFile(nativePath, fs.readFileSync(nativePath, 'utf8'), ts.ScriptTarget.ES2020, true);
const nativeClass = nativeAst.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'MpvLib');
const adapterClass = adapterAst.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'MpvAdapter');
const technicalInterface = adapterAst.statements.find(node => ts.isInterfaceDeclaration(node) && node.name.text === 'MpvTechnicalInfo');
const technicalMethods = ['getTechnicalInfo', 'applyScreenRatio', 'setSubtitleScale'].map(name => {
  const method = adapterClass.members.find(node => ts.isMethodDeclaration(node) && node.name.getText(adapterAst) === name);
  assert.ok(method); return method.getText(adapterAst);
});
assert.ok(nativeClass && technicalInterface);
const nativeSignatures = ['getProperty', 'getPropertyString', 'setProperty'].map(name => {
  const member = nativeClass.members.find(node => ts.isMethodDeclaration(node) && node.name.getText(nativeAst) === name);
  assert.ok(member && member.type);
  return name + '(' + Array.from(member.parameters).map(parameter => parameter.getText(nativeAst)).join(', ') + '): ' + member.type.getText(nativeAst) + ';';
}).join('\n');
const technicalCheckPath = path.join(__dirname, 'MpvTechnicalInfo.check.ts');
const coreAst = ts.createSourceFile(sourcePath, fs.readFileSync(sourcePath, 'utf8'), ts.ScriptTarget.ES2020, true);
const playbackErrorClass = coreAst.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'PlaybackError');
const technicalCheckSource = technicalInterface.getText(adapterAst) + '\ninterface NativeQueries {\n' + nativeSignatures + '\n}\n'
  + playbackErrorClass.getText(coreAst) + '\n'
  + 'declare const nativeQueries: NativeQueries;\ndeclare const hilog: { info(domain: number, tag: string, format: string, ...args: string[]): void };\nclass TechnicalProbe { private closed = false; private core = { surfaceController: { native: nativeQueries } };\n'
  + technicalMethods.join('\n') + '\n}';
const typeOptions = { strict: true, noEmit: true, skipLibCheck: true, types: [], target: ts.ScriptTarget.ES2020 };
const typeHost = ts.createCompilerHost(typeOptions);
const originalGetSourceFile = typeHost.getSourceFile.bind(typeHost);
typeHost.getSourceFile = (file, languageVersion, onError, shouldCreateNewSourceFile) => path.resolve(file) === path.resolve(technicalCheckPath)
  ? ts.createSourceFile(file, technicalCheckSource, languageVersion, true)
  : originalGetSourceFile(file, languageVersion, onError, shouldCreateNewSourceFile);
const technicalProgram = ts.createProgram([technicalCheckPath], typeOptions, typeHost);
const technicalDiagnostics = ts.getPreEmitDiagnostics(technicalProgram);
for (const diagnostic of technicalDiagnostics) console.error(ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n'));
assert.equal(technicalDiagnostics.length, 0, 'Technical getter strict types against actual wrapper query signatures');
console.log('PASS technical/ratio/subtitle APIs strict types against installed MpvLib declarations (no app build)');
const adapterModule = { exports: {} };
vm.runInNewContext(adapterResult.outputText, {
  module: adapterModule, exports: adapterModule.exports, setTimeout: setTimer, clearTimeout: clearTimer,
  require: name => {
    if (name === './MpvPlaybackHandle') return moduleObject.exports;
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
    if (name === '@kit.MediaKit') return { media: {
      VideoScaleType: { VIDEO_SCALE_TYPE_FIT: 0, VIDEO_SCALE_TYPE_FIT_CROP: 1 },
      MediaType: { MEDIA_TYPE_AUD: 0, MEDIA_TYPE_VID: 1, MEDIA_TYPE_SUBTITLE: 2 },
      BufferingInfoType: { BUFFERING_START: 0, BUFFERING_END: 1, BUFFERING_PERCENT: 2 }
    } };
    throw new Error('Unexpected adapter import: ' + name);
  }
}, { filename: adapterPath });
const Adapter = adapterModule.exports.MpvAdapter;
async function makeLoaded() {
  const h = new Handle(), p = h.surfaceController;
  p.ready(); const opening = h.open({ url: 'http://example.invalid/media' }); await flush();
  p.event(E.MPV_EVENT_FILE_LOADED); await opening; return { h, p };
}
let passed = 0;
async function test(name, body) {
  await body(); assert.equal(timers.size, 0, 'No lifecycle timers remain');
  passed++; console.log('PASS ' + name);
}
(async () => {
  console.log('Source: ' + sourcePath);
  await test('raw global headers precede open; cache 32/8MiB +20s/disk off; native ready/play/track/seek confirmation', async () => {
    const h = new Handle(), p = h.surfaceController, states = [], positions = [], seeks = [], errors = [];
    h.onState = value => states.push(value); h.onPosition = value => positions.push(value);
    h.onSeekDone = value => seeks.push(value); h.onError = error => errors.push(error);
    assert.equal(h.capabilities.firstRenderedFrame, false);
    assert.equal(p.values.get('demuxer-max-bytes'), 33554432);
    assert.equal(p.values.get('demuxer-max-back-bytes'), 8388608);
    assert.equal(p.values.get('cache-secs'), 20); assert.equal(p.values.get('cache-on-disk'), false);
    const opening = h.open({ url: 'http://example.invalid/media', headers: new Map([['Authorization', 'test-raw-token'], ['X-Test', 'a,b\\c']]) });
    p.event(E.MPV_EVENT_START_FILE);
    assert.equal(h.getSnapshot().state, 'opening'); assert.equal(p.opened, undefined, 'No load before surface attachment');
    p.ready(); await flush();
    assert.equal(p.values.get('http-header-fields'), 'Authorization: test-raw-token,X-Test: a\\,b\\\\c');
    assert.equal(p.values.get('sid'), 'no', 'Apply native subtitle-off policy before load');
    assert.equal(Object.prototype.hasOwnProperty.call(p.opened.options, 'httpHeaders'), false, 'No per-file header option');
    assert.equal(p.playFlag, false, 'Load paused while waiting for FILE_LOADED');
    const headerIndex = p.calls.findIndex(c => c[0] === 'set' && c[1] === 'http-header-fields');
    assert.ok(headerIndex >= 0 && headerIndex < p.calls.findIndex(c => c[0] === 'open'));
    assert.ok(p.calls.findIndex(c => c[0] === 'set' && c[1] === 'sid' && c[2] === 'no') < p.calls.findIndex(c => c[0] === 'open'));
    assert.equal(h.getSnapshot().state, 'opening');
    p.event(E.MPV_EVENT_FILE_LOADED); await opening; assert.equal(h.getSnapshot().state, 'ready');
    await h.play(); assert.equal(h.getSnapshot().state, 'ready', 'Submitting play does not confirm native playback');
    p.property('pause', false); assert.equal(h.getSnapshot().state, 'playing');
    p.property('time-pos/full', 2.345); p.property('time-pos/full', NaN); p.property('time-pos/full', -1);
    assert.deepEqual(positions, [2345]);
    p.property('track-list', JSON.stringify([{ id: 1, type: 'audio', selected: true }, { id: 2, type: 'audio', selected: false }, { id: 3, type: 'sub', selected: true }]));
    assert.equal(h.getSelectedTrackId('audio'), null, 'Missing native string is unknown, never numeric zero');
    p.reported.set('current-tracks/audio/id', '1');
    assert.equal(h.getSelectedTrackId('audio'), '1');
    await h.selectTrack('audio', '2');
    assert.equal(p.values.get('aid'), '2'); assert.equal(h.getTracks()[0].selected, true, 'No optimistic selection');
    assert.equal(h.getSelectedTrackId('audio'), '1', 'Set command cannot substitute for current native selection');
    p.property('aid', 'auto'); assert.equal(h.getTracks()[0].selected, true);
    p.property('aid', '2'); assert.equal(h.getTracks()[1].selected, true);
    assert.equal(h.getSelectedTrackId('audio'), '2');
    p.property('sid', 'no'); assert.equal(h.getTracks()[2].selected, false);
    assert.equal(h.getSelectedTrackId('subtitle'), '');
    p.property('track-list', '{unavailable'); assert.equal(errors.length, 0);
    let completed = false;
    const seeking = h.seek(8000).then(() => { completed = true; });
    assert.equal(p.seekTarget, 8); assert.equal(h.getSnapshot().positionMs, 2345, 'No optimistic requested position');
    await assert.rejects(h.seek(9000), /seek-state-or-position/);
    p.event(E.MPV_EVENT_PLAYBACK_RESTART); await flush(); assert.equal(completed, false);
    p.event(E.MPV_EVENT_SEEK); p.property('time-pos/full', 8.023); assert.equal(completed, false);
    p.event(E.MPV_EVENT_PLAYBACK_RESTART); await seeking; assert.deepEqual(seeks, [8023], 'Actual native completion position');
    await assert.rejects(h.open({ url: 'http://example.invalid/again' }), /open-once/);
    const released = h.release(); assert.equal(h.release(), released); await released; await h.release();
    assert.equal(p.destroyed, 1); assert.equal(p.values.get('http-header-fields'), '');
    const clearIndex = p.calls.findIndex(c => c[0] === 'set' && c[1] === 'http-header-fields' && c[2] === '');
    assert.ok(clearIndex >= 0 && clearIndex < p.calls.findIndex(c => c[0] === 'destroy'));
    const oldLength = positions.length;
    p.property('time-pos/full', 9); h.onPropertyChanged('time-pos/full', 10); h.onEvent(E.MPV_EVENT_END_FILE, 'late'); p.ready();
    assert.equal(positions.length, oldLength); assert.equal(h.getSnapshot().state, 'released');
    assert.equal(states.filter(s => s === 'released').length, 1);
  });
  await test('release cancels pending surface; late readiness/events do not reopen', async () => {
    const h = new Handle(), p = h.surfaceController;
    const rejected = assert.rejects(h.open({ url: 'http://example.invalid/media' }), /Playback open failed/);
    await h.release(); await rejected; p.ready(); p.event(E.MPV_EVENT_FILE_LOADED); await flush();
    assert.equal(p.opened, undefined); assert.equal(p.destroyed, 1); assert.equal(h.getSnapshot().state, 'released');
  });
  await test('release cancels in-flight load and seek', async () => {
    const loading = new Handle(), lp = loading.surfaceController; lp.ready();
    const rejected = assert.rejects(loading.open({ url: 'http://example.invalid/media' }), /Playback open failed/);
    await flush(); assert.ok(lp.opened); await loading.release(); await rejected;
    const { h, p } = await makeLoaded();
    const rejectedSeek = assert.rejects(h.seek(60000), /cancelled/);
    await h.release(); await rejectedSeek; p.event(E.MPV_EVENT_SEEK); p.event(E.MPV_EVENT_PLAYBACK_RESTART);
    assert.equal(h.getSnapshot().state, 'released');
  });
  await test('surface/load/seek timeouts reject and cleanup', async () => {
    const surface = new Handle();
    const rs = assert.rejects(surface.open({ url: 'http://example.invalid/media' }), /Playback open failed/);
    await expire(10000); await rs; assert.equal(surface.getSnapshot().state, 'error'); await surface.release();
    const loading = new Handle(); loading.surfaceController.ready();
    const rl = assert.rejects(loading.open({ url: 'http://example.invalid/media' }), /Playback open failed/);
    await flush(); await expire(30000); await rl; assert.equal(loading.getSnapshot().state, 'error'); await loading.release();
    const { h } = await makeLoaded();
    const rk = assert.rejects(h.seek(1000), /seek-completion-timeout/);
    await expire(15000); await rk; assert.equal(h.getSnapshot().state, 'ready', 'Operation timeout is not a fabricated native error'); await h.release();
  });
  await test('snapshot recovers native EOF without callbacks and duplicate EOF events complete exactly once', async () => {
    const { h, p } = await makeLoaded(), states = [];
    h.onState = value => states.push(value);
    p.values.set('eof-reached', true);
    assert.equal(h.getSnapshot().state, 'ready', 'Loaded paused media has not started');
    await h.play();
    p.state.position = 119.848; p.state.duration = 120;
    p.values.set('pause', true);
    assert.equal(h.getSnapshot().state, 'completed', 'Only the actual native EOF decides completion');
    h.getSnapshot(); p.property('pause', true); p.property('eof-reached', true); p.event(E.MPV_EVENT_END_FILE);
    assert.equal(states.filter(value => value === 'completed').length, 1);
    await h.release();
  });
  await test('near-end pause and duration equality do not complete without native EOF', async () => {
    const { h, p } = await makeLoaded(), states = [];
    h.onState = value => states.push(value);
    await h.play(); p.property('pause', false);
    p.state.position = 120; p.state.duration = 120; p.values.set('eof-reached', false);
    await h.pause(); p.property('pause', true);
    for (let index = 0; index < 20; index++) assert.equal(h.getSnapshot().state, 'paused');
    assert.equal(states.includes('completed'), false);
    await h.release();
  });
  await test('stale EOF while seeking waits for a real seek completion and the resulting native EOF', async () => {
    const { h, p } = await makeLoaded(), states = [];
    h.onState = value => states.push(value);
    await h.play(); p.property('pause', false);
    const seeking = h.seek(10000);
    p.property('eof-reached', true); p.event(E.MPV_EVENT_END_FILE);
    assert.equal(h.getSnapshot().state, 'playing');
    assert.equal(states.includes('completed'), false, 'An in-flight seek cannot consume the old EOF');
    p.values.set('eof-reached', false);
    p.event(E.MPV_EVENT_SEEK); p.property('time-pos/full', 10); p.event(E.MPV_EVENT_PLAYBACK_RESTART);
    await seeking;
    assert.equal(h.getSnapshot().state, 'playing');
    p.values.set('eof-reached', true); p.property('pause', true);
    assert.equal(h.getSnapshot().state, 'completed');
    assert.equal(states.filter(value => value === 'completed').length, 1);
    await h.release();
  });
  await test('EOF after a failed seek, fatal error, release or unavailable query cannot fabricate completion', async () => {
    const { h, p } = await makeLoaded(), states = [];
    h.onState = value => states.push(value);
    await h.play(); p.property('pause', false);
    const rejectedSeek = assert.rejects(h.seek(10000), /seek-completion-timeout/);
    p.values.set('eof-reached', true);
    await expire(15000); await rejectedSeek;
    h.getSnapshot(); assert.equal(states.includes('completed'), false);
    p.event(E.MPV_EVENT_SHUTDOWN); p.property('eof-reached', true); p.event(E.MPV_EVENT_END_FILE);
    assert.equal(h.getSnapshot().state, 'error');
    await h.release(); h.getSnapshot(); p.property('eof-reached', true);
    assert.equal(h.getSnapshot().state, 'released');
    assert.equal(states.includes('completed'), false);
    const unavailable = await makeLoaded(); await unavailable.h.play();
    const query = unavailable.p.native.getPropertyBool;
    unavailable.p.native.getPropertyBool = key => { if (key === 'eof-reached') throw Error('unavailable'); return query(key); };
    assert.equal(unavailable.h.getSnapshot().state, 'ready');
    await unavailable.h.release();
  });
  await test('EOF differs from failure; invalid auth never loads; missing cache limits fail closed', async () => {
    const { h, p } = await makeLoaded(); await h.play(); p.property('eof-reached', true);
    assert.equal(h.getSnapshot().state, 'completed'); await h.release();
    const failure = new Handle(); failure.surfaceController.ready();
    const rf = assert.rejects(failure.open({ url: 'http://example.invalid/media' }), /Playback open failed/);
    await flush(); failure.surfaceController.event(E.MPV_EVENT_END_FILE); await rf;
    assert.equal(failure.getSnapshot().state, 'error'); await failure.release();
    const invalid = new Handle(); invalid.surfaceController.ready();
    await assert.rejects(invalid.open({ url: 'http://example.invalid/media', headers: new Map([['Authorization', 'test\r\nInjected: blocked']]) }), /Playback open failed/);
    assert.equal(invalid.surfaceController.opened, undefined); await invalid.release();
    rejectCacheReadback = true;
    try { assert.throws(() => new Handle(), /cache-limit-not-applied/); } finally { rejectCacheReadback = false; }
    assert.equal(createdPlayers[createdPlayers.length - 1].destroyed, 1);
  });
  await test('adapter reads current native selection after early false flags; deselect confirms real native no', async () => {
    const count = createdPlayers.length;
    const creating = Adapter.create(); await flush();
    assert.equal(createdPlayers.length, count, 'Factory must yield a macrotask before binding even its first instance');
    await expire(0); const adapter = await creating;
    const h = adapter.core, p = h.surfaceController;
    let technical = adapter.getTechnicalInfo();
    assert.equal(technical.fps, null); assert.equal(technical.bitrate, null);
    assert.equal(technical.hardware, 'unknown'); assert.equal(technical.dynamicRange, '');
    p.values.set('container-fps', 23.976); p.values.set('video-bitrate', 4976329);
    p.reported.set('hwdec-current', 'ohcodec'); p.reported.set('video-params/gamma', 'bt.1886');
    technical = adapter.getTechnicalInfo();
    assert.equal(technical.fps, 23.976); assert.equal(technical.bitrate, 4976329);
    assert.equal(technical.hardware, 'hardware'); assert.equal(technical.dynamicRange, 'SDR');
    p.reported.set('hwdec-current', 'no'); p.reported.set('video-params/gamma', 'pq');
    assert.equal(adapter.getTechnicalInfo().hardware, 'software');
    assert.equal(adapter.getTechnicalInfo().dynamicRange, 'HDR');
    p.reported.set('video-params/gamma', 'hlg'); assert.equal(adapter.getTechnicalInfo().dynamicRange, 'HDR');
    p.reported.set('video-params/gamma', 'linear'); assert.equal(adapter.getTechnicalInfo().dynamicRange, '');
    p.reported.delete('hwdec-current'); p.reported.delete('video-params/gamma');
    p.values.set('container-fps', NaN); p.values.set('video-bitrate', Infinity);
    technical = adapter.getTechnicalInfo();
    assert.equal(technical.fps, null); assert.equal(technical.bitrate, null);
    assert.equal(technical.hardware, 'unknown'); assert.equal(technical.dynamicRange, '');
    p.values.set('container-fps', -1); p.values.set('video-bitrate', 0);
    assert.equal(adapter.getTechnicalInfo().fps, null); assert.equal(adapter.getTechnicalInfo().bitrate, null);
    const modeCases = [
      ['默认', true, 0, 'no', 'no'], ['平铺', true, 1, 'no', 'no'],
      ['拉伸', false, 0, 'no', 'no'], ['裁切', true, 1, 'no', 'no'],
      ['16:9', true, 0, '16:9', 'no'], ['4:3', true, 0, '4:3', 'no'],
      ['原始像素比例', true, 0, 'no', 'yes']
    ];
    for (const [mode, keepaspect, panscan, aspect, unscaled] of modeCases) {
      adapter.applyScreenRatio(mode);
      assert.equal(p.values.get('keepaspect'), keepaspect); assert.equal(p.values.get('panscan'), panscan);
      assert.equal(p.values.get('video-aspect-override'), aspect); assert.equal(p.values.get('video-unscaled'), unscaled);
    }
    const callCount = p.calls.length;
    assert.throws(() => adapter.applyScreenRatio('unknown'), /screen-ratio-mode/);
    assert.equal(p.calls.length, callCount, 'Invalid ratio must not modify native state');
    adapter.applyScreenRatio('默认');
    p.ignoredWrites.add('video-unscaled');
    assert.throws(() => adapter.applyScreenRatio('原始像素比例'), /screen-ratio/);
    assert.equal(p.values.get('video-unscaled'), 'no'); assert.equal(p.values.get('keepaspect'), 'yes');
    p.ignoredWrites.delete('video-unscaled');
    for (const scale of [0.5, 1.25, 2]) { adapter.setSubtitleScale(scale); assert.equal(p.values.get('sub-scale'), scale); }
    for (const scale of [0.49, 2.01, NaN, Infinity]) assert.throws(() => adapter.setSubtitleScale(scale), /subtitle-scale-range/);
    p.ignoredWrites.add('sub-scale');
    assert.throws(() => adapter.setSubtitleScale(1), /subtitle-scale-readback/);
    assert.equal(p.values.get('sub-scale'), 2);
    p.ignoredWrites.delete('sub-scale');
    p.ready(); const opening = adapter.open('http://example.invalid/media', {}); await flush();
    p.property('track-list', JSON.stringify([{ id: 1, type: 'video', selected: false }, { id: 2, type: 'audio', selected: false }, { id: 17, type: 'sub', selected: false }]));
    p.event(E.MPV_EVENT_FILE_LOADED); await opening;
    const descriptions = await adapter.getTrackDescription();
    let resolved = false;
    const querying = adapter.getSelectedTracks().then(result => { resolved = true; return result; });
    await flush(); assert.equal(resolved, false, 'Unready native selection must not return a fabricated empty list');
    p.reported.set('current-tracks/video/id', '1'); p.reported.set('current-tracks/audio/id', '2');
    await expire(100);
    const selected = await querying;
    assert.deepEqual(Array.from(selected), Array.from(descriptions).slice(0, 2).map(item => item.track_index));
    assert.equal(h.getTracks().every(track => !track.selected), true, 'Result came from native IDs, not cached flags');
    p.reported.set('current-tracks/sub/id', '17');
    let deselected = false;
    const disabling = adapter.deselectTrack(descriptions[2].track_index).then(() => { deselected = true; });
    await flush(); assert.equal(deselected, false, 'Early false flag must not skip deselect of currently active subtitle');
    assert.equal(p.values.get('sid'), 'no');
    p.property('sid', 'no'); await expire(100); await disabling;
    assert.deepEqual(Array.from(await adapter.getSelectedTracks()), Array.from(descriptions).slice(0, 2).map(item => item.track_index));
    await adapter.release();
    assert.equal(adapter.getTechnicalInfo().hardware, 'unknown');
    assert.equal(adapter.getTechnicalInfo().fps, null);
  });
  await test('screen ratio accepts native normalized defaults/ratios but rejects zero, stale or unavailable readback', async () => {
    const creating = Adapter.create(); await flush(); await expire(0);
    const adapter = await creating, p = adapter.core.surfaceController;
    const originalQuery = p.native.getPropertyString;
    p.native.getPropertyString = key => {
      const value = originalQuery(key);
      if (key !== 'video-aspect-override') return value;
      return value === 'no' ? '-2.000000' : value === '16:9' ? '1.777778' : value === '4:3' ? '1.333333' : value;
    };
    for (const mode of ['默认', '裁切', '拉伸', '16:9', '4:3', '默认']) {
      adapter.applyScreenRatio(mode);
      assert.equal(p.values.get('keepaspect'), mode !== '拉伸');
      assert.equal(p.values.get('panscan'), mode === '裁切' ? 1 : 0);
      assert.equal(p.values.get('video-aspect-override'), ['16:9', '4:3'].includes(mode) ? mode : 'no');
    }
    const originalSet = p.native.setProperty; let invalidSentinelWrites = 0;
    p.native.setProperty = (key, value) => {
      if (key === 'video-aspect-override' && Number(value) === -2) { invalidSentinelWrites++; throw Error('numeric range'); }
      return originalSet(key, value);
    };
    p.values.set('video-unscaled', 'yes'); p.ignoredWrites.add('video-unscaled');
    assert.throws(() => adapter.applyScreenRatio('4:3'), /screen-ratio/);
    assert.equal(p.values.get('video-aspect-override'), 'no', 'Rollback restores the default public spelling');
    assert.equal(invalidSentinelWrites, 0, 'The internal numeric sentinel must not be sent through a setter range check');
    p.ignoredWrites.delete('video-unscaled'); p.native.setProperty = originalSet; adapter.applyScreenRatio('默认');
    p.native.getPropertyString = key => key === 'video-aspect-override' ? '0' : originalQuery(key);
    assert.throws(() => adapter.applyScreenRatio('拉伸'), /screen-ratio/);
    assert.equal(p.values.get('keepaspect'), 'yes', 'Failed verification rolls back native state');
    p.native.getPropertyString = key => key === 'video-aspect-override' ? '-1.000000' : originalQuery(key);
    assert.throws(() => adapter.applyScreenRatio('默认'), /screen-ratio/, 'Container policy is not the no-override sentinel');
    p.native.getPropertyString = key => key === 'video-aspect-override' ? '1.777778' : originalQuery(key);
    assert.throws(() => adapter.applyScreenRatio('4:3'), /screen-ratio/, 'Stale 16:9 cannot claim 4:3');
    p.native.getPropertyString = key => key === 'video-aspect-override' ? '' : originalQuery(key);
    assert.throws(() => adapter.applyScreenRatio('默认'), /screen-ratio/);
    p.native.getPropertyString = originalQuery;
    await adapter.release();
  });
  await test('source resolution remains decoded w/h across aspect changes and never falls back to display dw/dh', async () => {
    const creating = Adapter.create(); await flush(); await expire(0);
    const adapter = await creating, core = adapter.core, p = core.surfaceController;
    for (const [mode, dw, dh] of [['4:3', 1920, 1440], ['16:9', 1920, 1080], ['平铺', 2848, 1602], ['拉伸', 2848, 1320], ['默认', 1920, 1080]]) {
      adapter.applyScreenRatio(mode);
      p.state.videoParams = { w: 1920, h: 1080, dw, dh };
      assert.equal(core.getSnapshot().width, 1920); assert.equal(core.getSnapshot().height, 1080);
      assert.equal(adapter.width, 1920); assert.equal(adapter.height, 1080);
      assert.equal(p.values.get('video-aspect-override'), ['4:3', '16:9'].includes(mode) ? mode : 'no');
      assert.equal(p.values.get('keepaspect'), mode !== '拉伸', 'Metadata query cannot reset the chosen presentation');
    }
    for (const raw of [0, undefined, NaN, -1]) {
      p.state.videoParams = { w: raw, h: raw, dw: 1920, dh: 1440 };
      assert.equal(core.getSnapshot().width, 0); assert.equal(core.getSnapshot().height, 0);
      assert.equal(adapter.height, 0, 'Unavailable source size remains unknown for the page metadata fallback');
    }
    await adapter.release();
  });
  await test('reference default fits, tile covers equally and stretch disables aspect; failed tile rolls back', async () => {
    const creating = Adapter.create(); await flush(); await expire(0);
    const adapter = await creating, p = adapter.core.surfaceController;
    for (const [mode, keepaspect, panscan] of [['默认', true, 0], ['平铺', true, 1], ['拉伸', false, 0], ['平铺', true, 1], ['默认', true, 0]]) {
      adapter.applyScreenRatio(mode);
      assert.equal(p.values.get('keepaspect'), keepaspect); assert.equal(p.values.get('panscan'), panscan);
      assert.equal(p.values.get('video-aspect-override'), 'no'); assert.equal(p.values.get('video-unscaled'), 'no');
    }
    p.ignoredWrites.add('panscan'); assert.throws(() => adapter.applyScreenRatio('平铺'), /screen-ratio/);
    assert.equal(Number(p.values.get('panscan')), 0); assert.equal(p.values.get('keepaspect'), 'yes');
    assert.equal(p.values.get('video-aspect-override'), 'no');
    assert.equal(typeof adapter.updateSurfaceSize, 'undefined');
    assert.equal(p.calls.some(call => call[0] === 'observe' && call[1] === 'video-dec-params'), false,
      'Native cover handles resized/rotated surfaces; no crop-cap observer remains');
    await adapter.release();
  });
  await test('adapter factory serializes re-entry and yields after an already completed external release', async () => {
    const count = createdPlayers.length;
    const firstCreating = Adapter.create(); const secondCreating = Adapter.create(); await flush();
    assert.equal(createdPlayers.length, count, 'No new global callbacks before a macrotask boundary');
    await expire(0); const first = await firstCreating; await flush();
    assert.equal(first.isReleased, true, 'Next constructor waits for previous release');
    assert.equal(first.surfaceController.destroyed, 1);
    assert.equal(createdPlayers.length, count + 1, 'Second creation also waits for its own gap');
    await expire(0); const second = await secondCreating;
    assert.equal(createdPlayers.length, count + 2); await second.release();
  });
  console.log('PASS: ' + passed + ' lifecycle groups against actual application module. SDK mocked; no ArkTS typecheck, native HTTP/decoding, PiP, or device proof.');
  console.log('Not covered: real SDK task-runner ordering across the factory macrotask gap; native callback routing still has no instance ID.');
})().catch(error => { console.error(error); process.exitCode = 1; });
