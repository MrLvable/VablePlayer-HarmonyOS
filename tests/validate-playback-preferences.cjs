'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const text = fs.readFileSync(projectFile('entry/src/main/ets/common/PlaybackPreferences.ets'), 'utf8');
const out = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(out.diagnostics.length, 0);
const plain = value => JSON.parse(JSON.stringify(value));
const defaults = { autoNext: true, doubleTapPause: true, ratio: '默认', subtitleScale: 1 };
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const turn = () => new Promise(resolve => setImmediate(resolve));
function fixture(initial = '{}') {
  let saved = initial, read = async () => saved, write = async (_key, value) => { saved = value; };
  const calls = [], context = { exports: {}, require(name) { assert.equal(name, './Store'); return { Store: {
    async get(key, fallback) { assert.equal(key, 'playback_preferences_v1'); assert.equal(fallback, '{}'); return read(); },
    async set(key, value) { calls.push({ key, value }); await write(key, value); }
  } }; } };
  vm.runInNewContext(out.outputText, context);
  return { P: context.exports.PlaybackPreferences, calls, set read(fn) { read = fn; }, set write(fn) { write = fn; }, get saved() { return saved; } };
}
let count = 0; async function test(name, run) { await run(); count++; console.log('PASS: ' + name); }
(async () => {
  await test('actual defaults and valid stored values load as independent copies', async () => {
    const f = fixture(); assert.deepEqual(plain(f.P.current()), defaults); assert.deepEqual(plain(await f.P.load()), defaults);
    for (const ratio of ['默认', '平铺', '拉伸', '裁切', '16:9', '4:3', '原始像素比例']) {
      for (const subtitleScale of [.8, 1, 1.25, 1.5]) {
        const value = { autoNext: false, doubleTapPause: false, ratio, subtitleScale };
        const loaded = fixture(JSON.stringify(value)); const result = await loaded.P.load(); assert.deepEqual(plain(result), value);
        result.ratio = 'modified'; const current = loaded.P.current(); current.subtitleScale = 999;
        assert.deepEqual(plain(loaded.P.current()), value);
      }
    }
  });
  await test('malformed, null, primitive and invalid stored fields use documented defaults', async () => {
    for (const raw of ['invalid-json', 'null', '[]', '42', '"string"', JSON.stringify({ autoNext: 1, doubleTapPause: 'false', ratio: 'invalid', subtitleScale: 2 })]) {
      const f = fixture(raw); assert.deepEqual(plain(await f.P.load()), defaults);
    }
    const f = fixture(JSON.stringify({ autoNext: false, ratio: '4:3', subtitleScale: '1.25', extra: 'ignored' }));
    assert.deepEqual(plain(await f.P.load()), { ...defaults, autoNext: false, ratio: '4:3' });
    f.read = async () => { throw Error('read failure'); }; await f.P.load(); assert.deepEqual(plain(f.P.current()), defaults);
  });
  await test('save rejects incomplete/invalid input before Store and persists only four whitelisted fields', async () => {
    const f = fixture();
    for (const value of [null, undefined, {}, { ...defaults, autoNext: 1 }, { ...defaults, doubleTapPause: 'true' }, { ...defaults, ratio: '999:1' }, { ...defaults, subtitleScale: NaN }, { ...defaults, subtitleScale: Infinity }, { ...defaults, subtitleScale: '1' }]) {
      await assert.rejects(f.P.save(value), /播放设置无效/);
    }
    assert.equal(f.calls.length, 0); assert.deepEqual(plain(f.P.current()), defaults);
    const next = { ...defaults, ratio: '平铺', unknown: 'must-not-save', toJSON() { throw Error('custom serializer must not run'); } };
    await f.P.save(next); assert.deepEqual(JSON.parse(f.saved), { ...defaults, ratio: '平铺' }); assert(!f.saved.includes('must-not-save'));
    assert.deepEqual(Object.keys(JSON.parse(f.saved)).sort(), Object.keys(defaults).sort());
  });
  await test('a failed save leaves the last accepted value and does not poison later writes', async () => {
    const f = fixture(); await f.P.save({ ...defaults, ratio: '4:3' });
    f.write = async () => { throw Error('disk full'); };
    await assert.rejects(f.P.save({ ...defaults, ratio: '拉伸' }), /disk full/); assert.equal(f.P.current().ratio, '4:3');
    f.write = async () => {};
    await f.P.save({ ...defaults, ratio: '16:9' }); assert.equal(f.P.current().ratio, '16:9');
  });
  await test('writes serialize, commit only after Store success and isolate queued inputs/current snapshots', async () => {
    const f = fixture(), first = deferred(), second = deferred(); let active = 0, maximum = 0;
    f.write = async () => { active++; maximum = Math.max(maximum, active); await (f.calls.length === 1 ? first.promise : second.promise); active--; };
    const input = { ...defaults, ratio: '平铺' }, a = f.P.save(input); input.ratio = 'invalid-after-call';
    const b = f.P.save({ ...defaults, autoNext: false, ratio: '裁切' }); await turn();
    assert.equal(f.calls.length, 1); assert.deepEqual(plain(f.P.current()), defaults);
    first.resolve(); await a; await turn(); assert.equal(f.calls.length, 2); assert.equal(f.P.current().ratio, '平铺');
    assert.equal(JSON.parse(f.calls[0].value).ratio, '平铺'); second.resolve(); await b;
    assert.equal(maximum, 1); assert.equal(f.P.current().ratio, '裁切'); assert.equal(f.P.current().autoNext, false);
    const escaped = f.P.current(); escaped.autoNext = true; assert.equal(f.P.current().autoNext, false);
  });
  await test('late reads cannot overwrite newer saves, and loads wait for pending writes', async () => {
    const f = fixture(), read = deferred(); f.read = () => read.promise;
    const loading = f.P.load(); await turn(); await f.P.save({ ...defaults, ratio: '4:3' });
    read.resolve(JSON.stringify(defaults)); const result = await loading; assert.equal(result.ratio, '4:3'); assert.equal(f.P.current().ratio, '4:3');
    const g = fixture(), gate = deferred(); let reads = 0, stored = '{}';
    g.write = async (_key, value) => { await gate.promise; stored = value; }; g.read = async () => { reads++; return stored; };
    const saving = g.P.save({ ...defaults, subtitleScale: 1.5 }); await turn(); const waiting = g.P.load(); await turn(); assert.equal(reads, 0);
    gate.resolve(); await saving; assert.equal((await waiting).subtitleScale, 1.5); assert.equal(reads, 1);
  });
  console.log('PASS: ' + count + ' actual PlaybackPreferences groups: defaults/validation/whitelist/failure/serialization/copy isolation/read-write races. Store is a bounded memory/deferred I/O mock; no device/build.');
})().catch(error => { console.error(error); process.exitCode = 1; });
