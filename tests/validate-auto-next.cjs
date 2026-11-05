'use strict';
const fs = require('node:fs'), vm = require('node:vm');
const assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const source = fs.readFileSync(projectFile('entry/src/main/ets/pages/PlayerPage.ets'), 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source); assert(match, name);
  const start = source.indexOf('{', match.index); let depth = 1, end = start + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    else if (source[end] === '}') depth--;
  }
  return source.slice(match.index, end).replace(/^  private /, '  ');
}
const modelSource = fs.readFileSync(projectFile('entry/src/main/ets/common/Models.ets'), 'utf8');
const modelContext = { exports: {}, module: { exports: {} } };
modelContext.exports = modelContext.module.exports;
vm.runInNewContext(ts.transpileModule(modelSource, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, modelContext);
const { MediaItem } = modelContext.module.exports;
let queueCalls, records, events, navigation, queueProvider, writeGate, navigateMode, autoNext=true;
const server = { id: 'server', userId: 'user', kind: 'fnos' };
const context = {
  exports: {}, MediaItem,
  PlaybackPreferences:{current:()=>({autoNext})},
  Store: { loadServers: async () => [server] },
  PlaybackQueueResolver: { resolve: async (...args) => { queueCalls.push(args); events.push('queue'); return queueProvider(...args); } },
  ProgressRepository: { upsert: async record => {
    records.push({ ...record }); events.push('persist:' + record.itemId + ':' + record.completed);
    if (writeGate) await writeGate.promise;
  } },
  router: { back: () => events.push('back') }, hilog: { info() {}, warn() {} },
  navigate: async (entry, item, sourceId, resumeMs, changingSource) => {
    navigation.push({ itemId: item.id, sourceId, resumeMs, changingSource }); events.push('navigate:' + item.id);
    if (navigateMode === 'reject') throw Error('switch offline');
    if (navigateMode === 'noop') return;
    entry.itemId = item.id; entry.reqSeason = item.parentIndexNumber; entry.reqEpisode = item.indexNumber;
    entry.playbackGen++; entry.player = {}; entry.playPos = 0; entry.duration = 0;
  }
};
const names = ['currentPlayer', 'canStepEpisode', 'currentNavigationItem', 'playableNavigationItem',
  'ensurePlaybackQueue', 'handlePlaybackCompleted', 'retryAutomaticNext', 'navigationServer', 'saveLocalProgress', 'saveNow', 'wirePlayerEvents'];
const entrySource = `class Entry {
  panelMounted=true; playbackGen=7; player={currentTime:9000}; navigationGen=3;
  itemId='one'; reqItemType='Episode'; reqSeriesId='series'; reqServerId='server'; reqUserId='user';
  reqSeason=1; reqEpisode=1; reqImageTag='cover'; title='Series'; subtitle='Episode one';
  episodes=[]; videoUrl='http://example.invalid/stream'; duration=10000; playPos=9500;
  resolvingNavigation=false; switchingPlayback=false; completionHandledGen=-1;
  autoAdvancing=false; autoNextPending=false; loadingFirstFrame=false; isBuffering=false; isPlaying=true;
  errMsg=''; desiredResumeMs=0; lastSaveAt=0; playbackQueueReadyKey=''; playbackQueueKey=''; playbackQueueRequest=null;
  stopTimer(){events.push('stop-timer')} stopWatchdog(){events.push('stop-watchdog')}
  stopAiSubtitles(restore){events.push('stop-ai:'+restore)} showBarTemporarily(){events.push('show-hud')}
  releaseAll(reason){events.push('release:'+reason);this.playbackGen++;this.player=null}
  retryPlayback(){events.push('retry-playback')}
  handlePlaybackFailure(gen,message,code){events.push('playback-failure:'+code)}
  async navigatePlayback(item,source,resume,change){await navigate(this,item,source,resume,change)}
  ${names.map(method).join('\n')}
} exports.Entry=Entry;`;
// The real methods call these mocks only for I/O, engine lifecycle and navigation.
Object.defineProperty(context, 'events', { get: () => events });
const result = ts.transpileModule(entrySource, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(result.diagnostics.length, 0); vm.runInNewContext(result.outputText, context);
const Entry = context.exports.Entry;
const ep = (id, index) => Object.assign(new MediaItem(), { id, type: 'Episode', seriesId: 'series',
  name: id, parentIndexNumber: 1, indexNumber: index });
const one = ep('one', 1), two = ep('two', 2);
const defer = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const turn = () => new Promise(resolve => setImmediate(resolve));
function reset() {
  queueCalls = []; records = []; events = []; navigation = []; writeGate = null; navigateMode = 'success';autoNext=true;
  queueProvider = async () => [one, two]; return new Entry();
}

(async () => {
  let e = reset(), oldPlayer = e.player;
  await Promise.all([e.handlePlaybackCompleted(7, oldPlayer), e.handlePlaybackCompleted(7, oldPlayer)]);
  assert.equal(queueCalls.length, 1); assert.equal(navigation.length, 1);
  assert.deepEqual(navigation[0], { itemId: 'two', sourceId: '', resumeMs: 0, changingSource: false });
  assert.equal(events.filter(v => v === 'stop-timer').length, 1); assert(events.includes('stop-ai:false'));
  assert(records.length >= 1); assert(records.every(r => r.itemId === 'one' && r.completed && r.positionMs === 10000));
  assert(events.findIndex(v => v === 'persist:one:true') < events.indexOf('navigate:two'));
  assert.equal(e.itemId, 'two'); assert(!events.includes('back'));
  e=reset();autoNext=false;await e.handlePlaybackCompleted(7,e.player);assert.equal(queueCalls.length,0);assert.equal(navigation.length,0);assert(events.includes('release:completed'));assert(events.includes('back'));assert(records.every(r=>r.completed));

  e = reset(); e.itemId = 'two'; e.reqEpisode = 2;
  await e.handlePlaybackCompleted(7, e.player);
  assert.equal(navigation.length, 0); assert(events.includes('release:completed-last-episode')); assert(events.includes('back'));
  assert(records.every(r => r.itemId === 'two' && r.completed));

  for (const change of [{ reqItemType: 'Movie' }, { videoUrl: '/data/storage/local.mkv' }]) {
    e = reset(); Object.assign(e, change); await e.handlePlaybackCompleted(7, e.player);
    assert.equal(queueCalls.length, 0); assert.equal(navigation.length, 0); assert(events.includes('release:completed')); assert(events.includes('back'));
  }
  e = reset(); await e.handlePlaybackCompleted(6, e.player); assert.equal(records.length, 0);
  e.resolvingNavigation = true; await e.handlePlaybackCompleted(7, e.player); assert.equal(records.length, 0);

  // UI-disabled navigation is not proof of the final episode. This is the real
  // resolve->persist commit gap: switching=true while resolving=false.
  e = reset(); e.episodes = [one, two]; e.switchingPlayback = true; e.resolvingNavigation = false;
  await e.handlePlaybackCompleted(7, e.player);
  assert.equal(navigation.length, 0); assert.equal(records.length, 0); assert(!events.includes('back'));
  assert(!events.some(value => value.startsWith('release:')));
  e = reset(); e.canStepEpisode = () => false;
  await e.handlePlaybackCompleted(7, e.player);
  assert.equal(navigation[0].itemId, 'two', 'EOF uses actual queue bounds, not a UI-interactivity helper');

  e = reset(); writeGate = defer(); const changedWhileSaving = e.handlePlaybackCompleted(7, e.player);
  e.navigationGen++; e.switchingPlayback = true; writeGate.resolve(); await changedWhileSaving;
  assert.equal(queueCalls.length, 0); assert(!events.includes('back')); assert.equal(navigation.length, 0);
  e = reset(); const manualCommitQueue = defer(); queueProvider = async () => manualCommitQueue.promise;
  const manualDuringQueue = e.handlePlaybackCompleted(7, e.player); await turn();
  e.navigationGen++; e.switchingPlayback = true; e.resolvingNavigation = false;
  manualCommitQueue.resolve([one, two]); await manualDuringQueue;
  assert.equal(navigation.length, 0); assert(!events.includes('back')); assert.equal(e.autoAdvancing, false);
  assert.equal(e.loadingFirstFrame, false, 'Interrupted auto-next cannot leave its loading layer behind');
  e = reset(); let rejectOldQueue; queueProvider = () => new Promise((_resolve, reject) => { rejectOldQueue = reject; });
  const obsoleteQueueFailure = e.handlePlaybackCompleted(7, e.player); await turn();
  e.navigationGen++; e.switchingPlayback = true; rejectOldQueue(Error('obsolete queue error')); await obsoleteQueueFailure;
  assert.equal(e.errMsg, '', 'A superseded EOF queue error cannot cover the manual navigation UI');
  assert.equal(e.autoNextPending, false); assert(!events.includes('back'));

  // A user leaves while the queue request is outstanding: no late navigation, state write or error overlay.
  e = reset(); const waitingQueue = defer(); queueProvider = async () => waitingQueue.promise;
  const waiting = e.handlePlaybackCompleted(7, e.player); await turn();
  e.panelMounted = false; e.playbackGen++; e.navigationGen++; waitingQueue.resolve([one, two]); await waiting;
  assert.equal(navigation.length, 0); assert.equal(e.episodes.length, 0); assert.equal(e.autoNextPending, false); assert.equal(e.errMsg, '');

  // Completion must persist before switching, and leaving during persistence must not start a queue request.
  e = reset(); writeGate = defer(); const persisting = e.handlePlaybackCompleted(7, e.player);
  assert.equal(queueCalls.length, 0); e.panelMounted = false; e.playbackGen++; writeGate.resolve(); await persisting;
  assert.equal(queueCalls.length, 0); assert.equal(navigation.length, 0);

  // A failed queue has one visible retry action. Repeated EOF callbacks do not form a retry loop.
  e = reset(); oldPlayer = e.player; queueProvider = async () => { throw Error('queue offline'); };
  await e.handlePlaybackCompleted(7, oldPlayer); assert.equal(e.autoNextPending, true); assert(e.errMsg.includes('queue offline'));
  await e.handlePlaybackCompleted(7, oldPlayer); assert.equal(queueCalls.length, 1); assert.equal(navigation.length, 0);
  assert(!events.includes('back')); await turn(); queueProvider = async () => [one, two];
  e.retryAutomaticNext(); await turn();
  assert.equal(queueCalls.length, 2); assert.equal(navigation.length, 1); assert.equal(navigation[0].resumeMs, 0); assert.equal(e.itemId, 'two');

  // The real navigation method catches some failures internally; a no-op must still surface a retry.
  e = reset(); navigateMode = 'noop'; await e.handlePlaybackCompleted(7, e.player);
  assert.equal(e.autoNextPending, true); assert(e.errMsg.includes('下一集未能开始'));
  const attempts = navigation.length; await e.handlePlaybackCompleted(7, e.player); assert.equal(navigation.length, attempts);
  navigateMode = 'success'; e.retryAutomaticNext(); await turn(); assert.equal(e.itemId, 'two');
  e = reset(); navigateMode = 'reject'; await e.handlePlaybackCompleted(7, e.player);
  assert.equal(e.autoNextPending, true); assert(e.errMsg.includes('switch offline'));

  // Foreground prefetch and EOF share a request/cache rather than making a second resolution.
  e = reset(); const prefetch = defer(); queueProvider = async () => prefetch.promise;
  const first = e.ensurePlaybackQueue(), second = e.ensurePlaybackQueue(); assert.equal(first, second);
  prefetch.resolve([one, two]); await first; await turn(); await e.handlePlaybackCompleted(7, e.player);
  assert.equal(queueCalls.length, 1); assert.equal(navigation.length, 1);
  e = reset(); e.player = null; e.retryAutomaticNext(); assert(events.includes('retry-playback'));

  // Actual event wiring must distinguish completion from state/operation errors.
  e = reset(); const handlers = new Map();
  const wired = { state: 'playing', on: (type, callback) => handlers.set(type, callback) };
  e.player = wired; e.wirePlayerEvents(7, wired);
  handlers.get('stateChange')('error'); assert.equal(queueCalls.length, 0); assert.equal(e.completionHandledGen, -1);
  handlers.get('error')({ code: 5400104 }); assert.equal(queueCalls.length, 0); assert.equal(navigation.length, 0);
  wired.state = 'error'; handlers.get('error')({ code: 123 }); assert(events.includes('playback-failure:123'));
  assert.equal(e.completionHandledGen, -1);
  handlers.get('stateChange')('completed'); handlers.get('stateChange')('completed'); await turn();
  assert.equal(queueCalls.length, 1); assert.equal(navigation.length, 1);
  console.log('PASS: real EOF/queue/current-item/retry/progress and event-wiring methods; duplicate EOF guard, next episode resume=0, last/non-episode/local exit, stale generation and navigation guard, leave during persistence/queue, old-item completion before switch, visible failed-queue/no-op/rejected-switch retries without loops, foreground shared queue/cache; state/operation errors do not start auto-next. No device, real network or build calls.');
})().catch(error => { console.error(error); process.exitCode = 1; });
