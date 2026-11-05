'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const source = fs.readFileSync(projectFile('entry/src/main/ets/pages/PlayerPage.ets'), 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source); assert(match, name);
  const start = source.indexOf('{', match.index); let depth = 1, end = start + 1;
  for (; depth && end < source.length; end++) { if (source[end] === '{') depth++; else if (source[end] === '}') depth--; }
  return source.slice(match.index, end).replace(/^  private /, '  ');
}
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const turn = () => new Promise(resolve => setImmediate(resolve));
const timers = new Map(); let nextTimer = 0, events = [], factoryGate = null, releaseGate = null, created = [];
const context = { exports: {},
  MpvAdapter: { async create() {
    const adapter = { async release() { events.push('late-adapter-release'); adapter.closed = true; } };
    created.push(adapter); events.push('create-adapter'); if (factoryGate) await factoryGate.promise; return adapter;
  } },
  setTimeout(callback, delay) { assert(delay >= 32, 'Surface teardown must cross a render frame'); timers.set(++nextTimer, callback); return nextTimer; },
  SourcePlaybackLeases: { claim: () => true, release: async () => {} },
  PlaybackNavigation: { resolve: async () => ({ leaseId: '', url: 'https://media.invalid/two', useMpv: true }) },
  hilog: { info() {}, warn() {} }, promptAction: { showToast() {} },
  emit(value) { events.push(value); }, closing: () => releaseGate ? releaseGate.promise : Promise.resolve()
};
const methods = ['createMpvSurface', 'retryPlayback', 'handlePlaybackFailure', 'navigatePlayback'];
const body = `class Page {
  panelMounted=true;playbackGen=7;navigationGen=1;pendingRelease=null;_surfaceMounted=true;
  get surfaceMounted(){return this._surfaceMounted}set surfaceMounted(value){this._surfaceMounted=value;emit('surface:'+value)}
  mpvSurfaceAdapter=null;player=null;useMpvEngine=true;sourceRouteError=false;retryingStream=false;
  resolvingNavigation=false;switchingPlayback=false;localFileMode=false;streamRetryCount=0;
  isLiveStream=false;desiredResumeMs=10000;playPos=12000;errMsg='';videoUrl='https://media.invalid/one';
  title='Series';reqSeriesId='series';completionHandledGen=-1;playbackLeaseId='';
  async setupPlayer(){emit('setup')}logStreamStats(){}showBarTemporarily(){}saveNow(){}
  async saveLocalProgress(){}rememberEpisodeProgress(){}async navigationServer(){return {id:'source'}}
  closeSidePanel(){}applyPlaybackTarget(target){emit('apply-target');this.videoUrl=target.url;this.useMpvEngine=true}
  releaseAll(reason,preserve){emit('release:'+reason+':'+preserve);this.playbackGen++;this.pendingRelease=closing()}
  ${methods.map(method).join('\n')}
} exports.Page=Page;`;
const compiled = ts.transpileModule(body, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(compiled.diagnostics.length, 0); vm.runInNewContext(compiled.outputText, context);
const Page = context.exports.Page;
function fixture() { timers.clear(); events = []; factoryGate = null; releaseGate = null; created = []; return new Page(); }
async function detachedFrame(page) {
  await turn(); assert.equal(page.surfaceMounted, false); assert.equal(created.length, 0, 'No new native controller before detached frame');
  assert(timers.size > 0, 'A real deferred frame interval is scheduled'); events.push('render-detached');
  const ready = [...timers.values()]; timers.clear(); ready.forEach(run => run()); await turn();
}
(async () => {
  let page = fixture(); releaseGate = deferred(); page.pendingRelease = releaseGate.promise;
  const initial = page.createMpvSurface(); await turn(); assert.equal(page.surfaceMounted, false); assert.equal(timers.size, 0); assert.equal(created.length, 0);
  releaseGate.resolve(); await detachedFrame(page); await initial;
  assert(events.indexOf('render-detached') < events.indexOf('create-adapter')); assert.equal(page.surfaceMounted, true);

  for (const stop of ['terminal', 'generation']) {
    page = fixture(); const pending = page.createMpvSurface(); await turn();
    if (stop === 'terminal') page.panelMounted = false; else page.playbackGen++;
    await detachedFrame(page); await pending; assert.equal(created.length, 0, stop); assert.equal(page.surfaceMounted, false);
  }
  page = fixture(); factoryGate = deferred(); const pendingFactory = page.createMpvSurface();
  await detachedFrame(page); assert.equal(created.length, 1); page.panelMounted = false; page.playbackGen++;
  factoryGate.resolve(); await pendingFactory; assert.equal(created[0].closed, true); assert.equal(page.mpvSurfaceAdapter, null); assert.equal(page.surfaceMounted, false);

  page = fixture(); const retry = page.retryPlayback(); await detachedFrame(page); await retry;
  assert(events.includes('release:manual-retry:true')); assert.equal(events.filter(value => value === 'create-adapter').length, 1);
  assert(events.includes('setup')); assert.equal(page.retryingStream, false); assert.equal(page.surfaceMounted, true);

  page = fixture(); const automatic = page.handlePlaybackFailure(7, 'stream ended', 0); await detachedFrame(page); await automatic;
  assert(events.includes('release:stream-retry:true')); assert.equal(page.streamRetryCount, 1); assert(events.includes('setup')); assert.equal(page.surfaceMounted, true);

  page = fixture(); const navigation = page.navigatePlayback({ id: 'two' }, '', 0, false);
  await detachedFrame(page); await navigation; assert(events.includes('apply-target')); assert(events.includes('setup'));
  assert(events.indexOf('render-detached') < events.indexOf('create-adapter')); assert.equal(page.surfaceMounted, true);

  page = fixture(); const retryThenLeave = page.retryPlayback(); await turn(); page.panelMounted = false; page.playbackGen++;
  await detachedFrame(page); await retryThenLeave; assert.equal(created.length, 0); assert(!events.includes('setup'));
  page = fixture(); page.panelMounted = false; await page.createMpvSurface(); assert.equal(timers.size, 0); assert.equal(events.length, 0);
  console.log('PASS: actual Player initial/manual retry/automatic retry/next-source Surface lifecycle shares native-release -> detached 32ms frame -> controller creation -> setup; terminal/generation guards before creation and late-adapter release; retry keeps lease ownership. SDK factory and frame clock mocked; no device/build/network.');
})().catch(error => { console.error(error); process.exitCode = 1; });
