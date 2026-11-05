'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
let clock=Date.UTC(2026,9,27,1,0,0);
class FixtureDate extends Date {constructor(value){super(value===undefined?clock:value);}static now(){return clock;}}
function environment(customStore,customModels){
 const values=new Map(),servers=new Map(),writes=[],modules=new Map();let readFail=false,writeFail=false,noWrite=false,active=0,maxActive=0;
 const store=customStore||{
  async get(key,fallback){await Promise.resolve();if(readFail)throw Error('fixture persistent read failure');return values.has(key)?values.get(key):fallback;},
  async set(key,value){active++;maxActive=Math.max(maxActive,active);try{await Promise.resolve();if(writeFail)throw Error('fixture write failure');if(!noWrite){values.set(key,value);writes.push([key,value]);}}finally{active--; }},
  async loadServers(){return Array.from(servers.values(),clone);},async upsert(server){servers.set(server.id,clone(server));}
 };
 function clone(server){const out=new models.ServerConfig(server.id,server.kind,server.name,server.host,server.port,server.username,server.token,server.userId);for(const key of Object.keys(server))out[key]=server[key];return out;}
 function load(relative){
  if(relative==='Models'&&customModels)return customModels;
  const file=projectFile('entry/src/main/ets/common/'+relative+'.ets');if(modules.has(file))return modules.get(file).exports;
  const module={exports:{}};modules.set(file,module);
  const result=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(result.diagnostics.length,0);
  vm.runInNewContext(result.outputText,{module,exports:module.exports,Date:FixtureDate,require:name=>{
   if(name==='./Store'||name==='../Store')return {Store:store};
   if(name==='@kit.ArkTS')return {url:{URL},util:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text);}}}};
   if(name==='@kit.CryptoArchitectureKit')return {cryptoFramework:{createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(crypto.randomBytes(n))})}),createMd:()=>{const hash=crypto.createHash('sha256');return{updateSync:blob=>hash.update(blob.data),digestSync:()=>({data:new Uint8Array(hash.digest())})};}}};
   return load(path.relative(projectFile('entry/src/main/ets/common'),path.resolve(path.dirname(file),name)).replaceAll('\\','/'));
  }});return module.exports;
 }
 const models=load('Models');const api=load('ServerOptions');
 return {values,servers,writes,store,models,...api,key:id=>'station_options_v1.'+crypto.createHash('sha256').update(id).digest('hex'),
  setReadFail:v=>readFail=v,setWriteFail:v=>writeFail=v,setNoWrite:v=>noWrite=v,getMaxActive:()=>maxActive};
}
let passed=0;
async function test(name,run){await run();passed++;console.log('PASS '+name);}
const textError=expression=>async()=>expression();
(async()=>{
 const e=environment(),api=e.ServerOptions;
 const makeServer=(id='station')=>{const s=new e.models.ServerConfig(id,'fnos','Fixture','nas.test',8005,'private-user','private-token','remote-user');s.basePath='/private-proxy';s.password='private-password';s.nativeToken='private-native';s.refreshToken='private-refresh';s.clientSecret='private-client-secret';s.sourceUrl='https://secret.test/private?signature=fixture';s.epgUrl='https://secret.test/epg?signature=fixture';s.authBrokerUrl='https://secret.test/broker-secret';s.credentialRef='asset-private-ref';return s;};
 e.servers.set('station',makeServer());e.servers.set('other',makeServer('other'));
 await test('defaults and batch views have per-station identity and no digest/salt leakage',async()=>{
  const result=await api.all();assert.equal(result.length,2);const s=await api.get('station');
  assert.equal(s.aggregateEnabled,true);assert.equal(s.hidden,false);assert.equal(s.hasPin,false);assert.equal(s.locked,false);
  for(const key of ['pinDigest','pinSalt','pinFailures','pinBlockedUntil'])assert.equal(key in s,false);
  assert.equal(api.cached('missing'),null);assert.equal(e.writes.length,0);
 });
 await test('a password only locks its designated station; other stations and their passwords are independent',async()=>{
  await api.setPin('station','1234');assert.equal(await api.isLocked('station'),true);assert.equal(await api.isLocked('other'),false);
  await api.setPin('other','5678');assert.equal(await api.isLocked('other'),true);
  assert.equal(await api.verifyPin('station','1234'),true);assert.equal(await api.isLocked('station'),false);assert.equal(await api.isLocked('other'),true);
  await api.clearPin('station');assert.equal((await api.get('station')).hasPin,false);assert.equal((await api.get('other')).hasPin,true);
  await api.clearPin('other','5678');assert.equal(await api.isLocked('other'),false);
 });
 await test('metadata writes serialize and public/cache copies cannot mutate persisted values',async()=>{
  await Promise.all([api.setNote('station','  real note\nline2  '),api.setHidden('station',true),api.setAggregate('station',false),api.setReminder('station',true,10,25)]);
  const value=await api.get('station');assert.equal(value.note,'real note\nline2');assert.equal(value.hidden,true);assert.equal(value.aggregateEnabled,false);assert.equal(value.reminderHour,10);assert.equal(value.reminderMinute,25);
  assert.equal(e.getMaxActive(),1);value.note='mutated';assert.notEqual(api.cached('station').note,'mutated');assert.equal((await api.get('other')).note,'');
  await api.setHidden('station',false);
 });
 await test('invalid IDs, switches, text and times reject without overwriting current state or prototype injection',async()=>{
  const before=e.values.get(e.key('station')),count=e.writes.length;
  for(const id of ['', '__proto__','constructor','prototype','a/b','a\\b','a\u0000b'])await assert.rejects(async()=>api.get(id),/标识/);
  for(const action of [()=>api.setNote('station','x'.repeat(2001)),()=>api.setNote('station','x\u0000'),()=>api.setHidden('station',1),()=>api.setAggregate('station','yes'),()=>api.setReminder('station',true,24,0),()=>api.setReminder('station',true,9,60)])await assert.rejects(textError(action));
  assert.equal(e.values.get(e.key('station')),before);assert.equal(e.writes.length,count);assert.equal({}.polluted,undefined);
 });
 await test('backup URLs canonicalize real endpoints and reject credentials, query, fragment, malformed percent and traversal',async()=>{
  assert.equal(api.normalizeBackupUrl('HTTPS://NAS.TEST:443/dav/'),'https://nas.test/dav');
  assert.equal(api.normalizeBackupUrl('http://[2001:db8::1]:8005/emby/'),'http://[2001:db8::1]:8005/emby');
  for(const input of ['ftp://nas.test/','http://u:p@nas.test/','http://nas.test/?token=secret','http://nas.test/#fragment','http://nas.test/%','http://nas.test/a/../b','http://nas.test/%2e%2e/b','http://nas.test/a%2fb','http://nas.test/a%5cb','http://nas.test/a%0ab','http://nas.test:70000/','http://nas.test/a b'])assert.throws(()=>api.normalizeBackupUrl(input),/备用/);
 });
 let node;
 await test('backup create/edit/remove enforces duplicate and eight-node bounds with immutable returned rows',async()=>{
  node=await api.putBackup('station','LAN','https://backup.test/emby');assert.match(node.id,/^node-[a-f0-9]{24}$/);
  await assert.rejects(async()=>api.putBackup('station','duplicate','https://backup.test/emby/'),/存在/);
  node=await api.putBackup('station','LAN renamed','https://backup.test:8443/emby',node.id);assert.equal(node.name,'LAN renamed');
  const savedId=node.id;node.url='https://mutated.test';assert.equal((await api.get('station')).backups[0].url,'https://backup.test:8443/emby');
  for(let i=1;i<8;i++)await api.putBackup('station','node'+i,'https://n'+i+'.test');
  await assert.rejects(async()=>api.putBackup('station','overflow','https://overflow.test'),/8/);
  const toRemove=(await api.get('station')).backups[7].id;await api.removeBackup('station',toRemove);assert.equal((await api.get('station')).backups.length,7);
  node=(await api.get('station')).backups.find(n=>n.id===savedId);
 });
 await test('backup activation updates only endpoint on a fresh station, preserving ID and runtime/vault credentials',async()=>{
  const source=e.servers.get('station');source.name='fresh concurrent display';
  const output=await api.activateBackup('station',node.id);assert.equal(output.id,'station');assert.equal(output.name,'fresh concurrent display');assert.equal(output.host,'backup.test');assert.equal(output.port,8443);assert.equal(output.scheme,'https');assert.equal(output.basePath,'/emby');
  for(const key of ['credentialRef','username','token','password','nativeToken','refreshToken','clientSecret','sourceUrl','epgUrl','authBrokerUrl'])assert.equal(output[key],source[key],key);
  assert.equal(source.host,'nas.test','Caller snapshot was not mutated');
  const unsupported=makeServer('local');unsupported.kind='local';e.servers.set('local',unsupported);const n=await api.putBackup('local','not applicable','http://nas.test');
  await assert.rejects(async()=>api.activateBackup('local',n.id),/直连来源/);
 });
 await test('public share emits only allowlisted origin/type and no account, secret, resource or private path',async()=>{
  const server=e.servers.get('station');const raw=await api.publicShare(server),value=JSON.parse(raw);
  assert.deepEqual(Object.keys(value).sort(),['connectionMode','kind','notice','origin','version']);assert.equal(value.origin,'https://backup.test:8443');
  for(const marker of ['private-user','private-token','private-password','private-native','private-refresh','private-client-secret','asset-private-ref','signature','broker-secret','/emby','sourceUrl','epgUrl','authBroker'])assert.equal(raw.includes(marker),false,marker);
 });
 await test('PIN uses per-set random SHA256 salt, really blocks mutations/share and masks private options',async()=>{
  await api.setPin('station','1234');const saved=JSON.parse(e.values.get(e.key('station')));assert.match(saved.pinSalt,/^[a-f0-9]{64}$/);assert.match(saved.pinDigest,/^[a-f0-9]{64}$/);
  assert.notEqual(saved.pinDigest,crypto.createHash('sha256').update('1234').digest('hex'));assert.equal(JSON.stringify(saved).includes('"1234"'),false);
  const value=await api.get('station');assert.equal(value.hasPin,true);assert.equal(value.locked,true);assert.equal(value.note,'');assert.equal(value.backups.length,0);
  for(const action of [()=>api.setNote('station','bypass'),()=>api.setHidden('station',false),()=>api.setAggregate('station',true),()=>api.activateBackup('station',node.id),()=>api.shareText('station'),()=>api.clear('station')])await assert.rejects(textError(action),/锁定/);
  assert.equal(await api.verifyPin('station','9999'),false);assert.equal(await api.isLocked('station'),true);
  assert.equal(await api.verifyPin('station','1234'),true);assert.equal(await api.isLocked('station'),false);assert.equal((await api.get('station')).note,'real note\nline2');
 });
 await test('session unlock expires, cached copies mask after expiry, restart cannot persist an unlock',async()=>{
  clock+=10*60*1000+1;assert.equal(api.cached('station').locked,true);assert.equal(api.cached('station').note,'');assert.equal(await api.isLocked('station'),true);
  assert.equal(await api.verifyPin('station','1234'),true);assert.equal(await api.isLocked('station'),false);
  const restarted=environment(e.store,e.models);assert.equal(await restarted.ServerOptions.isLocked('station'),true);
  await api.lock('station');assert.equal(await api.isLocked('station'),true);
 });
 await test('five wrong attempts persist cooldown across a fresh runtime and cannot unlock on a failed write',async()=>{
  for(let i=0;i<5;i++)assert.equal(await api.verifyPin('station','9876'),false);
  const restarted=environment(e.store,e.models);await assert.rejects(async()=>restarted.ServerOptions.verifyPin('station','1234'),/尝试过多/);
  clock+=60001;assert.equal(await restarted.ServerOptions.verifyPin('station','1234'),true);
  await restarted.ServerOptions.lock('station');e.setWriteFail(true);await assert.rejects(async()=>restarted.ServerOptions.verifyPin('station','1234'),/write failure/);e.setWriteFail(false);
  assert.equal(await restarted.ServerOptions.isLocked('station'),true);
 });
 await test('PIN changes need old verification, clear removes protection only after authorization',async()=>{
  await api.lock('station');await assert.rejects(async()=>api.setPin('station','4321'),/PIN/);
  const before=JSON.parse(e.values.get(e.key('station'))).pinSalt;
  await api.setPin('station','4321','1234');assert.notEqual(JSON.parse(e.values.get(e.key('station'))).pinSalt,before);assert.equal(await api.isLocked('station'),true);
  assert.equal(await api.verifyPin('station','1234'),false);assert.equal(await api.verifyPin('station','4321'),true);
  await api.clearPin('station');assert.equal((await api.get('station')).hasPin,false);assert.equal(await api.isLocked('station'),false);
 });
 await test('foreground reminders are due once per calendar day, serialized, and suppressed for hidden/locked stations',async()=>{
  const morning=new Date(2026,9,28,9,0,0).getTime();clock=morning;await api.setReminder('station',true,10,0);
  assert.equal(await api.takeDueReminder('station',morning),false);
  const due=new Date(2026,9,28,10,0,0).getTime();const results=await Promise.all(Array.from({length:8},()=>api.takeDueReminder('station',due)));assert.equal(results.filter(Boolean).length,1);
  await api.setHidden('station',true);assert.equal(await api.takeDueReminder('station',due+86400000),false);await api.setHidden('station',false);
  await api.setPin('station','7777');assert.equal(await api.takeDueReminder('station',due+86400000),false);await api.clearPin('station','7777');
  assert.equal(await api.takeDueReminder('station',due+86400000),true);
 });
 await test('corrupt/failed storage is non-destructive, batch fails closed, and write failures do not poison the queue',async()=>{
  const good=e.values.get(e.key('station'));e.values.set(e.key('station'),'{broken');const count=e.writes.length;
  await assert.rejects(async()=>api.setNote('station','overwrite'),/原记录已保留/);assert.equal(e.values.get(e.key('station')),'{broken');assert.equal(e.writes.length,count);
  const row=(await api.all()).find(v=>v.id==='station');assert.equal(row.locked,true);assert.equal(row.aggregateEnabled,false);assert.ok(row.error);
  e.values.set(e.key('station'),good);e.setReadFail(true);await assert.rejects(async()=>api.setNote('station','overwrite'),/read failure/);e.setReadFail(false);
  e.setWriteFail(true);await assert.rejects(async()=>api.setNote('station','failed'),/write failure/);e.setWriteFail(false);await api.setNote('station','recovered');assert.equal((await api.get('station')).note,'recovered');
  e.setNoWrite(true);await assert.rejects(async()=>api.setNote('station','not persisted'),/未保存/);e.setNoWrite(false);
  const rawPayload=e.values.get(e.key('station'));const payload=JSON.parse(rawPayload.slice(0,-1)+',"__proto__":{"polluted":"bad"},"extra":"untrusted"}');
  e.values.set(e.key('station'),JSON.stringify(payload));assert.equal(e.values.get(e.key('station')).includes('__proto__'),true);
  await api.setNote('station','whitelisted');assert.equal({}.polluted,undefined);assert.equal(e.values.get(e.key('station')).includes('untrusted'),false);assert.equal(e.values.get(e.key('station')).includes('__proto__'),false);
 });
 await test('actual Store/ServerRepository asset path keeps credentialRef during endpoint switch, no credentials in option JSON',async()=>{
  const nativeEnv=require('./source-storage-env.cjs')();await nativeEnv.Store.init({});
  const s=new nativeEnv.models.ServerConfig('repository-real','fnos','Name','nas.test',8005,'account','token','uid');s.password='pw';s.nativeToken='native';s.sourceUrl='https://secret.test/private?sign=x';s.epgUrl='https://secret.test/epg';s.authBrokerUrl='https://secret.test/broker';
  await nativeEnv.Store.upsert(s);const ref=s.credentialRef;assert.ok(ref);
  const r=environment(nativeEnv.Store,nativeEnv.models),service=r.ServerOptions;
  const backup=await service.putBackup(s.id,'Other LAN','https://other.test:8443/emby');const next=await service.activateBackup(s.id,backup.id);
  assert.equal(next.id,s.id);assert.equal(next.credentialRef,ref);const restored=(await nativeEnv.Store.loadServers())[0];assert.equal(restored.credentialRef,ref);assert.equal(restored.password,'pw');assert.equal(restored.token,'token');assert.equal(restored.authBrokerUrl,s.authBrokerUrl);
  const raw=nativeEnv.values.get(r.key(s.id));for(const marker of ['password','credentialRef','authBroker','token','account','secret.test'])assert.equal(raw.includes(marker),false,marker);
 });
 console.log('PASS '+passed+' actual ServerOptions groups; Node crypto/URL/Store fixtures and actual repository integration, no device.');
})().catch(error=>{console.error(error);process.exitCode=1;});
