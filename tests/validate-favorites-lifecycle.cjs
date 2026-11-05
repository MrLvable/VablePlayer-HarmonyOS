'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const { SourceIdentity } = require('./image-loader-fixture.cjs');
const source = fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'), 'utf8');
function block(start) { let depth = 1, end = start + 1; for (; depth; end++) {
  if (source[end] === '{') depth++; else if (source[end] === '}') depth--;
} return source.slice(start, end); }
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source); assert(match, name);
  const start = source.indexOf('{', match.index);
  return source.slice(match.index, start).replace('private ', '') + block(start);
}
const dockAt = source.indexOf('.onChange((index: number) => {', source.indexOf('  hdsDock()'));
assert(dockAt >= 0);
const dockChange = 'onDockChange(index: number) ' + block(source.indexOf('{', dockAt));
const methods = ['favoriteAccountScope', 'syncFavoritesScope', 'onCurrentServerChanged', 'visibleFavorites',
  'favoritesRequestCurrent', 'loadFavorites', 'selectTab', 'selectServer', 'toggleCurrentFavorite'];
const code = `class Subject {
 current=null; currentTab=0; favorites=[]; favoritesScope=''; favoritesGeneration=0; favoritesLoading=false; favoritesError='';
 favoriteMutationPending=false; detailItem=null; visionTab=0; tabCtl={changeIndex(){}};serverSelectionGeneration=0;
 homeScrollMounted=true;homeScrollPageVisible=true;libraryLoads=[];
 async serverGate(server,action){return gate(server,action)}
 applyAmbient(){} stopHeroTimer(){} loadLibraries(){this.libraryLoads.push(this.current);return Promise.resolve();} loadVision(){}
 ${methods.map(method).join('\n')} ${dockChange}
} exports.Subject=Subject;`;
const result = ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(result.diagnostics.length, 0);
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
const queue = [], requests = [], mutations = [], toasts = [];
let lookup = async () => ({ item: { favoriteKnown: true, isFavorite: true } }),gate=async()=>true;
const context = { exports: {}, SourceIdentity,gate:(...args)=>gate(...args),
  MediaServices: {
    getFavorites(server) { const pending = deferred(); queue.push(pending); requests.push(server); return pending.promise; },
    getItemDetail(server, id) { return lookup(server, id); },
    async addFavorite(server, id) { mutations.push(['add', server.id, id]); },
    async removeFavorite(server, id) { mutations.push(['remove', server.id, id]); }
  }, Store: { async setLastId() {} }, Ambient: { reset() {} }, hilog: { info() {} },
  promptAction: { showToast(value) { toasts.push(value.message); } }
};
vm.runInNewContext(result.outputText, context);
const Subject = context.exports.Subject;
const server = (overrides = {}) => ({ id: 'A', userId: 'account-A', kind: 'fnos', host: '192.0.2.8', port: 8005, username: 'fixture',
  connectionMode:'direct',scheme:'http',basePath:'',rootPath:'/',shareName:'',sourceUrl:'',domain:'',authMode:'password',token:'',...overrides });
