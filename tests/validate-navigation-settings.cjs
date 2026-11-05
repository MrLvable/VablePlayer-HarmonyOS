'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const source=fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'),'utf8');
function method(name){const m=new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m').exec(source);assert(m,name);const start=source.indexOf('{',m.index);let n=1,end=start+1;for(;n;end++){if(source[end]==='{')n++;if(source[end]==='}')n--;}return source.slice(m.index,end).replace(/^  private /,'  ');}
let locked=false,options={},writes=[],deleted=[],choice=0,closed=0,db=[],nodeSwitches=[],toasts=[];
class ServerOption{constructor(){this.note='';this.hidden=false;this.aggregateEnabled=true;this.hasPin=false;this.locked=false;this.backups=[];}}
const ctx={exports:{},ServerOption,Materials:{popupMaterial:()=>({nativeMaterial:true})},SourceIdentity:{scope:s=>s.id+'|'+s.host},
  ServerOptions:{isLocked:async()=>locked,publicShare:async()=>'{"origin":"https://example.invalid"}',
    setAggregate:async(id,value)=>writes.push(['aggregate',id,value]),
    setHidden:async(id,value)=>writes.push(['hidden',id,value]),
    lock:async id=>{locked=true;writes.push(['lock',id]);},
    activateBackup:async(id,node)=>{nodeSwitches.push([id,node]);return db[0]},
    removeBackup:async()=>{},clear:async()=>{}},
  Store:{remove:async id=>deleted.push(id),loadServers:async()=>db, set:async()=>{}},
  promptAction:{showDialog:async()=>({index:choice}),showToast:args=>toasts.push(args.message)}};
const code=`class Page {
  serverOptions=[];serverOptionId='';serverOptionMode='';serverOptionText='';serverOptionPin='';serverOptionOldPin='';serverOptionError='';
  serverPendingAction='';serverOptionGeneration=0;current=null;selected=[];edited=[];pages=[];refreshes=0;cleared=[];
  P(){return {textDim:'#aaa',accent:'#0087ff'}}dark(){return true}getUIContext(){return {getPromptAction(){return promptAction},getContextMenuController(){return {close(){closed++}}}}}
  ensureSubpage(name){this.pages.push(name)} reloadServerOptions(){this.refreshes++}
  openEditServer(server){this.edited.push(server.id)} selectServer(server){this.selected.push(server.id)}
  clearProtectedSource(id){this.cleared.push(id)}
  ${['settingsPageTitle','serverOption','serverGate','openServerOption','serverMenuAction','activateServerBackup'].map(method).join('\n')}
}exports.Page=Page;`;
ctx.closed=closed;
vm.runInNewContext(ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,ctx);
function fixture(){locked=false;writes=[];deleted=[];choice=0;db=[];toasts=[];const p=new ctx.exports.Page();const opt=new ServerOption();opt.id='nas';p.serverOptions=[opt];return p;}
const server={id:'nas',host:'example.invalid'};
let groups=0;async function test(name,run){await run();groups++;console.log('PASS: '+name);}
(async()=>{
 await test('locked station gates edit, share and deletion before touching configuration',async()=>{
   const p=fixture();locked=true;for(const action of ['edit','share','delete']){await p.serverMenuAction(server,action);assert.equal(p.serverOptionMode,'unlock');assert.equal(p.serverPendingAction,action);}
   assert.equal(p.edited.length,0);assert.equal(deleted.length,0);assert.equal(writes.length,0);
 });
 await test('unlocked edit opens source editing and menu actions keep their own page',async()=>{
   const p=fixture();await p.serverMenuAction(server,'edit');assert.deepEqual(Array.from(p.edited),['nas']);
   await p.serverMenuAction(server,'note');assert.equal(p.serverOptionMode,'note');assert.equal(p.pages.at(-1),'server-options');
   await p.serverMenuAction(server,'share');await Promise.resolve();assert.match(p.serverOptionText,/origin/);
 });
 await test('locking a configured station clears displayed account content',async()=>{
   const p=fixture();p.serverOptions[0].hasPin=true;await p.serverMenuAction(server,'lock');assert.deepEqual(writes,[['lock','nas']]);assert.equal(p.cleared[0],'nas');
 });
 await test('hiding requires PIN setup and cannot silently hide an unprotected station',async()=>{
   const p=fixture();await p.serverMenuAction(server,'hidden');assert.equal(p.serverOptionMode,'pin');assert.equal(p.serverPendingAction,'hidden');assert.equal(writes.length,0);
   p.serverOptions[0].hasPin=true;await p.serverMenuAction(server,'hidden');assert.equal(writes[0][0],'hidden');assert.equal(writes[0][2],true);assert.equal(writes[1][0],'lock');
 });
 await test('delete cancellation preserves saved station; confirmed delete removes it',async()=>{
   const p=fixture();await p.serverMenuAction(server,'delete');assert.equal(deleted.length,0);choice=1;await p.serverMenuAction(server,'delete');assert.deepEqual(deleted,['nas']);
 });
 await test('aggregation menu changes content participation without changing transport mode',async()=>{
   const p=fixture();await p.serverMenuAction(server,'aggregate');assert.deepEqual(writes,[['aggregate','nas',false]]);assert.equal(server.connectionMode,undefined);
 });
 await test('PIN expiry while a deletion dialog is open refuses deletion on confirmation',async()=>{
   const p=fixture(),original=ctx.promptAction.showDialog;
   ctx.promptAction.showDialog=async()=>{locked=true;return{index:1}};
   try{await p.serverMenuAction(server,'delete');assert.equal(deleted.length,0);assert.equal(p.serverOptionMode,'unlock');}
   finally{ctx.promptAction.showDialog=original;}
 });
 await test('late share data cannot overwrite a newly opened station option page',async()=>{
   const p=fixture(),original=ctx.ServerOptions.publicShare;let resolve;
   ctx.ServerOptions.publicShare=()=>new Promise(r=>{resolve=r});
   p.openServerOption(server,'share');p.openServerOption({...server,id:'other'},'note');
   resolve('old share');await Promise.resolve();assert.equal(p.serverOptionId,'other');assert.equal(p.serverOptionText,'');
   ctx.ServerOptions.publicShare=original;
 });
 await test('settings actions and source editor are independent Navigation destinations',async()=>{
   const settings=source.slice(source.indexOf('  settingsView() {'),source.indexOf('  private rootServerSummary()'));
   assert(!/selectTab\(/.test(settings));assert.match(settings,/settings:tmdb/);assert.match(settings,/settings:servers/);assert.match(settings,/settings:subtitles/);
   assert(!source.includes('.bindSheet($$this.showAdd'));assert.match(source,/\.onBackPressed\(\(\): boolean => this.sourceFormPhase === 'saving'/);
   assert.match(source,/\.animationDuration\(MotionPref\.dur\(MotionSpec\.page\)\)/);assert.match(source,/bindContextMenu\(this.serverContextMenu\(s\), ResponseType.LongPress/);
   assert(!source.includes("['本周趋势', '热门电影'"));assert.equal(new ctx.exports.Page().settingsPageTitle('tmdb'),'TMDB 设置');
 });
 console.log(`PASS: ${groups} navigation/settings/server-action groups (actual methods with storage/UI mocks; no device rendering).`);
})().catch(error=>{console.error(error);process.exitCode=1});
