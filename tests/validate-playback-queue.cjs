'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const root = projectFile('entry/src/main/ets/common');
const modules = new Map(), requests = [], responses = [];
const service = {};
function load(file) {
  file = path.resolve(file);
  if (path.basename(file) === 'MediaServices.ets') return { MediaServices: service };
  if (path.basename(file) === 'Dbg.ets') return { Dbg: { setApi() {} } };
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal(result.diagnostics.length, 0, file);
  const requireForModule = name => name === '@kit.NetworkKit' ? { http: {
    RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'STRING' },
    createHttp: () => ({ destroy() {}, request: async (url, options) => {
      requests.push({ url, options }); assert(responses.length, 'Unexpected HTTP call');
      return { responseCode: 200, result: JSON.stringify(responses.shift()) };
    } })
  } } : load(path.resolve(path.dirname(file), name + '.ets'));
  vm.runInNewContext(result.outputText, { module, exports: module.exports, require: requireForModule }, { filename: file });
  return module.exports;
}
const { MediaItem, ServerConfig } = load(path.join(root, 'Models.ets'));
const { PlaybackQueueResolver: resolver } = load(path.join(root, 'PlaybackQueueResolver.ets'));
const { EmbyClient } = load(path.join(root, 'EmbyClient.ets'));
const server = new ServerConfig('server', 'fnos', 'NAS', 'example.invalid', 8005, 'u', 'redacted', 'user', '', '');
const episode = (id, season, index, extra = {}) => Object.assign(new MediaItem(), {
  id, name: 'Title must not determine order ' + id, type: 'Episode', seriesId: 'series',
  parentIndexNumber: season, indexNumber: index, ...extra
});
const season = (id, index, extra = {}) => Object.assign(new MediaItem(), { id, name: 'Season', type: 'Season', indexNumber: index, ...extra });
const ids = items => Array.from(items, item => item.id);
const calls = [];
let seasons = [], bySeason = new Map(), flat = [], fresh = null;
function reset() {
  calls.length = 0; seasons = []; bySeason = new Map(); flat = []; fresh = null;
  service.getSeasons = async (s, series) => { calls.push(['seasons', s.id, series]); return seasons; };
  service.getEpisodes = async (s, series, id) => {
    calls.push(['episodes', s.id, series, id]); const value = id === '' ? flat : bySeason.get(id);
    if (value instanceof Error) throw value;
    return value || [];
  };
  service.getItemDetail = async (s, id) => { calls.push(['detail', s.id, id]); if (fresh instanceof Error) throw fresh; return { item: fresh }; };
}
const rejectsCode = (promise, code) => assert.rejects(promise, error => error && error.code === code && error.message.length > 0);

