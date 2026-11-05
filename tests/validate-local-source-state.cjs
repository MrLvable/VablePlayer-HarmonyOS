'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const data=new Map(),writes=[],modules=new Map();
let getFailure=false,setFailure=false,activeWrites=0,maxWrites=0;
const store={async get(key,fallback){await Promise.resolve();if(getFailure)throw Error('fixture persistent read failed');return data.has(key)?data.get(key):fallback;},
 async set(key,value){activeWrites++;maxWrites=Math.max(maxWrites,activeWrites);try{await Promise.resolve();if(setFailure)throw Error('fixture write failed');writes.push([key,value]);data.set(key,value);}finally{activeWrites--;}}};
function load(relative){
 const file=projectFile('entry/src/main/ets/common/'+relative+'.ets');if(modules.has(file))return modules.get(file).exports;
 const module={exports:{}};modules.set(file,module);
 const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(code.diagnostics.length,0);
 vm.runInNewContext(code.outputText,{module,exports:module.exports,require:name=>{
  if(name==='../Store')return{Store:store};
  if(name==='@kit.ArkTS')return{util:{TextEncoder:class{encodeInto(value){return new TextEncoder().encode(value);}}}};
  if(name==='@kit.CryptoArchitectureKit')return{cryptoFramework:{createMd:()=>{const h=crypto.createHash('sha256');return{updateSync:b=>h.update(b.data),digestSync:()=>({data:new Uint8Array(h.digest())})};}}};
  const dependency=path.relative(projectFile('entry/src/main/ets/common'),path.resolve(path.dirname(file),name)).replaceAll('\\','/');return load(dependency);
 }});return module.exports;
}
const {MediaItem,ServerConfig}=load('Models');
const {SourceIdentity}=load('services/SourceIdentity');
const {LocalSourceState:state}=load('services/LocalSourceState');
const makeItem=(id,extra={})=>Object.assign(new MediaItem(),{id,name:'File '+id,type:'Video',runtimeTicks:100000000,...extra});
const makeServer=(id='s')=>{const s=new ServerConfig(id,'custom','Fixture','example.test',443,'','','');s.scheme='https';s.sourceUrl='https://example.test/library.json';s.authMode='anonymous';return s;};
const key=s=>'local_source_state_v1.'+SourceIdentity.scope(s);
const doc=s=>JSON.parse(data.get(key(s))||'{"version":1,"entries":[]}');
let passed=0;
async function test(name,run){await run();passed++;console.log('PASS '+name);}
(async()=>{
 const s=makeServer();
 await test('signed resource URLs and embedded HTTP credentials are removed from saved metadata',async()=>{
  await state.addFavorite(s,'a',makeItem('a',{imageTag:'https://cdn.test/a.jpg?signature=fixture-secret',backdropTag:'https://u:fixture-pass@cdn.test/b.jpg',path:'https://cdn.test/a.mp4?token=fixture-token',modifiedAt:'2026-10-27T01:00:00Z'}));
  const raw=data.get(key(s));for(const marker of ['signature=','fixture-secret','fixture-pass','fixture-token'])assert.equal(raw.includes(marker),false);
  assert.equal(doc(s).entries[0].item.modifiedAt,'2026-10-27T01:00:00Z');
 });
 await test('over256 history records never evict a favorite and retain only bounded recent history',async()=>{
  for(let i=0;i<300;i++)await state.reportProgress(s,'h'+i,i+1,false,makeItem('h'+i));
  assert.deepEqual(Array.from(await state.getFavorites(s,1000),i=>i.id),['a']);
  const rows=doc(s).entries;assert.equal(rows.filter(e=>e.favorite).length,1);assert.equal(rows.filter(e=>!e.favorite).length,256);
  assert.equal((await state.getResume(s,1000)).length,256);
 });
 await test('256 favorites cap rejects an additional one visibly without rewriting existing data',async()=>{
  const capped=makeServer('capped');data.set(key(capped),JSON.stringify({version:1,entries:Array.from({length:256},(_,i)=>({item:makeItem('f'+i),favorite:true,updatedAt:i}))}));
  const old=data.get(key(capped)),count=writes.length;
  await assert.rejects(async()=>state.addFavorite(capped,'extra',makeItem('extra')),/256/);
  assert.equal(data.get(key(capped)),old);assert.equal(writes.length,count);
  await state.addFavorite(capped,'f0',makeItem('f0'));assert.equal(doc(capped).entries.length,256);
 });
 await test('concurrent mutations serialize rather than losing favorites or progress',async()=>{
  const c=makeServer('concurrent');maxWrites=0;
  await Promise.all(Array.from({length:20},(_,i)=>state.addFavorite(c,'x'+i,makeItem('x'+i))).concat(Array.from({length:20},(_,i)=>state.reportProgress(c,'x'+i,100+i,false,makeItem('x'+i)))));
  assert.equal((await state.getFavorites(c,256)).length,20);assert.equal((await state.getResume(c,256)).length,20);assert.equal(maxWrites,1);
  await state.removeFavorite(c,'x0');await state.reportProgress(c,'x0',999,false,makeItem('x0',{isFavorite:true}));assert.equal(await state.isFavorite(c,'x0'),false,'Old snapshot must not resurrect removed favorite');
 });
 await test('read failure or corrupt document never overwrites persistent data; queue recovers after failure',async()=>{
  const p=makeServer('read-fail');await state.addFavorite(p,'keep',makeItem('keep'));const old=data.get(key(p)),count=writes.length;
  getFailure=true;await assert.rejects(async()=>state.reportProgress(p,'new',1,false,makeItem('new')),/read failed/);getFailure=false;
  assert.equal(data.get(key(p)),old);assert.equal(writes.length,count);
  data.set(key(p),'broken JSON');await assert.rejects(async()=>state.removeFavorite(p,'keep'),/原记录已保留/);assert.equal(data.get(key(p)),'broken JSON');
  data.set(key(p),old);await state.addFavorite(p,'recovered',makeItem('recovered'));assert.equal((await state.getFavorites(p,256)).length,2);
 });
 await test('invalid IDs/mismatched items reject, while bad persisted rows never fabricate media',async()=>{
  const p=makeServer('bad');const count=writes.length;
  for(const id of ['', 'https://cdn.test/private?token=secret'])await assert.rejects(async()=>state.addFavorite(p,id,makeItem(id)),/标识/);
  await assert.rejects(async()=>state.addFavorite(p,'one',makeItem('two')),/不匹配/);assert.equal(writes.length,count);
  data.set(key(p),JSON.stringify({version:1,entries:[null,{item:null},{item:makeItem(''),favorite:true},{item:makeItem('valid'),favorite:true,updatedAt:1}]}));
  assert.deepEqual(Array.from(await state.getFavorites(p,256),i=>i.id),['valid']);assert.equal(writes.length,count);
 });
 await test('OAuth app-local namespace survives access token rotation without claiming a remote user id',async()=>{
  const p=makeServer('oauth');p.authMode='oauth';p.token='oauth-before';SourceIdentity.ensureLocalAccount(p);assert.match(p.userId,/^local:/);
  const before=SourceIdentity.scope(p);await state.reportProgress(p,'resume',123,false,makeItem('resume'));
  p.token='oauth-after';p.refreshToken='rotated';SourceIdentity.ensureLocalAccount(p);
  assert.equal(SourceIdentity.scope(p),before);assert.equal((await state.getResume(p,10))[0].id,'resume');
 });
 await test('explicit token replacement cannot reuse an older local namespace; real remote account ids stay authoritative',async()=>{
  const p=makeServer('token');p.authMode='token';p.token='explicit-one';SourceIdentity.ensureLocalAccount(p);const before=SourceIdentity.scope(p);
  await state.reportProgress(p,'private-one',123,false,makeItem('private-one'));p.token='explicit-two';SourceIdentity.ensureLocalAccount(p);
  assert.notEqual(SourceIdentity.scope(p),before);assert.equal((await state.getResume(p,10)).length,0);
  p.userId='verified-remote-account';const same=SourceIdentity.scope(p);p.token='rotated-same-user';assert.equal(SourceIdentity.scope(p),same);
 });
 await test('server repository rejects malformed preference types safely and does not inherit a different token account secret',async()=>{
  const env=require('./source-storage-env.cjs')();await env.Store.init({});
  env.values.set('servers_json',null);assert.equal((await env.Store.loadServers()).length,0);assert.equal(env.values.get('servers_json'),null);
  const p=new env.models.ServerConfig('token-repo','custom','Profile','example.test',443,'','one','');p.scheme='https';p.authMode='token';p.password='old-only';SourceIdentity.ensureLocalAccount(p);
  await env.Store.upsert(p);const old=(await env.Store.loadServers())[0];
  const next=new env.models.ServerConfig(p.id,p.kind,p.name,p.host,p.port,'','two',old.userId);next.scheme='https';next.authMode='token';SourceIdentity.ensureLocalAccount(next);
  await env.Store.upsert(next);const restored=(await env.Store.loadServers())[0];assert.equal(restored.token,'two');assert.equal(restored.password,'');assert.notEqual(restored.userId,old.userId);
 });
 await test('bad names/types reject new writes without replacing state; invalid historical rows are ignored',async()=>{
  const p=makeServer('strict-item');await state.addFavorite(p,'keep',makeItem('keep'));const old=data.get(key(p)),count=writes.length;
  for(const bad of [{name:''},{name:'   '},{name:null},{type:undefined},{type:'InventedVideo'},{type:{name:'Video'}}]) {
   await assert.rejects(async()=>state.addFavorite(p,'bad',makeItem('bad',bad)),/名称或类型/);
   await assert.rejects(async()=>state.reportProgress(p,'bad',10,false,makeItem('bad',bad)),/名称或类型/);
  }
  assert.equal(data.get(key(p)),old);assert.equal(writes.length,count);
  data.set(key(p),JSON.stringify({version:1,entries:[{item:makeItem('missing-name',{name:''}),favorite:true},
   {item:makeItem('unknown-type',{type:'Unknown'}),favorite:true},{item:makeItem('valid-channel',{type:'Channel'}),favorite:true,updatedAt:1}]}));
  assert.deepEqual(Array.from(await state.getFavorites(p,256),i=>i.id),['valid-channel']);assert.equal(writes.length,count);
 });
 console.log('PASS '+passed+' actual LocalSourceState/SourceIdentity/repository groups; Node SHA256 and fixture Store/assets, no device.');
})().catch(error=>{console.error(error);process.exitCode=1;});