const flush = async () => { for (let index = 0; index < 10; index++) await Promise.resolve(); };
function fixture() {
  queue.length = 0; requests.length = 0; mutations.length = 0; toasts.length = 0;
  lookup = async () => ({ item: { favoriteKnown: true, isFavorite: true } });
  gate=async()=>true;
  const page = new Subject(); let selected = null;
  // Model the actual @Watch handler for every server assignment, including login/edit paths.
  Object.defineProperty(page, 'current', { get() { return selected; }, set(value) { selected = value; this.onCurrentServerChanged(); } });
  page.current = server(); return page;
}
let passed = 0;
async function test(name, body) { await body(); passed++; console.log('PASS ' + name); }
(async () => {
  await test('late response from another server cannot overwrite fresh favorites; active account change reloads', async () => {
    const page = fixture(); const old = page.loadFavorites(); page.currentTab = 2;
    await page.selectServer(server({ id: 'B', userId: 'account-B' }));
    assert.equal(requests.length, 2); assert.equal(page.visibleFavorites().length, 0);
    queue[1].resolve([{ id: 'B-favorite' }]); await flush(); queue[0].resolve([{ id: 'A-favorite' }]); await old;
    assert.equal(page.favorites[0].id, 'B-favorite'); assert.equal(page.favoritesLoading, false);
  });
  await test('same server ID with changed account or address has an isolated scope; stale failure cannot clear fresh items', async () => {
    const page = fixture(); const old = page.loadFavorites(); page.currentTab = 2;
    page.current = server({ userId: 'account-B' }); queue[1].resolve([{ id: 'account-B-favorite' }]); await flush();
    queue[0].reject(Error('stale')); await old; assert.equal(page.favorites[0].id, 'account-B-favorite'); assert.equal(page.favoritesError, '');
    page.current = server({ userId: 'account-B', host: '192.0.2.9' });
    assert.equal(page.visibleFavorites().length, 0); assert.equal(requests.length, 3);
    queue[2].resolve([]); await flush();
  });
  await test('same-host scheme, proxy path, file root, share and subscription changes cannot early-return or reuse old favorites',async()=>{
    for(const change of [{scheme:'https'},{basePath:'/new-proxy'},{rootPath:'/new-files'},{shareName:'new-share'},{sourceUrl:'https://playlist.invalid/new.m3u'}]){
      const page=fixture(),oldScope=page.favoriteAccountScope(page.current),old=page.loadFavorites();page.currentTab=2;
      const next=server(change);await page.selectServer(next);
      assert.equal(page.current,next);assert.notEqual(page.favoriteAccountScope(page.current),oldScope);
      assert.equal(page.libraryLoads.length,1,'A same-host endpoint/root change reloads the actual selected source');
      assert.equal(requests.length,2);assert.equal(page.visibleFavorites().length,0);
      queue[1].resolve([{id:'new-scope'}]);await flush();queue[0].resolve([{id:'old-scope'}]);await old;
      assert.equal(page.favorites[0].id,'new-scope');
    }
    const page=fixture();await page.selectServer(server());assert.equal(page.libraryLoads.length,0,'Only an actually identical identity may skip switching');
    gate=async()=>false;await page.selectServer(server({id:'blocked'}));assert.equal(page.current.id,'A');assert.equal(page.libraryLoads.length,0);
  });
  await test('same-tab dock callbacks and concurrent requests deduplicate; deliberate re-entry refreshes without clearing', async () => {
    const page = fixture(); page.selectTab(2); page.onDockChange(2); page.selectTab(2); await page.loadFavorites();
    assert.equal(requests.length, 1); queue[0].resolve([{ id: 'kept' }]); await flush();
    page.selectTab(0); page.selectTab(2); assert.equal(requests.length, 2);
    assert.equal(page.favorites[0].id, 'kept'); queue[1].resolve([{ id: 'refreshed' }]); await flush();
    assert.equal(page.favorites[0].id, 'refreshed');
  });
  await test('forced newer refresh rejects old success/failure and only the current request owns loading', async () => {
    const page = fixture(), old = page.loadFavorites(), fresh = page.loadFavorites(true);
    queue[1].resolve([{ id: 'new' }]); await fresh; queue[0].reject(Error('old failure')); await old;
    assert.equal(page.favorites[0].id, 'new'); assert.equal(page.favoritesError, ''); assert.equal(page.favoritesLoading, false);
  });
  await test('current network failure retains confirmed items and exposes retry status instead of fake empty state', async () => {
    const page = fixture(); const first = page.loadFavorites(); queue[0].resolve([{ id: 'kept' }]); await first;
    const refresh = page.loadFavorites(); queue[1].reject(Error('offline')); await refresh;
    assert.equal(page.favorites[0].id, 'kept'); assert.ok(page.favoritesError.length > 0); assert.equal(page.favoritesLoading, false);
    const retry = page.loadFavorites(true); assert.equal(page.favorites[0].id, 'kept'); assert.equal(page.favoritesError, '');
    queue[2].resolve([{ id: 'retried' }]); await retry; assert.equal(page.favorites[0].id, 'retried');
  });
  await test('disconnect hides old account data immediately and ignores its late completion', async () => {
    const page = fixture(), pending = page.loadFavorites(); page.favorites = [{ id: 'old' }]; page.current = null;
    assert.equal(page.visibleFavorites().length, 0); queue[0].resolve([{ id: 'late' }]); await pending;
    assert.equal(page.favorites.length, 0); assert.equal(page.favoritesLoading, false);
  });
  await test('favorite mutation uses confirmed metadata rather than an unloaded or partial favorites list', async () => {
    const page = fixture(); page.detailItem = { id: 'item', favoriteKnown: true, isFavorite: true };
    await page.toggleCurrentFavorite(); assert.deepEqual(mutations[0], ['remove', 'A', 'item']);
    assert.equal(page.detailItem.isFavorite, false); queue[0].resolve([]); await flush();
    const pending = deferred(); lookup = () => pending.promise;
    page.detailItem = { id: 'unknown', favoriteKnown: false, isFavorite: false };
    const first = page.toggleCurrentFavorite(); await page.toggleCurrentFavorite();
    pending.resolve({ item: { favoriteKnown: false, isFavorite: false } }); await first;
    assert.equal(mutations.length, 1, 'Unknown state and repeated clicks cannot issue a blind add');
  });
  await test('favorites builder stays bound to favorites while backgrounded and exposes actual loading/error controls', async () => {
    assert.match(source, /@State\s+@Watch\('onCurrentServerChanged'\)\s+current:/);
    const body = method('gridView'); assert.ok(!body.includes('this.allItems()')); assert.ok(!body.includes('this.currentTab'));
    assert.match(body, /this\.visibleFavorites\(\)/); assert.match(body, /this\.favoritesError/);
    assert.match(body, /loadFavorites\(true\)/); assert.match(body, /this\.favoritesLoading/);
  });
  console.log('PASS: ' + passed + ' actual Index lifecycle groups. ArkUI/requests mocked; no app build, device or crash-root-cause claim.');
})().catch(error => { console.error(error); process.exitCode = 1; });
