'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const root = projectFile('entry/src/main/ets/common');
const modules = new Map(), responses = [], requests = [];
function load(file) {
  file = path.resolve(file);
  if (path.basename(file) === 'Dbg.ets') return { Dbg: { setApi() {} } };
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal(result.diagnostics.length, 0);
  const requireForModule = name => name === '@kit.NetworkKit' ? { http: {
    RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'STRING' }, createHttp: () => ({ destroy() {}, request: async (url, options) => {
      requests.push({ url, options }); assert(responses.length, 'Unexpected network call');
      const response = responses.shift(); return { responseCode: response.status || 200, result: JSON.stringify(response.body) };
    } })
  } } : load(path.resolve(path.dirname(file), name + '.ets'));
  vm.runInNewContext(result.outputText, { module, exports: module.exports, require: requireForModule }, { filename: file });
  return module.exports;
}
const { MediaItem, ServerConfig } = load(path.join(root, 'Models.ets'));
const { EmbyClient } = load(path.join(root, 'EmbyClient.ets'));
const indexSource = fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(indexSource);
  assert(match, name); const start = indexSource.indexOf('{', match.index);
  let depth = 1, end = start + 1;
  for (; depth && end < indexSource.length; end++) {
    if (indexSource[end] === '{') depth++;
    else if (indexSource[end] === '}') depth--;
  }
  return indexSource.slice(match.index, end).replace(/^  private /, '  ');
}
const media = { getItems: async () => [], getFavorites: async () => [] };
let gate=async()=>true;
const context = { exports: {}, MediaServices: media,gate:server=>gate(server), Edge: { Top: 'Top' }, promptAction: { showToast() {} } };
const methods = ['openLibrary', 'closeLibrary', 'libraryGenres', 'libraryGenreCount', 'libraryDate',
  'librarySortAvailable', 'chooseLibrarySort', 'refreshLibraryItems', 'selectLibraryMode', 'loadLibraryFavorites',
  'libraryEmptyText', 'librarySortNote'];
