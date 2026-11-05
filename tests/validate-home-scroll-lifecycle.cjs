'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const source = fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'), 'utf8');
function block(start) {
  let depth = 1, end = start + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++; else if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0); return source.slice(start, end);
}
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source);
  assert(match, name); const start = source.indexOf('{', match.index);
  return source.slice(match.index, start).replace(/^  private /, '  ') + block(start);
}
const binding = source.indexOf('.onDidScroll(() => {');
assert(binding >= 0);
const callback = 'onScrollEvent() ' + block(source.indexOf('{', binding));
const methods = ['onHomeScroll', 'homeScrollAllowed', 'commitHomeScroll', 'syncHomeScroll',
  'queueHomeScrollSync', 'cancelHomeScrollSync', 'onShellChange', 'onPageShow', 'onPageHide',
  'aboutToAppear', 'aboutToDisappear', 'onLookChange'];
const text = `class Entry {
  homeScrollMounted=false;homeScrollPageVisible=false;homeScrollTask=-1;homeScrollGeneration=0;
  pendingHomeScrollY=Number.NaN;appActive=true;currentTab=0;showAdd=false;showSearch=false;
  showDownloads=false;locked=false;detailItem=null;browsingLib=null;names=[];height=100;
  heroTouching=false;current={id:'test-server'};winRef=null;writes=[];timerSyncs=0;resumeLoads=0;playRequestGeneration=0;
  _progress=0;
  get heroScrollP(){return this._progress}
  set heroScrollP(value){assertOutsideRender();this.writes.push(value);this._progress=value;onStateCommit(this)}
  stackNames(){return this.names} heroArtworkHeight(){return this.height}
  clamp01(value){return Math.max(0,Math.min(1,value))}
  syncHeroTimer(){this.timerSyncs++} stopHeroTimer(){} restartHeroTimer(){}
  commitArtworkPull(){}cancelArtworkPull(){}
  invalidateSourceRequest(){}
  refreshSourceProtection(){return Promise.resolve()}clearProtectedSource(){this.current=null}
  clearAmbTicker(){}loadResume(){this.resumeLoads++}measureInsets(){}applyNativeColorMode(){}
  applySystemBarStyle(){}applyAmbient(){}watchWindowSize(){}boot(){}
  startLaunchIntro(){}cancelLaunchIntro(){}
  ${methods.map(method).join('\n')}
  ${callback}
} exports.Entry=Entry;`;
const output = ts.transpileModule(text, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
assert.equal(output.diagnostics.length, 0);
const motion = fs.readFileSync(projectFile('entry/src/main/ets/common/MotionSpec.ets'), 'utf8');
const frame = Number(/imageReadyFrame: number = (\d+)/.exec(motion)?.[1]);
assert(Number.isFinite(frame) && frame > 0 && frame <= 32);
let renderActive = false, onCommit = () => {}, next = 0,cachedOption={locked:false};
const tasks = new Map();
const context = { exports: {}, Number, MotionSpec: { imageReadyFrame: frame },ServerOptions:{cached:()=>cachedOption},
  setTimeout(callback, delay) { assert.equal(delay, frame); const id = ++next; tasks.set(id, callback); return id; },
  clearTimeout: id => tasks.delete(id), assertOutsideRender() { assert.equal(renderActive, false, 'State must not change in a render/layout callback'); },
  onStateCommit: value => onCommit(value), Theme: { init() {} }, display: { getDefaultDisplaySync: () => ({ width: 440, height: 900 }) },
  Metrics: { init() {} }, px2vp: value => value };
vm.runInNewContext(output.outputText, context);
function fixture() {
  tasks.clear(); renderActive = false; onCommit = () => {};cachedOption={locked:false};
  const subject = new context.exports.Entry();
  const state = { subject, y: 0, reads: 0, missing: false, readError: false };
  subject.homeScroller = { currentOffset() {
    assert.equal(renderActive, false, 'Scroller is read after the layout callback');
    state.reads++;
    if (state.readError) throw new Error('test unbound scroller');
    return state.missing ? undefined : { yOffset: state.y };
  } };
  subject.aboutToAppear(); return state;
}
function flush(state) {
  const id = state.subject.homeScrollTask;
  const run = tasks.get(id); assert(run, 'one queued scroll synchronization');
  tasks.delete(id); run();
}
function inRender(run) { renderActive = true; try { run(); } finally { renderActive = false; } }
let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS: ' + name); }

test('actual onDidScroll binding only queues; latest offset is read once outside render', () => {
  const state = fixture();
  inRender(() => { for (let n = 0; n < 30; n++) { state.y = n * 2; state.subject.onScrollEvent(); } });
  assert.equal(state.subject.writes.length, 0);
  assert.equal(state.reads, 0); assert.equal(tasks.size, 1);
  state.y = 65; flush(state);
  assert.equal(state.subject.heroScrollP, 0.65);
  assert.equal(state.reads, 1); assert.equal(state.subject.timerSyncs, 1);
});
test('direct offset notifications coalesce, clamp and retain the existing dead zone', () => {
  const state = fixture();
  inRender(() => { state.subject.onHomeScroll(10); state.subject.onHomeScroll(95); });
  assert.equal(tasks.size, 1); assert.equal(state.subject.writes.length, 0);
  flush(state); assert.equal(state.subject.heroScrollP, 0.95); assert.equal(state.reads, 0);
  state.subject.onHomeScroll(95.1); flush(state);
  assert.equal(state.subject.writes.length, 1); assert.equal(state.subject.timerSyncs, 1);
  state.subject.onHomeScroll(-5); flush(state); assert.equal(state.subject.heroScrollP, 0);
  state.subject.onHomeScroll(200); flush(state); assert.equal(state.subject.heroScrollP, 1);
  state.subject.onHomeScroll(Number.NaN); state.subject.onHomeScroll(Number.POSITIVE_INFINITY);
  assert.equal(tasks.size, 0);
});
test('tab cancellation and late callback cannot overwrite a newer task or its cancellation handle', () => {
  const state = fixture(); state.y = 20; state.subject.syncHomeScroll();
  const oldId = state.subject.homeScrollTask, late = tasks.get(oldId);
  state.subject.currentTab = 2; state.subject.onShellChange();
  assert.equal(tasks.has(oldId), false);
  state.subject.currentTab = 0; state.y = 70; state.subject.onShellChange();
  const currentId = state.subject.homeScrollTask;
  late();
  assert.equal(state.subject.homeScrollTask, currentId);
  assert.equal(state.subject.writes.length, 0);
  flush(state); assert.equal(state.subject.heroScrollP, 0.7);
});
test('detail state and navigation-only cover prevent queued commits', () => {
  const state = fixture(); state.y = 80; state.subject.syncHomeScroll();
  state.subject.detailItem = { id: 'detail' }; state.subject.onShellChange();
  assert.equal(tasks.size, 0); assert.equal(state.subject.writes.length, 0);
  state.subject.detailItem = null; state.subject.onShellChange();
  state.subject.names = ['detail']; flush(state);
  assert.equal(state.subject.writes.length, 0);
  state.subject.names = []; state.subject.syncHomeScroll(); flush(state);
  assert.equal(state.subject.heroScrollP, 0.8);
});
test('search/download/library/add-server/lock covers cannot commit even without a watcher callback', () => {
  for (const [key, blocked] of [['showSearch', true], ['showDownloads', true], ['browsingLib', {}], ['showAdd', true], ['locked', true]]) {
    const state = fixture(); state.y = 80; state.subject.syncHomeScroll(); state.subject[key] = blocked;
    flush(state); assert.equal(state.subject.writes.length, 0, key);
  }
});

test('add-server dismissal and unlock automatically resync through their actual shell watchers', () => {
  for (const key of ['showAdd', 'locked']) {
    assert.match(source, new RegExp("@State\\s+@Watch\\('onShellChange'\\)\\s+" + key + ':'));
    const state = fixture(); let value = state.subject[key];
    Object.defineProperty(state.subject, key, {
      get() { return value; },
      set(nextValue) {
        if (value === nextValue) return;
        value = nextValue;
        state.subject.onShellChange();
      }
    });
    state.y = 80; state.subject.syncHomeScroll();
    const oldId = state.subject.homeScrollTask, late = tasks.get(oldId);
    state.subject[key] = true;
    assert.equal(tasks.size, 0, key + ': cover cancels queued synchronization');
    assert.equal(state.subject.writes.length, 0);
    state.y = 35;
    state.subject[key] = false;
    const newId = state.subject.homeScrollTask;
    assert.ok(tasks.has(newId), key + ': no scroll/page-show event is needed to resume');
    late();
    assert.equal(state.subject.homeScrollTask, newId, key + ': old callback cannot clear the new task');
    flush(state);
    assert.equal(state.subject.heroScrollP, 0.35);
    assert.equal(state.reads, 1);
    assert.equal(tasks.size, 0);
  }
});
test('page hide, background and component teardown invalidate pending work and safely resume later', () => {
  for (const mode of ['page', 'background', 'destroy']) {
    const state = fixture(); state.y = 90; state.subject.syncHomeScroll();
    const id = state.subject.homeScrollTask, late = tasks.get(id);
    if (mode === 'page') state.subject.onPageHide();
    else if (mode === 'background') { state.subject.appActive = false; state.subject.onLookChange(); }
    else state.subject.aboutToDisappear();
    assert.equal(tasks.has(id), false, mode); late();
    assert.equal(state.subject.writes.length, 0, mode);
    state.y = 25;
    if (mode === 'background') { state.subject.appActive = true; state.subject.onLookChange(); }
    else { if (mode === 'destroy') state.subject.aboutToAppear(); state.subject.onPageShow(); }
    flush(state); assert.equal(state.subject.heroScrollP, 0.25, mode);
  }
});
test('unbound/invalid Scroller returns without writes and the next valid event recovers', () => {
  const state = fixture();
  state.readError = true; state.subject.syncHomeScroll(); flush(state);
  state.readError = false; state.missing = true; state.subject.syncHomeScroll(); flush(state);
  state.missing = false; state.y = Number.NaN; state.subject.syncHomeScroll(); flush(state);
  assert.equal(state.subject.writes.length, 0);
  state.y = 35; state.subject.syncHomeScroll(); flush(state);
  assert.equal(state.subject.heroScrollP, 0.35);
});
test('a synchronous render callback caused by commit queues one settling read rather than recursive State writes', () => {
  const state = fixture(); state.y = 60;
  onCommit = subject => inRender(() => subject.onScrollEvent());
  inRender(() => state.subject.onScrollEvent()); flush(state);
  assert.equal(state.subject.writes.length, 1); assert.equal(tasks.size, 1);
  flush(state);
  assert.equal(state.subject.writes.length, 1); assert.equal(tasks.size, 0);
});
(async()=>{
  const state=fixture();let release;const waiting=new Promise(resolve=>{release=resolve});
  state.subject.refreshSourceProtection=()=>waiting;state.subject.onPageShow();assert.equal(state.subject.resumeLoads,0,'Resume waits for the fresh protection check');
  release();await new Promise(resolve=>setImmediate(resolve));assert.equal(state.subject.resumeLoads,1);
  const hidden=fixture();let finish;hidden.subject.refreshSourceProtection=()=>new Promise(resolve=>{finish=resolve});
  hidden.subject.onPageShow();hidden.subject.onPageHide();finish();await new Promise(resolve=>setImmediate(resolve));assert.equal(hidden.subject.resumeLoads,0,'A late protection check cannot resume a hidden page');
  const locked=fixture();cachedOption={locked:true};locked.subject.onPageShow();assert.equal(locked.subject.current,null,'Expired cached protection clears content synchronously');
  await new Promise(resolve=>setImmediate(resolve));assert.equal(locked.subject.resumeLoads,0);
  passed++;console.log('PASS: resumed metadata waits for fresh protection, late hidden returns are ignored, cached lock expiry clears immediately');
  console.log(`PASS: ${passed} actual-method home-scroll lifecycle groups. No device/network/build calls.`);
})().catch(error=>{console.error(error);process.exitCode=1});
