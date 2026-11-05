'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const root = projectFile('entry/src/main/ets/common'), modules = new Map(), calls = [], roots = new Map(), timers = new Map();
let nextTimer = 0, rootFd = 30, childFd = 100, capability = true, persistFailure = false, selection = [], httpResponse = null, factory;
const persisted = new Set(), files = new Map(), requests = [];
const rootUri = 'file://docs/storage/Users/currentUser/Movies';
const docUri = 'file://docs/storage/Users/currentUser/library.json';
const stat = (directory, size = 0, modified = 1700000000000) => ({ isDirectory: directory, size, modifiedTime: modified });
files.set(rootUri + '\0', { ...stat(true), list: [{ name: 'A.mkv', ...stat(false, 5e9) }, { name: 'sub', ...stat(true) }, { name: 'notes.txt', ...stat(false, 20) }] });
files.set(rootUri + '\0A.mkv', stat(false, 5e9));
files.set(rootUri + '\0sub', { ...stat(true), list: [{ name: 'B.mp4', ...stat(false, 1e9, 1800000000000) }] });
files.set(rootUri + '\0sub/B.mp4', stat(false, 1e9, 1800000000000));
const localNative = {
  stat: async (fd, p) => { calls.push(['native-stat', roots.get(fd), p]); const value = files.get(roots.get(fd) + '\0' + p); if (!value) throw Error('LOCAL_ROOT_OR_PATH_NOT_READABLE'); return value; },
  list: async (fd, p) => { calls.push(['native-list', roots.get(fd), p]); const value = files.get(roots.get(fd) + '\0' + p); if (!value || !value.list) throw Error('LOCAL_NOT_DIRECTORY'); return value.list; },
  openChild: async (fd, p) => { calls.push(['native-open', roots.get(fd), p]); const value = files.get(roots.get(fd) + '\0' + p); if (!value || value.isDirectory) throw Error('LOCAL_NOT_PLAYABLE_FILE'); return { ...value, fd: ++childFd }; },
  closeFile: async fd => { calls.push(['native-close', fd]); },
  readSmall: async (fd, p, maximum) => { calls.push(['native-read-doc', roots.get(fd), maximum]); const value = files.get(roots.get(fd) + '\0' + p); if (!value || !value.text) throw Error('LOCAL_DOCUMENT_READ_FAILED'); const data = new TextEncoder().encode(value.text); if (data.byteLength > maximum) throw Error('LOCAL_DOCUMENT_TOO_LARGE'); return data.buffer; }
};
class FakeHttp {
  static resolve(base, href) { const value = new URL(href, base); if (!['http:', 'https:'].includes(value.protocol) || value.username || value.password) throw Error('来源地址必须是HTTP(S)'); value.hash = ''; return value.toString(); }
  static sameOrigin(a, b) { return new URL(a).origin === new URL(b).origin; }
  static extension(value) { return (new URL(value).pathname.match(/\.([a-z0-9]+)$/i) || ['', ''])[1].toLowerCase(); }
  static basic(user, password) { return 'Basic ' + Buffer.from(user + ':' + password).toString('base64'); }
  cancel() { calls.push(['http-cancel']); }
  async request(address, method, headers, body, maximum) { requests.push({ address, method, headers, body, maximum }); if (!httpResponse) throw Error('No fixture'); const current = httpResponse; return typeof current === 'function' ? current() : { status: 200, text: JSON.stringify(current), address }; }
}
const localState = { getResume: async () => [], getFavorites: async () => [], isFavorite: async () => false, addFavorite: async () => {}, removeFavorite: async () => {}, reportProgress: async () => {} };
function load(file) {
  file = path.resolve(file); const name = path.basename(file);
  if (name === 'DirectSourceHttp.ets') return { DirectSourceHttp: FakeHttp };
  if (name === 'LocalSourceState.ets') return { LocalSourceState: localState };
  if (name === 'MediaServiceRegistry.ets') return { MediaServiceRegistry: { forServer: server => ({ catalog: factory(server.kind, server) }) } };
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal(output.diagnostics.length, 0, file);
  const requireModule = name => {
    if (name === 'libnas_local.so') return { default: localNative };
    if (name === '@kit.CoreFileKit') return {
      picker: { DocumentSelectOptions: class {}, DocumentSelectMode: { FOLDER: 1, FILE: 0 }, DocumentViewPicker: class { async select(options) { calls.push(['picker', options]); return selection; } } },
      fileIo: { OpenMode: { READ_ONLY: 0 }, async open(uri) { calls.push(['open-uri', uri]); const fd = ++rootFd; roots.set(fd, uri); return { fd }; }, async close(file) { calls.push(['close-root', file.fd]); roots.delete(file.fd); } },
      fileShare: { OperationMode: { READ_MODE: 1 }, async persistPermission(policies) { if (persistFailure) throw Error('unsupported'); persisted.add(policies[0].uri); }, async checkPersistentPermission(policies) { return [persisted.has(policies[0].uri)]; }, async activatePermission(policies) { calls.push(['activate', policies[0].uri]); } },
      fileUri: { FileUri: class { constructor(uri) { this.name = decodeURIComponent(new URL(uri).pathname.split('/').at(-1)); } } }
    };
    if (name === '@kit.ArkTS') return { util: {
      TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
      TextDecoder: class { constructor(label, options) { this.decoder = new TextDecoder(label, options); } decodeWithStream(data) { return this.decoder.decode(data); } }
    } };
    if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd: () => { const hash = crypto.createHash('sha256'); return { updateSync: blob => hash.update(blob.data), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) }; } } };
    return load(path.resolve(path.dirname(file), name + '.ets'));
  };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, require: requireModule, Uint8Array, ArrayBuffer,
    canIUse: () => capability, setTimeout: fn => { const id = ++nextTimer; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id) }, { filename: file });
  return module.exports;
}
const { ServerConfig, MediaItem, Library } = load(path.join(root, 'Models.ets'));
const { LocalAccess } = load(path.join(root, 'services/LocalAccess.ets'));
const { LocalCatalog } = load(path.join(root, 'services/LocalCatalog.ets'));
const { LocalAdapter } = load(path.join(root, 'services/LocalAdapter.ets'));
const { CustomManifest } = load(path.join(root, 'services/CustomManifest.ets'));
const { CustomCatalog } = load(path.join(root, 'services/CustomCatalog.ets'));
const { SourceBrowserController } = load(path.join(root, 'services/SourceBrowserController.ets'));
const server = new ServerConfig('local-test', 'local', 'Local', '', 0, '', '', ''); server.sourceUrl = rootUri; server.authMode = 'anonymous';
const custom = new ServerConfig('custom-test', 'custom', 'Custom', 'example.test', 443, 'u', '', ''); custom.scheme = 'https'; custom.sourceUrl = 'https://example.test/library/list.json'; custom.password = 'fixture-only';
const basicDoc = () => ({ version: 1, name: 'Actual manifest', folders: [{ id: 'movies', name: 'Movies' }], items: [
  { id: 'a', name: 'A', parentId: 'movies', streamURL: '../video/a.mp4', sizeBytes: 5e9, width: 1920, height: 1080,
    modifiedAt: '2026-10-27T01:00:00Z', subtitles: [{ id: 'en', url: '../subs/a.vtt', language: 'en' }] },
  { id: 'b', name: 'B', streamURL: 'https://cdn.test/b.mkv' }
] });
const item = (id, name, type = 'Video', modifiedAt = '') => Object.assign(new MediaItem(), { id, name, type, modifiedAt });
const tick = async () => { for (let i = 0; i < 24; i++) await Promise.resolve(); };
const frame = async () => { await tick(); const ready = [...timers.values()]; timers.clear(); ready.forEach(fn => fn()); await tick(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return { promise, resolve, reject }; };
let groups = 0;
(async () => {
  selection = [rootUri]; assert.equal(await LocalAccess.select({}, true), rootUri); await LocalAccess.ensureRead(rootUri);
  LocalAccess.temporary.clear(); await LocalAccess.ensureRead(rootUri); assert(calls.some(c => c[0] === 'activate'));
  selection = []; assert.equal(await LocalAccess.select({}, false), ''); groups++;

  const temporary = 'file://docs/storage/Users/currentUser/temporary.mp4';
  persistFailure = true; selection = [temporary]; await LocalAccess.select({}, false); await LocalAccess.ensureRead(temporary);
  assert.match(LocalAccess.permissionNotice(temporary), /重启/); LocalAccess.temporary.clear();
  await assert.rejects(LocalAccess.ensureRead(temporary), /重新选择/); persistFailure = false; groups++;

  assert.throws(() => LocalAccess.relative('../secret'), /根范围/); assert.throws(() => LocalAccess.relative('a/../b'), /根范围/);
  assert.throws(() => LocalAccess.relative('/outside'), /相对路径/); assert.throws(() => LocalAccess.relative('a\\b'), /相对路径/);
  const catalog = new LocalCatalog(); const views = await catalog.getViews(server); assert.equal(views.length, 1);
  const rows = await catalog.getItems(server, views[0].id, 0, 100, false);
  assert.equal(rows.length, 3); assert.equal(rows[0].type, 'Folder'); assert(rows.find(r => r.name === 'A.mkv').modifiedAt.length > 0);
  assert.equal(rows.find(r => r.name === 'notes.txt').isPlayable(), false);
  await assert.rejects(catalog.getItems(server, 'local:..%2Foutside', 0, 1, false), /根目录/); groups++;

  const adapter = new LocalAdapter(); const playback = await adapter.getPlaybackInfo(server, 'local:A.mkv', '', 0);
  assert.match(playback.url, /^fd:\/\/\d+$/); assert.equal(Object.keys(playback.headers).length, 0);
  assert.equal(calls.some(c => c[0] === 'native-read-doc' && c[1] === rootUri), false, 'Video never read into a whole-file buffer');
  const ownedFd = Number(playback.url.substring(5)); await playback.release(); await playback.release();
  assert.equal(calls.filter(c => c[0] === 'native-close' && c[1] === ownedFd).length, 1);
  assert.equal(roots.size, 0, 'Temporary root File objects closed independently of borrowed playback fd'); groups++;

  const doc = basicDoc(); const parsed = CustomManifest.parse(JSON.stringify(doc), custom.sourceUrl, false, { Authorization: 'fixture-only' });
  assert.equal(parsed.entries.get('a').address, 'https://example.test/video/a.mp4');
  assert.equal(parsed.entries.get('a').headers.authorization, 'fixture-only'); assert.equal(Object.keys(parsed.entries.get('b').headers).length, 0);
  assert.equal(parsed.entries.get('a').source.sizeBytes, 5e9); assert.equal(parsed.entries.get('a').source.streams.find(s => s.type === 'Video').width, 1920);
  assert.equal(parsed.entries.get('a').subtitles[0].url, 'https://example.test/subs/a.vtt'); groups++;

  for (const mutate of [d => { d.version = 2; }, d => { d.folders[0].parentId = 'movies'; }, d => { d.items[0].parentId = 'missing'; },
    d => { d.items[1].id = 'a'; }, d => { d.items[0].streamURL = 'file://docs/private.mkv'; },
    d => { d.items[0].streamURL = 'javascript:alert(1)'; }, d => { d.items[0].headers = { Host: 'bad' }; },
    d => { d.items[0].headers = { Authorization: 'bad\r\nx: y' }; }, d => { d.items[0].sizeBytes = Number.MAX_SAFE_INTEGER + 1; },
    d => { d.items[0].subtitles[0].url = 'https://other.test/auth-leak.vtt'; }]) {
    const value = basicDoc(); mutate(value); assert.throws(() => CustomManifest.parse(JSON.stringify(value), custom.sourceUrl, false, { Authorization: 'fixture' }));
  }
  assert.throws(() => CustomManifest.parse(JSON.stringify({ version:1, items: Array.from({length:5001},(_,i)=>({id:String(i),name:'x',streamURL:'https://example.test/a.mp4'})) }), custom.sourceUrl, false, {}), /5000/); groups++;

  const deep = { version:1, folders: Array.from({length:33},(_,i)=>({ id:String(i), name:'d', parentId:i===0?'':String(i-1) })), items:[] };
  assert.throws(() => CustomManifest.parse(JSON.stringify(deep), custom.sourceUrl, false, {}), /深度/);
  assert.throws(() => CustomManifest.parse(JSON.stringify({version:1,items:[{id:'x',name:'x',streamURL:'../a.mp4'}]}), docUri, true, {}), /完整 HTTP/); groups++;

  httpResponse = basicDoc(); const cc = new CustomCatalog(); const cv = await cc.getViews(custom);
  const folderRows = await cc.getItems(custom, cv[0].id, 0, 20, false); assert.equal(folderRows.some(r => r.type==='Folder'), true);
  const nested = await cc.getItems(custom, 'custom:folder:movies', 0, 20, false); assert.equal(nested.length,1);
  const detail = await cc.getItemDetail(custom, nested[0].id); assert.equal(detail.sources[0].sizeBytes,5e9);
  const play = await cc.playback(custom, nested[0].id); assert.equal(play.url,'https://example.test/video/a.mp4'); assert.equal(play.isLive,false);
  assert.equal(cc.subtitleUrl(custom,nested[0].id,'',1000,'vtt'),'https://example.test/subs/a.vtt');
  assert.equal(requests.at(-1).maximum,2097152); groups++;

  persisted.add(docUri); files.set(docUri+'\0',{...stat(false),text:JSON.stringify({version:1,items:[{id:'x',name:'X',streamURL:'https://video.test/x.mp4'}]})});
  const localCustom = new ServerConfig('local-json','custom','JSON','',0,'','',''); localCustom.sourceUrl=docUri; localCustom.authMode='anonymous';
  assert.equal((await new CustomCatalog().getViews(localCustom)).length,1);
  localCustom.sourceUrl='file://docs/storage/Users/currentUser/not-json.mp4'; await assert.rejects(new CustomCatalog().getViews(localCustom),/\.json/);
  const bigUri='file://docs/storage/Users/currentUser/big.json'; persisted.add(bigUri); files.set(bigUri+'\0',{...stat(false),text:'x'.repeat(2097153)});
  await assert.rejects(LocalAccess.readDocument(bigUri),/2MiB/); groups++;

  const events=[], catalogCalls=[]; let pending=null;
  const browserCatalog={
    cancel(){catalogCalls.push(['cancel']);}, async getViews(s){catalogCalls.push(['views',s.id]);return [new Library('root','Root','folders')];},
    async getItems(s,parent,start){catalogCalls.push(['items',s.id,parent,start]); if(pending){const p=pending;pending=null;return p.promise;}return parent==='root'?[item('sub','Sub','Folder','2026-01-01'),item('z','Z','Video','2026-01-02'),item('a','A','Video','2026-01-03')]:[item('inside','Inside')];},
    async search(s,q){catalogCalls.push(['search',s.id,q]);return [item('found',q)];}, async isFavorite(){catalogCalls.push(['favorite-query']);return true;},
    async addFavorite(){catalogCalls.push(['add']);},async removeFavorite(){catalogCalls.push(['remove']);},
    imageUrl(s,id,w,tag){return tag;}, imageHeaders(){return {Authorization:'fixture-only'};},
    async getEpg(){return [{title:'Current',startMs:Date.now()-1000,endMs:Date.now()+1000},{title:'Next',startMs:Date.now()+1000,endMs:Date.now()+2000}];}
  };
  factory=()=>browserCatalog;
  const browsing=new ServerConfig('browse','smb','Browse','example.test',445,'u','',''); browsing.scheme='http';
  const controller=new SourceBrowserController(s=>events.push(s)); controller.configure(browsing,true);
  await tick(); assert.equal(events.length,0,'No render-turn State publication'); await frame(); assert.equal(events.at(-1).items.length,3); groups++;

  controller.enter(events.at(-1).items[0]); await frame(); assert.equal(events.at(-1).trail.length,2); assert.equal(events.at(-1).items[0].id,'inside');
  controller.back(0); await frame(); controller.setSort('time'); await frame(); assert.equal(events.at(-1).items[1].id,'a');
  controller.setGrid(true); await frame(); assert.equal(events.at(-1).grid,true);
  await controller.search('needle'); await frame(); assert.equal(events.at(-1).items[0].id,'found'); controller.setSort('time'); await frame();
  assert.equal(events.at(-1).sort,'name'); assert.match(events.at(-1).notice,/缺少真实日期/); groups++;

  controller.back(0); await frame(); const video=events.at(-1).items.find(i=>i.id==='a');
  await controller.toggleFavorite(video); await frame(); assert.equal(catalogCalls.some(c=>c[0]==='favorite-query'),true); assert.equal(catalogCalls.some(c=>c[0]==='remove'),true);
  assert.equal(events.at(-1).items.find(i=>i.id==='a').favoriteKnown,true); groups++;

  pending=deferred(); const late=pending; controller.enter(events.at(-1).items[0]); await tick(); controller.setVisible(false);
  const before=events.length; late.resolve([item('late','Must not render')]); await frame(); assert.equal(events.length,before);
  controller.setVisible(true); await frame(); assert.equal(events.at(-1).items.some(i=>i.id==='late'),false); groups++;

  const oldPending=deferred(); pending=oldPending; controller.back(0); await tick();
  const other=new ServerConfig('other','smb','Other','other.test',445,'other','',''); other.scheme='http'; controller.configure(other,true);
  await frame(); const currentScope=events.at(-1).scope; oldPending.resolve([item('old-account','Old')]); await frame();
  assert.equal(events.at(-1).scope,currentScope); assert.equal(events.at(-1).items.some(i=>i.id==='old-account'),false); groups++;

  const logo=item('logo','Logo'); logo.imageTag='http://other.test:445/logo.jpg'; assert.equal(controller.imageHeaders(logo).Authorization,'fixture-only');
  logo.imageTag='https://cdn.test/logo.jpg'; assert.equal(Object.keys(controller.imageHeaders(logo)).length,0);
  const iptv=new ServerConfig('tv','iptv','TV','example.test',80,'','',''); iptv.sourceUrl='http://example.test/live.m3u'; controller.configure(iptv,true); await frame();
  await controller.loadEpg(item('ch','Channel')); await frame(); assert.equal(events.at(-1).programmes[0].title,'Current'); groups++;

  const selected=[];
  factory=(kind,s)=>{selected.push([kind,s.connectionMode]);if(s.connectionMode==='invalid-imported-mode')throw Error('unsupported imported connection mode');return browserCatalog};
  for(const kind of ['smb','custom']){const aggregate=new ServerConfig('aggregate-'+kind,kind,'Aggregate','example.test',443,'u','','');aggregate.scheme='https';aggregate.connectionMode='aggregate';controller.configure(aggregate,true);await frame();assert.equal(selected.at(-1)[0],kind);assert.equal(selected.at(-1)[1],'aggregate');assert.equal(controller.server.kind,kind);assert.equal(controller.server.connectionMode,'aggregate')}
  const invalid=new ServerConfig('invalid-mode','smb','Invalid','example.test',443,'u','','');invalid.connectionMode='invalid-imported-mode';const publications=events.length;
  assert.doesNotThrow(()=>controller.configure(invalid,true));assert.equal(events.length,publications,'Imported mode error cannot synchronously publish State on a mount/render stack');await frame();assert.match(events.at(-1).error,/imported connection mode/);assert.equal(events.at(-1).items.length,0);assert.equal(controller.catalog,null);groups++;
  const delayedEvents=[],delayedController=new SourceBrowserController(state=>delayedEvents.push(state));delayedController.configure(invalid,false);await frame();assert.equal(delayedEvents.length,0);
  delayedController.configure(invalid,true);assert.equal(delayedEvents.length,0);await frame();assert.match(delayedEvents.at(-1).error,/imported connection mode/);
  delayedController.setVisible(false);delayedController.setVisible(true);await frame();assert.match(delayedEvents.at(-1).error,/imported connection mode/);delayedController.destroy();groups++;
  controller.configure(browsing,true);await frame();
  const lateDestroyed=deferred(); pending=lateDestroyed; controller.back(0); await tick(); controller.destroy(); const last=events.length;
  lateDestroyed.resolve([item('destroyed','No')]); await frame(); assert.equal(events.length,last); assert.equal(timers.size,0); groups++;

  // Execute the widget's real imperative click/lifecycle methods without pretending to render ArkUI on Node.
  const widgetSource=fs.readFileSync(projectFile('entry/src/main/ets/components/SourceBrowser.ets'),'utf8');
  function widgetMethod(name){
    const expression=new RegExp('(?:private )?'+name+'\\([^)]*\\)[^{]*\\{'); const match=expression.exec(widgetSource); assert(match,name);
    let end=match.index+match[0].length, depth=1;
    while(depth>0&&end<widgetSource.length){const char=widgetSource[end++];if(char==='{')depth++;if(char==='}')depth--;}
    return widgetSource.substring(match.index,end).replace(/^private /,'');
  }
  const imperative=ts.transpileModule('class WidgetActions { '+['open','nowText','nextText','aboutToAppear','aboutToDisappear','inputsChanged'].map(widgetMethod).join('\n')+' } module.exports=WidgetActions;',
    {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  const actionModule={exports:{}};vm.runInNewContext(imperative,{module:actionModule,SourceBrowserController,Date});
  const actions=new actionModule.exports(); const played=[],entered=[],explained=[];
  actions.current=()=>true;actions.controller={enter:i=>entered.push(i.id),explainFile:i=>explained.push(i.id)};
  actions.frame={items:[item('folder','F','Folder'),item('channel','C'),item('file','T','File')],programmes:[{title:'Current',startMs:Date.now()-1000,endMs:Date.now()+1000},{title:'Next',startMs:Date.now()+1000,endMs:Date.now()+2000}]};
  actions.onPlay=(i,siblings)=>played.push([i.id,Array.from(siblings,x=>x.id)]);
  actions.open(actions.frame.items[0]);actions.open(actions.frame.items[1]);actions.open(actions.frame.items[2]);
  assert.deepEqual(entered,['folder']);assert.deepEqual(played,[['channel',['channel']]]);assert.deepEqual(explained,['file']);
  assert.equal(actions.nowText(),'Current');assert.match(actions.nextText(),/Next/); groups++;

  const lifecycle=new actionModule.exports();lifecycle.server=browsing;lifecycle.active=true;lifecycle.frame={scope:'',query:''};lifecycle.searchText='old';
  lifecycle.aboutToAppear();await tick();assert.equal(lifecycle.frame.scope,'','onAppear has no synchronous UI State assignment');
  await frame();assert.equal(lifecycle.frame.items.length,3);lifecycle.aboutToDisappear();assert.equal(timers.size,0);groups++;
  console.log('PASS local/custom/browser: '+groups+' groups; actual ETS provider/controller methods with platform/native/HTTP bindings mocked. Device grants/playback and native filesystem IO are separate.');
})().catch(error=>{console.error(error);process.exitCode=1;});