const testClass = `class Entry {
  libGeneration=0; libFavoriteGeneration=0; libServer=null; browsingLib=null;
  libItems=[]; libVisibleItems=[]; libHeroItems=[]; libFavoriteIds=[];
  libMode=0; libGenre=''; libHeroIndex=0; libSort=0; libDescending=false;
  libSortOpen=false; libLoading=false; libFavoritesLoading=false; libFavoritesLoaded=false;
  libFavoriteError=''; libError=''; libAmbient=''; libAmbientKey='';
  homeScrollMounted=true;homeScrollPageVisible=true;async serverGate(server){return gate(server)}
  librarySortLabels=['名称','添加时间','上映时间','影片评分','随机'];
  libraryScroller={scrollEdge(){}}; updateLibraryAmbient(){} ensureSubpage(){}
  ${methods.map(method).join('\n')}
} exports.Entry=Entry;`;
const result = ts.transpileModule(testClass, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(result.diagnostics.length, 0); vm.runInNewContext(result.outputText, context);
const Entry = context.exports.Entry;
const item = (id, fields = {}) => Object.assign(new MediaItem(), { id, name: id, type: 'Movie' }, fields);
const ids = items => Array.from(items, value => value.id);
const defer = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const settle=async()=>{for(let index=0;index<12;index++)await Promise.resolve();};

(async () => {
  const server = new ServerConfig('s', 'emby', 'Server', 'example.invalid', 8096, 'u', 'redacted', 'u-id', '', '');
  const defaults = new MediaItem();
  assert.equal(defaults.createdAt, ''); assert.equal(defaults.premiereDate, '');
  assert.equal(defaults.isFavorite, false); assert.equal(defaults.favoriteKnown, false);
  responses.push({ body: { Items: [
    { Id: 'real', Name: 'Real', Type: 'Series', Genres: ['Drama', '', 'Action'], DateCreated: '2026-10-27T01:00:00Z',
      PremiereDate: '2024-02-03T00:00:00Z', ImageTags: { Primary: 'cover' }, BackdropImageTags: ['actual-backdrop'], UserData: { IsFavorite: true } },
    { Id: 'unknown', Name: 'Unknown', Type: 'Movie', Genres: null, DateCreated: 42, PremiereDate: null,
      BackdropImageTags: null, UserData: null }
  ] } });
  const parsed = await EmbyClient.getItems(server, 'lib', 0, 600, false);
  assert.deepEqual(Array.from(parsed[0].genres), ['Drama', 'Action']);
  assert.equal(parsed[0].createdAt, '2026-10-27T01:00:00Z'); assert.equal(parsed[0].premiereDate, '2024-02-03T00:00:00Z');
  assert.equal(parsed[0].backdropTag, 'actual-backdrop'); assert.equal(parsed[0].isFavorite, true); assert.equal(parsed[0].favoriteKnown, true);
  assert.equal(parsed[1].createdAt, ''); assert.equal(parsed[1].premiereDate, '');
  assert.equal(parsed[1].favoriteKnown, false); assert.equal(parsed[1].genres.length, 0);
  for (const field of ['Genres', 'DateCreated', 'PremiereDate', 'Backdrop']) assert(requests.at(-1).url.includes(field));
  responses.push({ status: 404, body: { message: 'not supported' } });
  await assert.rejects(EmbyClient.getFavorites(server, 20), /HTTP 404/);

  const e = new Entry();
  const a = item('a', { createdAt: '2025-01-01T00:00:00Z', premiereDate: '2023-01-01', rating: 8, genres: ['Drama'], type: 'Series' });
  const b = item('b', { createdAt: '2026-01-01T00:00:00Z', premiereDate: '2020-01-01', rating: 6, genres: ['Action'] });
  const c = item('c', { genres: ['Drama', 'Action'] });
  e.libItems = [c, b, a]; e.refreshLibraryItems(); assert.deepEqual(ids(e.libVisibleItems), ['a', 'b', 'c']);
  assert.deepEqual(ids(e.libItems), ['c', 'b', 'a'], 'Sorting must not mutate source data');
  assert.deepEqual(Array.from(e.libraryGenres()), ['Action', 'Drama']); assert.equal(e.libraryGenreCount('Drama'), 2);
  e.libMode = 2; e.libGenre = 'Drama'; e.refreshLibraryItems(); assert.deepEqual(ids(e.libVisibleItems), ['a', 'c']);
  e.libGenre = 'missing'; e.refreshLibraryItems(); assert.equal(e.libVisibleItems.length, 0);
  e.libMode = 1; e.refreshLibraryItems(); assert.deepEqual(ids(e.libVisibleItems), ['a'], 'Only real containers, no manufactured genre folders');
  e.libMode = 0; e.chooseLibrarySort(1); assert.deepEqual(ids(e.libVisibleItems), ['b', 'a', 'c']);
  e.chooseLibrarySort(1); assert.deepEqual(ids(e.libVisibleItems), ['a', 'b', 'c'], 'Missing dates remain last in both directions');
  e.chooseLibrarySort(2); assert.deepEqual(ids(e.libVisibleItems), ['a', 'b', 'c']);
  e.chooseLibrarySort(3); assert.deepEqual(ids(e.libVisibleItems), ['a', 'b', 'c']);
  e.libItems = [item('no-date'), item('invalid-date', { createdAt: '0' })];
  assert.equal(e.librarySortAvailable(1), false); const oldSort = e.libSort; e.chooseLibrarySort(1); assert.equal(e.libSort, oldSort);
  e.libItems = [a, b, c]; e.chooseLibrarySort(4); assert.deepEqual(ids(e.libVisibleItems).sort(), ['a', 'b', 'c']);

  e.libServer = server; e.libMode = 3; e.libFavoriteIds = ['a']; e.libFavoritesLoaded = true;
  media.getFavorites = async () => { throw Error('HTTP 404'); };
  await e.loadLibraryFavorites(); assert.deepEqual(Array.from(e.libFavoriteIds), ['a']); assert(e.libFavoriteError.includes('重试'));
  e.refreshLibraryItems(); assert.deepEqual(ids(e.libVisibleItems), ['a']);
  media.getFavorites = async () => [];
  await e.loadLibraryFavorites(); assert.equal(e.libFavoriteError, ''); assert.equal(e.libVisibleItems.length, 0);

  const pendingA = defer(), pendingB = defer();
  media.getItems = async (s, id) => id === 'A' ? pendingA.promise : pendingB.promise;
  const A = e.openLibrary(server, { id: 'A' });await settle();const B = e.openLibrary(server, { id: 'B' });await settle();
  pendingB.resolve([b]); await B; pendingA.resolve([a]); await A;
  assert.equal(e.browsingLib.id, 'B'); assert.deepEqual(ids(e.libItems), ['b']);
  const pendingClose = defer(); media.getItems = async () => pendingClose.promise;
  const closing = e.openLibrary(server, { id: 'closing' });await settle(); e.closeLibrary(); pendingClose.resolve([c]); await closing;
  assert.equal(e.browsingLib, null); assert.equal(e.libItems.length, 0); assert.equal(e.libLoading, false);
  e.libServer = server; const pendingFavorite = defer(); media.getFavorites = async () => pendingFavorite.promise;
  const favoriteClose = e.loadLibraryFavorites(); e.closeLibrary(); pendingFavorite.resolve([a]); await favoriteClose;
  assert.equal(e.libFavoriteIds.length, 0); assert.equal(e.libFavoritesLoading, false);
  let calls=0;media.getItems=async()=>{calls++;return[a]};gate=async()=>false;
  await e.openLibrary(server,{id:'protected'});assert.equal(calls,0);assert.equal(e.browsingLib,null);
  for(const stop of [page=>page.closeLibrary(),page=>{page.homeScrollPageVisible=false},page=>{page.homeScrollMounted=false}]){
    const page=new Entry(),pending=defer();gate=()=>pending.promise;const opening=page.openLibrary(server,{id:'gated'});
    stop(page);pending.resolve(true);await opening;assert.equal(calls,0);assert.equal(page.browsingLib,null);
  }
  gate=async()=>true;
  console.log('PASS: real metadata/default parsing, backdrop identity, requested fields, unmasked 404, genre membership, real containers, name/rating/date ordering and missing-date guards, random permutation, favorite failure retention, explicit empty result, stale-library/favorite and close cancellation. No real network/device/build calls.');
})().catch(error => { console.error(error); process.exitCode = 1; });