(async () => {
  // The transport must omit the optional season parameter, not send an empty Guid/string.
  responses.push({ Items: [{ Id: 'special', Type: 'Episode', SeriesId: 'series', IndexNumber: 0, ParentIndexNumber: 0 }] });
  const zero = (await EmbyClient.getEpisodes(server, 'series', ''))[0];
  assert.equal(new URL(requests.at(-1).url).searchParams.has('SeasonId'), false);
  assert.equal(zero.indexNumberKnown, true); assert.equal(zero.parentIndexNumberKnown, true);
  responses.push({ Items: [{ Id: 'missing', Type: 'Episode' }] });
  const unknown = (await EmbyClient.getEpisodes(server, 'series', 'season-1'))[0];
  assert.equal(new URL(requests.at(-1).url).searchParams.get('SeasonId'), 'season-1');
  assert.equal(unknown.indexNumberKnown, false); assert.equal(unknown.parentIndexNumberKnown, false);

  // Compatibility servers may cap a request without an explicit Limit. Complete the declared total.
  const dto = index => ({ Id: 'paged-' + index, Type: 'Episode', SeriesId: 'series', ParentIndexNumber: 1, IndexNumber: index });
  const beforePaging = requests.length;
  responses.push({ TotalRecordCount: 5, Items: [dto(1), dto(2)] },
    { TotalRecordCount: 5, Items: [dto(3), dto(4)] }, { TotalRecordCount: 5, Items: [dto(5)] });
  assert.deepEqual(ids(await EmbyClient.getEpisodes(server, 'series', 'season-1')),
    ['paged-1', 'paged-2', 'paged-3', 'paged-4', 'paged-5']);
  assert.equal(requests.length - beforePaging, 3);
  assert.equal(new URL(requests[beforePaging].url).searchParams.has('Limit'), false);
  assert.equal(new URL(requests[beforePaging + 1].url).searchParams.get('StartIndex'), '2');
  assert.equal(new URL(requests[beforePaging + 1].url).searchParams.get('Limit'), '200');
  assert.equal(new URL(requests[beforePaging + 2].url).searchParams.get('StartIndex'), '4');
  responses.push({ TotalRecordCount: '3', Items: [dto(1)] }, { TotalRecordCount: '3', Items: [dto(2), dto(3)] });
  assert.equal((await EmbyClient.getEpisodes(server, 'series', '')).length, 3);
  responses.push({ TotalRecordCount: 4, Items: [dto(1), dto(2)] }, { TotalRecordCount: 4, Items: [] });
  await assert.rejects(EmbyClient.getEpisodes(server, 'series', 'season-1'), /空页/);
  responses.push({ TotalRecordCount: 4, Items: [dto(1), dto(2)] }, { TotalRecordCount: 4, Items: [dto(1), dto(2)] });
  await assert.rejects(EmbyClient.getEpisodes(server, 'series', 'season-1'), /重复/);
  responses.push({ TotalRecordCount: 4, Items: [dto(1), dto(2)] }, { TotalRecordCount: 4, Items: [dto(2), dto(3)] });
  await assert.rejects(EmbyClient.getEpisodes(server, 'series', 'season-1'), /重复/);
  responses.push({ TotalRecordCount: 4, Items: [] });
  await assert.rejects(EmbyClient.getEpisodes(server, 'series', 'season-1'), /空页/);
  responses.push({ TotalRecordCount: 4, Items: [dto(1), dto(2)] }, { TotalRecordCount: 5, Items: [dto(3), dto(4)] });
  await assert.rejects(EmbyClient.getEpisodes(server, 'series', 'season-1'), /变化/);
  responses.push({ TotalRecordCount: 5001, Items: [dto(1)] });
  await assert.rejects(EmbyClient.getEpisodes(server, 'series', 'season-1'), /5000/);
  assert.equal(responses.length, 0);

  reset(); seasons = [season('s2', 2), season('s1', 1)];
  const one = episode('one', 1, 1), two = episode('two', 1, 2), three = episode('three', 2, 1);
  bySeason.set('s1', [two, one, two]); bySeason.set('s2', [three]);
  const seedOnly = episode('stale-seed-only', 1, 3);
  const seed = [episode('two', 1, 2, { overview: 'real cached synopsis' }), seedOnly,
    episode('wrong-series', 1, 3, { seriesId: 'different' })];
  const queue = await resolver.resolve(server, one, seed);
  assert.deepEqual(ids(queue), ['one', 'two', 'three']); assert.equal(queue[1].overview, 'real cached synopsis');
  assert.equal(queue[2].parentIndexNumber, 2); assert.equal(seed.length, 3);
  assert.notEqual(queue[0], one); assert.equal(calls.filter(call => call[0] === 'detail').length, 0);

  // Home resume with no supplied episode list still fetches the complete series.
  const homeQueue = await resolver.resolve(server, two, []);
  assert.deepEqual(ids(homeQueue), ['one', 'two', 'three']);
  assert.equal(homeQueue[homeQueue.findIndex(item => item.id === two.id) + 1].id, 'three');

  // The scoped season response can supply a missing parent number without mutating the response.
  reset(); seasons = [season('s1', 1)];
  const withoutParent = episode('two', 0, 2); bySeason.set('s1', [one, withoutParent]);
  const scoped = await resolver.resolve(server, one, []);
  assert.equal(scoped[1].parentIndexNumber, 1); assert.equal(scoped[1].parentIndexNumberKnown, true);
  assert.equal(withoutParent.parentIndexNumber, 0);

  // A provider without a season endpoint may expose the standard whole-series endpoint instead.
  reset(); service.getSeasons = async () => { throw Error('404'); }; flat = [three, two, one];
  assert.deepEqual(ids(await resolver.resolve(server, one, [])), ['one', 'two', 'three']);
  reset(); seasons = [season('s1', 1), season('s2', 2)]; bySeason.set('s1', [one, two]); bySeason.set('s2', Error('offline'));
  flat = Error('offline'); await rejectsCode(resolver.resolve(server, one, [one, two]), 'queue-load');
  flat = [three, one, two]; assert.deepEqual(ids(await resolver.resolve(server, one, [])), ['one', 'two', 'three']);

  // Foreign items and types never leak into a queue; a missing current is never injected from seed.
  reset(); flat = [one, two, Object.assign(new MediaItem(), { id: 'movie', type: 'Movie' }),
    episode('foreign', 1, 3, { seriesId: 'other' })];
  assert.deepEqual(ids(await resolver.resolve(server, one, [])), ['one', 'two']);
  flat = [two]; await rejectsCode(resolver.resolve(server, one, [one, two]), 'current-missing');
  flat = [one, episode('unknown-number', 1, 0, { name: '第3集' })];
  await rejectsCode(resolver.resolve(server, one, []), 'unknown-order');
  flat = [one, episode('different-id-same-number', 1, 1)];
  await rejectsCode(resolver.resolve(server, one, []), 'ambiguous-version');
  flat = [one, two, episode('two', 1, 3)]; await rejectsCode(resolver.resolve(server, one, []), 'conflicting-order');
  flat = [episode('one', 1, 2)]; await rejectsCode(resolver.resolve(server, one, []), 'current-order-conflict');

  // Missing current metadata is refreshed. Real season/episode zero is accepted only with known flags.
  reset(); const unindexed = episode('one', 0, 0); fresh = one; flat = [one, two];
  assert.deepEqual(ids(await resolver.resolve(server, unindexed, [])), ['one', 'two']);
  assert(calls.some(call => call[0] === 'detail'));
  fresh = episode('one', 0, 0, { name: 'S01E01' });
  await rejectsCode(resolver.resolve(server, unindexed, []), 'unknown-current-order');
  fresh = episode('different', 1, 1); await rejectsCode(resolver.resolve(server, unindexed, []), 'identity-changed');
  fresh = Error('offline'); await rejectsCode(resolver.resolve(server, unindexed, []), 'current-load');
  reset(); seasons = [season('specials', 0, { indexNumberKnown: true })];
  const special = episode('special', 0, 0, { indexNumberKnown: true, parentIndexNumberKnown: true });
  bySeason.set('specials', [special, episode('special-1', 0, 1, { parentIndexNumberKnown: true })]);
  assert.deepEqual(ids(await resolver.resolve(server, special, [])), ['special', 'special-1']);

  // Bounded parallel season loading and numeric cross-season order.
  reset(); seasons = Array.from({ length: 7 }, (_, i) => season('s' + (i + 1), i + 1));
  let active = 0, maxActive = 0;
  service.getEpisodes = async (s, series, id) => {
    active++; maxActive = Math.max(maxActive, active); await Promise.resolve(); active--;
    const n = Number(id.slice(1)); return [episode('e' + n, n, 1)];
  };
  assert.deepEqual(ids(await resolver.resolve(server, episode('e1', 1, 1), [])), ['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7']);
  assert(maxActive <= 3); assert(maxActive > 1);
  reset(); flat = Array.from({ length: 5001 }, (_, i) => episode('e' + i, 1, i + 1));
  await rejectsCode(resolver.resolve(server, flat[0], []), 'too-many');

  reset(); await rejectsCode(resolver.resolve(Object.assign({}, server, { kind: 'local' }), one, []), 'unsupported');
  await rejectsCode(resolver.resolve(server, Object.assign(new MediaItem(), { id: 'movie', type: 'Movie' }), []), 'not-episode');
  await rejectsCode(resolver.resolve(server, episode('missing-series', 1, 1, { seriesId: '' }), []), 'not-episode');
  assert.equal(calls.length, 0, 'Unsupported identity must not issue requests');
  console.log('PASS: omitted SeasonId and declared-total pagination; truncated/short/string-total pages, offset progression, empty/repeated/overlapping pages and changed-total rejection; known-zero vs missing-index parsing; empty-seed home resume; complete multi-season order/cross-season adjacency; dedup; real scope and current presence; strict unknown/conflicting/version metadata; fresh-current recovery; all-series fallback and partial-failure rejection; concurrency/size bounds; unsupported identities. No device, real network or build calls.');
})().catch(error => { console.error(error); process.exitCode = 1; });
