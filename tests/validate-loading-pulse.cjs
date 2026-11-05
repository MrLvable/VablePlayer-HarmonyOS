'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const source = fs.readFileSync(projectFile('entry/src/main/ets/pages/PlayerPage.ets'), 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source); assert(match, name);
  const start = source.indexOf('{', match.index); let depth = 1, end = start + 1;
  for (; depth; end++) { if (source[end] === '{') depth++; else if (source[end] === '}') depth--; }
  return source.slice(match.index, end).replace(/^  private /, '  ');
}
const names = ['loadingPulseAllowed', 'queueLoadingPulse', 'cancelLoadingPulse',
  'onLoadingPulseAppear', 'onLoadingPulseDisappear', 'onPageShow', 'onPageHide'];
const text = `class Page {
 panelMounted=true;loadingFirstFrame=true;isBuffering=false;errMsg='';playbackGen=0;
 loadingPulseMounted=false;loadingPulsePageVisible=true;loadingPulseStarted=false;loadingPulseTask=-1;loadingPulseGeneration=0;
 _beat=false;writes=[];
 get loadingBeat(){return this._beat;} set loadingBeat(value){outsideRender();this.writes.push(value);this._beat=value;onCommit(this);}
 ${names.map(method).join('\n')}
} exports.Page=Page;`;
const result = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(result.diagnostics.length, 0);
const spec = fs.readFileSync(projectFile('entry/src/main/ets/common/MotionSpec.ets'), 'utf8');
const frame = Number(/imageReadyFrame: number = (\d+)/.exec(spec)[1]);
let next = 0, render = false, commit = () => {}; const tasks = new Map();
const context = { exports: {}, MotionSpec: { imageReadyFrame: frame },
  setTimeout(run, delay) { assert.equal(delay, frame); const id = ++next; tasks.set(id, run); return id; },
  clearTimeout(id) { tasks.delete(id); }, setInterval() { throw Error('No JavaScript pulse repetition'); },
  outsideRender() { assert.equal(render, false, 'Loading pulse State must not change in render/lifecycle callbacks'); },
  onCommit(page) { commit(page); } };
vm.runInNewContext(result.outputText, context);
function fixture() { tasks.clear(); render = false; commit = () => {}; return new context.exports.Page(); }
function inRender(action) { render = true; try { action(); } finally { render = false; } }
function flush(page) { const run = tasks.get(page.loadingPulseTask); assert(run); tasks.delete(page.loadingPulseTask); run(); }
let passed = 0;
function test(name, body) { body(); assert.equal(tasks.size, 0, 'No pulse timers remain'); passed++; console.log('PASS ' + name); }
test('appear queues one deferred start and disappearance never synchronously resets State', () => {
  const page = fixture(); inRender(() => page.onLoadingPulseAppear());
  assert.equal(page.writes.length, 0); assert.equal(tasks.size, 1); flush(page);
  assert.equal(page.writes.length, 1); assert.equal(page.loadingBeat, true);
  inRender(() => page.onLoadingPulseDisappear()); assert.equal(page.writes.length, 1);
});
test('hide before start cancels old work; a late callback cannot clear or mutate the next loading mount', () => {
  const page = fixture(); inRender(() => page.onLoadingPulseAppear());
  const old = tasks.get(page.loadingPulseTask);
  inRender(() => page.onLoadingPulseDisappear()); old(); assert.equal(page.writes.length, 0);
  inRender(() => page.onLoadingPulseAppear()); const current = page.loadingPulseTask;
  old(); assert.equal(page.loadingPulseTask, current); assert.equal(page.writes.length, 0);
  flush(page); assert.equal(page.writes.length, 1); page.onLoadingPulseDisappear();
});
test('first progress, errors and released pages suppress an already queued pulse even before node teardown', () => {
  for (const mode of ['progress', 'error', 'released']) {
    const page = fixture(); page.onLoadingPulseAppear();
    if (mode === 'progress') page.loadingFirstFrame = false;
    else if (mode === 'error') page.errMsg = 'failed'; else page.panelMounted = false;
    flush(page); assert.equal(page.writes.length, 0, mode); page.onLoadingPulseDisappear();
  }
});
test('page hide cancels; page show restarts on a deferred turn without accepting old callbacks', () => {
  const page = fixture(); page.onLoadingPulseAppear(); const old = tasks.get(page.loadingPulseTask);
  inRender(() => page.onPageHide()); assert.equal(tasks.size, 0); inRender(() => page.onPageShow());
  const current = page.loadingPulseTask; old(); assert.equal(page.loadingPulseTask, current); assert.equal(page.writes.length, 0);
  flush(page); assert.equal(page.writes.length, 1);
  page.onPageHide(); page.onPageShow(); flush(page); assert.equal(page.writes.length, 2); page.onLoadingPulseDisappear();
});
test('repeat appear/retry while the same node is visible does not create a JS pulse loop or repeated resets', () => {
  const page = fixture(); page.onLoadingPulseAppear(); page.onLoadingPulseAppear(); page.queueLoadingPulse();
  assert.equal(tasks.size, 1); flush(page);
  page.playbackGen++; page.queueLoadingPulse(); page.onLoadingPulseAppear();
  assert.equal(tasks.size, 0); assert.equal(page.writes.length, 1);
  page.loadingFirstFrame = false; page.isBuffering = true; page.queueLoadingPulse();
  assert.equal(tasks.size, 0); page.onLoadingPulseDisappear();
  page.onLoadingPulseAppear(); flush(page); assert.equal(page.writes.length, 2); page.onLoadingPulseDisappear();
});
test('render triggered by the deferred State commit can remove the loading node without reentrant State writes', () => {
  const page = fixture(); commit = current => inRender(() => current.onLoadingPulseDisappear());
  inRender(() => page.onLoadingPulseAppear()); flush(page);
  assert.equal(page.writes.length, 1); assert.equal(page.loadingPulseMounted, false);
});
test('actual loading bindings and teardown use guarded methods and retain native visual animation', () => {
  assert.match(source, /\.onAppear\(\(\) => \{ this\.onLoadingPulseAppear\(\); \}\)/);
  assert.match(source, /\.onDisAppear\(\(\) => \{ this\.onLoadingPulseDisappear\(\); \}\)/);
  assert.equal((source.match(/this\.loadingBeat\s*=/g) || []).length, 1, 'Only deferred start writes the pulse State');
  assert.match(method('aboutToDisappear'), /this\.panelMounted = false;[\s\S]*this\.onLoadingPulseDisappear\(\)/);
  assert.match(source, /iterations: -1, playMode: PlayMode\.Alternate/);
});
console.log('PASS: ' + passed + ' actual PlayerPage pulse lifecycle groups. Render/clock mocked; no native animation/device/build proof.');
