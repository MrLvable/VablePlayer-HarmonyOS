'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const compile=source=>{const result=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(result.diagnostics.length,0);return result.outputText;};
const source=fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'),'utf8');
function method(name){const m=new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m').exec(source);assert(m,name);const start=source.indexOf('{',m.index);let n=1,end=start+1;for(;n;end++){if(source[end]==='{')n++;if(source[end]==='}')n--;}return source.slice(m.index,end).replace(/^  private /,'  ');}
function storage(){
 const values=new Map([['lock_enabled','1'],['lock_pin','legacy-fixture-hash'],['lock_bio','1'],['station_options_v1.fixture','station-fixture-unchanged'],['servers_json','saved-stations-unchanged']]);const writes=[];let fail=false;
 const preferences={get:async(key,fallback)=>values.has(key)?values.get(key):fallback,put:async(key,value)=>{if(fail)throw Error('fixture failed write');writes.push(key);values.set(key,value)},flush:async()=>{}};
 const context={exports:{},require(name){if(name==='@kit.ArkData')return{preferences:{getPreferences:async()=>preferences}};if(name==='./ServerRepository')return{ServerRepository:{}};return{}}};
 vm.runInNewContext(compile(fs.readFileSync(projectFile('entry/src/main/ets/common/Store.ets'),'utf8')),context);
 return{api:context.exports.Store,values,writes,setFail(value){fail=value}};
}
let actions=[],locked=true;
const context={exports:{},recordAction:entry=>actions.push(Array.from(entry)),SourceIdentity:{scope:server=>server.id},ServerOptions:{
 isLocked:async()=>locked,setPin:async(id,pin,old)=>actions.push(['setPin',id,pin,old]),
 clearPin:async(id,pin)=>actions.push(['clearPin',id,pin]),verifyPin:async()=>true,
 setHidden:async()=>{},lock:async()=>{}},promptAction:{showToast(){}}};
vm.runInNewContext(compile(`class Page {
 servers=[{id:'A'},{id:'B'}];serverOptionId='A';serverOptionMode='pin';serverOptionPin='1234';serverOptionConfirmPin='1234';serverOptionOldPin='5678';
 serverOptionBusy=false;serverOptionError='';serverOptionGeneration=1;serverPendingAction='';homeScrollMounted=true;homeScrollPageVisible=true;current=null;
 cleared=[];popped=[];tabs=[];refreshes=0;
 reloadServerOptions(){this.refreshes++;return Promise.resolve()}clearProtectedSource(id){this.cleared.push(id)}
 popNamed(name){this.popped.push(name)}serverMenuAction(){throw Error('unexpected extra step')}
 selectServer(server,afterUnlock){this.current=server;recordAction(['select',server.id,afterUnlock]);return Promise.resolve()}selectTab(index){this.tabs.push(index)}
 ${['saveServerOption','openServerHome'].map(method).join('\n')}
}exports.Page=Page;`),context);
let groups=0;async function test(name,run){await run();groups++;console.log('PASS: '+name);}
(async()=>{
 await test('retiring a legacy app-wide lock leaves all station PINs and server connections intact',async()=>{
  const e=storage();await e.api.init({});await e.api.retireLegacyApplicationLock();
  assert.equal(e.values.get('lock_enabled'),'0');assert.equal(e.values.get('lock_pin'),'');assert.equal(e.values.get('lock_bio'),'0');
  assert.equal(e.values.get('station_options_v1.fixture'),'station-fixture-unchanged');assert.equal(e.values.get('servers_json'),'saved-stations-unchanged');
  assert.deepEqual(e.writes,['lock_enabled','lock_pin','lock_bio']);await e.api.retireLegacyApplicationLock();assert.equal(e.writes.length,3);
 });
 await test('legacy cleanup storage failure never reintroduces an application lock screen',async()=>{
  const e=storage();await e.api.init({});e.setFail(true);await assert.rejects(e.api.retireLegacyApplicationLock());
  assert(!source.includes('this.lockView()'));assert(!source.includes('this.toggleLock('));assert(!source.includes('Store.isLockEnabled()'));
  assert.match(source,/try \{ await Store\.retireLegacyApplicationLock\(\); \}/);assert(!source.includes("Text('启用应用锁')"));
 });
 await test('password setup targets one chosen server, including direct old-password verification while locked',async()=>{
  actions=[];locked=true;const page=new context.exports.Page();await page.saveServerOption();
  assert.deepEqual(actions,[['setPin','A','1234','5678']]);assert.deepEqual(Array.from(page.cleared),['A']);
  assert.equal(page.serverOptionError,'');assert.equal(page.refreshes,1);assert.deepEqual(Array.from(page.popped),['server-options']);
 });
 await test('mismatched new passwords never modify either station',async()=>{
  actions=[];const page=new context.exports.Page();page.serverOptionConfirmPin='0000';await page.saveServerOption();
  assert.equal(actions.length,0);assert.match(page.serverOptionError,/不一致/);assert.equal(page.cleared.length,0);
 });
 await test('remove-password action verifies only the selected station without unlocking the application',async()=>{
  actions=[];const page=new context.exports.Page();page.serverOptionId='B';page.serverOptionMode='clearPin';page.serverOptionPin='9876';await page.saveServerOption();
  assert.deepEqual(actions,[['clearPin','B','9876']]);assert.equal(page.serverOptionError,'');
 });
 await test('one explicit server tap opens its content and keeps the unlock continuation intent',async()=>{
  actions=[];const page=new context.exports.Page();await page.openServerHome({id:'B'});
  assert.deepEqual(actions,[['select','B','home']]);assert.deepEqual(Array.from(page.tabs),[0]);
  page.homeScrollPageVisible=false;page.tabs=[];await page.openServerHome({id:'A'});assert.equal(page.tabs.length,0);
 });
 console.log(`PASS: ${groups} actual server-password/migration/usability groups; Preferences and UI mocks, no device.`);
})().catch(error=>{console.error(error);process.exitCode=1});
