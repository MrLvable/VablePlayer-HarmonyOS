'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const HeaderLoader = require('./image-loader-fixture.cjs').imageLoader().NetImageLoader;
let reduceMotion = false;
const motionContext = { exports: {}, Curve: { EaseInOut: 'EaseInOut', EaseIn: 'EaseIn', EaseOut: 'EaseOut' },
  AppStorage: { get: () => reduceMotion } };
const motionCode = ts.transpileModule(fs.readFileSync(projectFile('entry/src/main/ets/common/MotionSpec.ets'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
});
vm.runInNewContext(motionCode.outputText, motionContext);
const normalDuration = motionContext.exports.MotionSpec.ambient;
assert(normalDuration >= 700 && normalDuration <= 900, 'ambient transition matches the accepted range');

// Execute the real lifecycle/request methods; ArkUI rendering and animation clocks are mocked.
function componentClass(relative, name, globals = {}) {
  const source = fs.readFileSync(projectFile(relative), 'utf8');
  const start = source.indexOf('export struct ' + name + ' {');
  const end = source.indexOf('\n  build() {', start);
  assert(start >= 0 && end > start, name);
  const body = source.slice(start, end)
    .replace('export struct ' + name, 'class ' + name)
    .replace(/^\s*@(Prop|State)(?:\s+@Watch\('[^']+'\))?\s+/gm, '  ')
    + '\n}\nexports.Component = ' + name + ';';
  const output = ts.transpileModule(body, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    reportDiagnostics: true
  });
  assert.equal(output.diagnostics.length, 0, name + ' syntax');
  const context = { exports: {}, Curve: { EaseInOut: 'EaseInOut' }, ...motionContext.exports, ...globals };
  vm.runInNewContext(output.outputText, context);
  return context.exports.Component;
}

const timers = new Map();
let nextTimer = 0;
const Backdrop = componentClass('entry/src/main/ets/components/LibraryBackdrop.ets', 'LibraryBackdrop', {
  NetImageLoader: HeaderLoader,
  setTimeout: (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
  clearTimeout: id => timers.delete(id)
});
function backdrop(url = 'image-A') {
  const subject = new Backdrop();
  const animations = [];
  subject.getUIContext = () => ({ animateTo(options, body) {
    const record = { options, before: [subject.aOpacity, subject.bOpacity] };
    body();
    record.after = [subject.aOpacity, subject.bOpacity];
    animations.push(record);
  } });
  subject.url = url;
  subject.scopeId = 'test-server:test-user';
  subject.token = 'test-credential';
  subject.authHeader = 'X-Test-Token';
  subject.baseColor = '#111111';
  subject.fallbackColor = '#334455';
  subject.aboutToAppear();
  return { subject, animations };
}
function change(state, url) { state.subject.url = url; state.subject.onSourceChanged(); }
function frame(state) {
  const id = state.subject.fadeStartTimer;
  const timer = timers.get(id);
  assert(timer, 'pending decoded-image mount turn');
  assert.equal(timer.delay, motionContext.exports.MotionSpec.imageReadyFrame);
  timers.delete(id);
  timer.callback();
  return timer;
}
function ready(state, slot, url, runFrame = true) {
  const old = state.subject.fadeStartTimer;
  state.subject.onSlotReady(slot, url);
  if (runFrame && state.subject.fadeStartTimer >= 0 && state.subject.fadeStartTimer !== old) frame(state);
}
function finish(state) {
  const transition = [...state.animations].reverse().find(record => record.options.onFinish && !record.finished);
  assert(transition, 'pending fade');
  transition.finished = true;
  transition.options.onFinish();
  return transition;
}
function activeA() {
  const state = backdrop();
  assert.equal(state.subject.aOpacity, 0, 'decoded readiness is required');
  assert.equal(state.animations.length, 0);
  ready(state, 0, 'image-A');
  const animation = finish(state);
  assert.equal(animation.options.duration, normalDuration);
  assert.equal(animation.options.curve, 'EaseInOut');
  assert.equal(state.subject.activeSlot, 0);
  return state;
}

let groups = 0;
async function test(name, run) { await run(); groups++; console.log('PASS: ' + name); }
async function flush() { for (let n = 0; n < 8; n++) await Promise.resolve(); }

(async () => {
  await test('detail appearance overrides leave existing library defaults intact and bound invalid strengths safely', () => {
    const subject = new Backdrop();
    subject.darkMode = true;
    assert.equal(subject.imageLayerOpacity(), 0.80); assert.equal(subject.baseVeilOpacity(), 0.34);
    subject.darkMode = false;
    assert.equal(subject.imageLayerOpacity(), 0.32); assert.equal(subject.baseVeilOpacity(), 0.72);
    subject.imageStrength = 0.68; subject.baseVeilStrength = 0.46;
    assert.equal(subject.imageLayerOpacity(), 0.68); assert.equal(subject.baseVeilOpacity(), 0.46);
    subject.imageStrength = 4; subject.baseVeilStrength = 3;
    assert.equal(subject.imageLayerOpacity(), 1); assert.equal(subject.baseVeilOpacity(), 1);
    subject.imageStrength = NaN; subject.baseVeilStrength = -1;
    assert.equal(subject.imageLayerOpacity(), 0.32); assert.equal(subject.baseVeilOpacity(), 0.72);
  });
  await test('a same-turn cache-ready notification waits a mounted render turn before any fade', () => {
    const state = backdrop();
    ready(state, 0, 'image-A', false);
    assert.equal(state.subject.aOpacity, 0);
    assert.equal(state.subject.fading, false);
    assert.equal(state.animations.length, 0);
    frame(state);
    assert.equal(state.subject.fading, true);
    finish(state);
  });
  await test('exit/re-entry before deferred fade cancels the timer and rejects a late callback', () => {
    const state = backdrop();
    ready(state, 0, 'image-A', false);
    const id = state.subject.fadeStartTimer;
    const late = timers.get(id).callback;
    state.subject.aboutToDisappear();
    assert.equal(timers.has(id), false);
    state.subject.aboutToAppear();
    late();
    assert.equal(state.subject.aOpacity, 0);
    assert.equal(state.subject.activeSlot, -1);
    assert.equal(state.animations.length, 0);
    ready(state, 0, 'image-A'); finish(state);
  });
  await test('rapid source change during the ready frame cancels stale fade and keeps old image', () => {
    const state = activeA();
    change(state, 'image-B'); ready(state, 1, 'image-B', false);
    const id = state.subject.fadeStartTimer;
    const late = timers.get(id).callback;
    change(state, 'image-C');
    assert.equal(timers.has(id), false);
    ready(state, 1, 'image-C', false);
    const newestTimer = state.subject.fadeStartTimer;
    late();
    assert.equal(state.subject.fadeStartTimer, newestTimer, 'late callback cannot erase the latest cancellation handle');
    assert.equal(timers.has(newestTimer), true);
    assert.equal(state.subject.aOpacity, 1);
    assert.equal(state.subject.bOpacity, 0);
    assert.equal(state.subject.fading, false);
    assert.equal(state.subject.bUrl, 'image-C');
    frame(state); finish(state);
    assert.equal(state.subject.activeSlot, 1);
    assert.equal(state.subject.bUrl, 'image-C');
  });
  await test('retain decoded old image until the hidden incoming image is ready', () => {
    const state = activeA();
    change(state, 'image-B');
    assert.equal(state.subject.aUrl, 'image-A');
    assert.equal(state.subject.aOpacity, 1);
    assert.equal(state.subject.bUrl, 'image-B');
    assert.equal(state.subject.bOpacity, 0);
    assert.equal(state.subject.fading, false);
    ready(state, 1, 'image-B');
    const animation = finish(state);
    assert.deepEqual(animation.before, [1, 0]);
    assert.deepEqual(animation.after, [1, 1], 'opaque old image avoids a midpoint dip');
    assert.equal(state.subject.activeSlot, 1);
    assert.equal(state.subject.aUrl, '');
  });
  await test('reverse slot transition puts decoded image below old opaque layer before fading it out', () => {
    const state = activeA();
    change(state, 'image-B'); ready(state, 1, 'image-B'); finish(state);
    change(state, 'image-C');
    assert.equal(state.subject.bUrl, 'image-B');
    assert.equal(state.subject.bOpacity, 1);
    assert.equal(state.subject.aOpacity, 0);
    ready(state, 0, 'image-C');
    const animation = finish(state);
    assert.deepEqual(animation.before, [1, 1]);
    assert.deepEqual(animation.after, [1, 0]);
    assert.equal(state.subject.activeSlot, 0);
    assert.equal(state.subject.bUrl, '');
  });
  await test('rapid changes while loading ignore old ready/failure and only commit latest URL', () => {
    const state = activeA();
    change(state, 'image-B');
    change(state, 'image-C');
    ready(state, 1, 'image-B');
    state.subject.onSlotFailed(1, 'image-B');
    assert.equal(state.subject.fading, false);
    assert.equal(state.subject.bUrl, 'image-C');
    assert.equal(state.subject.aOpacity, 1);
    ready(state, 1, 'image-C'); finish(state);
    assert.equal(state.subject.bUrl, 'image-C');
  });
  await test('rapid changes while fading coalesce without replacing a visible image', () => {
    const state = activeA();
    change(state, 'image-B'); ready(state, 1, 'image-B');
    change(state, 'image-C'); change(state, 'image-D');
    assert.equal(state.subject.bUrl, 'image-B', 'fading image remains decoded and unchanged');
    assert.equal(state.subject.aUrl, 'image-A');
    finish(state);
    assert.equal(state.subject.activeSlot, 1);
    assert.equal(state.subject.aUrl, 'image-D', 'intermediate C never gets loaded');
    assert.equal(state.subject.aOpacity, 0);
    ready(state, 0, 'image-C');
    assert.equal(state.subject.fading, false);
    ready(state, 0, 'image-D'); finish(state);
    assert.equal(state.subject.aUrl, 'image-D');
  });
  await test('incoming failure retains old image; same active request cancels a pending replacement', () => {
    const state = activeA();
    change(state, 'image-B'); state.subject.onSlotFailed(1, 'image-B');
    assert.equal(state.subject.activeSlot, 0);
    assert.equal(state.subject.aUrl, 'image-A');
    assert.equal(state.subject.aOpacity, 1);
    assert.equal(state.subject.bUrl, '');
    change(state, 'image-C'); change(state, 'image-A');
    assert.equal(state.subject.loadingSlot, -1);
    ready(state, 1, 'image-C');
    assert.equal(state.subject.activeSlot, 0);
    assert.equal(state.subject.fading, false);
  });
  await test('empty source, account change and teardown invalidate old completions', () => {
    const state = activeA();
    change(state, 'image-B'); ready(state, 1, 'image-B');
    state.subject.scopeId = 'other-server:other-user';
    state.subject.token = 'other-test-credential';
    state.subject.onSourceChanged();
    finish(state); // old onFinish must not commit into the new account.
    assert.equal(state.subject.activeSlot, -1);
    assert.equal(state.subject.aUrl, 'image-B');
    assert.equal(state.subject.aOpacity, 0);
    ready(state, 1, 'image-B');
    assert.equal(state.subject.fading, false);
    change(state, '');
    assert.equal(state.subject.aUrl, '');
    assert.equal(state.subject.bUrl, '');
    change(state, 'image-C'); ready(state, 0, 'image-C');
    state.subject.aboutToDisappear();
    finish(state);
    ready(state, 0, 'image-C');
    assert.equal(state.subject.activeSlot, -1);
    assert.equal(state.subject.aUrl, '');
    assert.equal(state.subject.fading, false);
    state.subject.aboutToAppear();
    assert.equal(state.subject.aUrl, 'image-C');
    assert.equal(state.subject.aOpacity, 0);
  });
  await test('generic header changes reset private layers and retain independent slot snapshots', () => {
    const state = activeA();
    const headers = { 'X-Plex-Token': 'plex-before' };
    state.subject.headers = headers;
    state.subject.onSourceChanged();
    assert.equal(state.subject.activeSlot, -1);
    assert.equal(state.subject.aOpacity, 0);
    assert.equal(state.subject.aHeaders['X-Plex-Token'], 'plex-before');
    assert.equal(state.subject.aHeaders['X-Emby-Token'], undefined);
    headers['X-Plex-Token'] = 'plex-after';
    assert.equal(state.subject.aHeaders['X-Plex-Token'], 'plex-before');
    const generation = state.subject.requestGeneration;
    state.subject.headers = { 'x-plex-token': 'plex-before' };
    state.subject.onSourceChanged();
    assert.equal(state.subject.requestGeneration, generation);
    assert(!state.subject.scopeKey.includes('plex-before'));
    state.subject.aboutToDisappear();
  });
  await test('fallback color changes use MotionSpec easing without image request churn', () => {
    const state = activeA();
    const request = state.subject.requestGeneration;
    state.subject.fallbackColor = '#556677';
    state.subject.onAppearanceChanged();
    const record = state.animations.at(-1);
    assert.equal(record.options.duration, normalDuration);
    assert.equal(record.options.curve, 'EaseInOut');
    assert.equal(state.subject.currentFallback, '#556677');
    assert.equal(state.subject.requestGeneration, request);
    assert.equal(state.subject.aUrl, 'image-A');
  });
  await test('ReducedMotion shortens fade while still retaining old image until decode-ready', () => {
    reduceMotion = true;
    const state = backdrop();
    assert.equal(state.subject.aOpacity, 0);
    assert.equal(state.animations.length, 0);
    ready(state, 0, 'image-A');
    const animation = finish(state);
    assert.equal(animation.options.duration, motionContext.exports.MotionPref.dur(normalDuration));
    assert(animation.options.duration < normalDuration);
    change(state, 'image-B');
    assert.equal(state.subject.aOpacity, 1);
    assert.equal(state.subject.bOpacity, 0);
    assert.equal(state.subject.fading, false);
    reduceMotion = false;
  });

  const pending = [];
  const cache = new Map();
  const loader = { cacheKey: HeaderLoader.cacheKey, effectiveHeaders: HeaderLoader.effectiveHeaders,
    cached: key => cache.get(key), load: (...args) => new Promise(resolve => pending.push({ args, resolve })) };
  const leases = { acquire() {}, releaseKey() {} };
  const NetImage = componentClass('entry/src/main/ets/components/NetImage.ets', 'NetImage', {
    NetImageLoader: loader, ImageCache: leases, ImageFit: { Cover: 2, Contain: 0 }
  });
  function image() {
    pending.length = 0; cache.clear();
    const subject = new NetImage();
    subject.url = 'image-A'; subject.token = 'test-credential';
    const ready = [], failed = [];
    subject.onImageReady = url => ready.push(url);
    subject.onFail = url => failed.push(url);
    return { subject, ready, failed };
  }
  await test('NetImage notifies only after real decode success or a valid PixelMap cache hit', async () => {
    const state = image();
    state.subject.startLoad();
    assert.equal(state.ready.length, 0);
    pending[0].resolve({ decoded: true }); await flush();
    assert.deepEqual(state.ready, ['image-A']);
    assert.equal(state.failed.length, 0);
    const cached = image();
    cache.set(cached.subject.requestKey(), { decoded: true });
    cached.subject.startLoad();
    assert.deepEqual(cached.ready, ['image-A']);
    assert.equal(pending.length, 0);
  });
  await test('NetImage stale A→B→A decode cannot notify even when the URL repeats', async () => {
    const state = image();
    state.subject.startLoad();
    state.subject.url = 'image-B'; state.subject.startLoad();
    state.subject.url = 'image-A'; state.subject.startLoad();
    pending[0].resolve({ decoded: 'old-A' });
    pending[1].resolve({ decoded: 'old-B' }); await flush();
    assert.equal(state.ready.length, 0);
    pending[2].resolve({ decoded: 'latest-A' }); await flush();
    assert.deepEqual(state.ready, ['image-A']);
    assert.equal(state.subject.pix.decoded, 'latest-A');
  });
  await test('NetImage failure and teardown never report a ready image; consumer callback errors stay isolated', async () => {
    const failed = image(); failed.subject.startLoad();
    pending[0].resolve(undefined); await flush();
    assert.equal(failed.ready.length, 0);
    assert.deepEqual(failed.failed, ['image-A']);
    const gone = image(); gone.subject.startLoad();
    gone.subject.aboutToDisappear();
    pending[0].resolve({ decoded: true }); await flush();
    assert.equal(gone.ready.length, 0);
    const throwing = image();
    throwing.subject.onImageReady = () => { throw new Error('test consumer'); };
    throwing.subject.startLoad(); pending[0].resolve({ decoded: true }); await flush();
    assert.equal(throwing.subject.failed, false);
    assert.equal(throwing.failed.length, 0);
  });
  console.log(`PASS: ${groups} lifecycle groups. Real component methods; no device/network/build, pixel or timing claim.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
