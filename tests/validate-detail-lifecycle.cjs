'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const source=fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'),'utf8');
function method(name){const m=new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m').exec(source);assert(m,name);const start=source.indexOf('{',m.index);let level=1,end=start+1;for(;level;end++){if(source[end]==='{')level++;if(source[end]==='}')level--;}return source.slice(m.index,end).replace(/^  private /,'  ');}
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return{promise,resolve,reject};}
const item=(id,type='Movie')=>({id,type,name:id});
let detail=async(_s,id)=>({item:item(id),sources:[]}),seasons=async()=>[],episodes=async()=>[],people=async()=>[],toasts=[],gate=async()=>true,watchLater=async()=>false;
const ctx={exports:{},SourceIdentity:{scope:s=>JSON.stringify([s.id,s.userId,s.kind,s.rootPath])},
 MediaServices:{getItemDetail:(...a)=>detail(...a),getSeasons:(...a)=>seasons(...a),getEpisodes:(...a)=>episodes(...a),getPeople:(...a)=>people(...a)},
 VisionStore:{isWatchLater:(...a)=>watchLater(...a)},promptAction:{showToast:v=>toasts.push(v.message)}};
const code=`class Page {current={id:'source',userId:'account',kind:'fnos'};detailItem=null;detail=null;seasons=[];episodes=[];people=[];
 homeScrollMounted=true;homeScrollPageVisible=true;detailRequestGeneration=0;seasonRequestGeneration=0;curSeasonId='';
 ensureSubpage(){} sourceFamily(){return 'catalog'}async serverGate(server){return gate(server)}
 ${['detailRequestCurrent','openDetail','selectSeason','loadPeople'].map(method).join('\n')}
 }exports.Page=Page;`;
const out=ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(out.diagnostics.length,0);vm.runInNewContext(out.outputText,ctx);
ctx.gate=server=>gate(server);
const Page=ctx.exports.Page;const settle=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
let groups=0;async function test(name,run){detail=async(_s,id)=>({item:item(id),sources:[]});seasons=async()=>[];episodes=async()=>[];people=async()=>[];gate=async()=>true;watchLater=async()=>false;toasts=[];await run();console.log('PASS: '+name);groups++;}
(async()=>{
 await test('late detail A cannot overwrite a newer B page or issue A cast requests',async()=>{const p=new Page(),a=deferred(),calls=[];detail=async(_s,id)=>id==='A'?a.promise:{item:item(id),sources:[]};people=async(_s,id)=>{calls.push(id);return[id]};const old=p.openDetail(item('A'));await p.openDetail(item('B'));a.resolve({item:item('A'),sources:[]});await old;await settle();assert.equal(p.detail.item.id,'B');assert.equal(p.people[0],'B');assert.deepEqual(calls,['B']);});
 await test('closing, hiding, changing account and changing source root reject a stale detail result',async()=>{for(const change of [p=>p.detailItem=null,p=>p.homeScrollPageVisible=false,p=>p.current={...p.current,userId:'other'},p=>p.current={...p.current,rootPath:'/other'}]){const p=new Page(),a=deferred();detail=()=>a.promise;const old=p.openDetail(item('A'));await settle();change(p);a.resolve({item:item('A'),sources:[]});await old;assert.equal(p.detail,null);assert.equal(toasts.length,0);}});
 await test('default season and slow selected seasons cannot replace the latest explicit season',async()=>{const p=new Page(),first=deferred(),second=deferred();seasons=async()=>[{id:'s1'},{id:'s2'},{id:'s3'}];episodes=async(_s,_id,season)=>season==='s1'?first.promise:season==='s2'?second.promise:[item('ep3','Episode')];const open=p.openDetail(item('show','Series'));await settle();const s2=p.selectSeason('s2');await p.selectSeason('s3');second.resolve([item('ep2','Episode')]);first.resolve([item('ep1','Episode')]);await Promise.all([open,s2]);assert.equal(p.curSeasonId,'s3');assert.equal(p.episodes[0].id,'ep3');});
 await test('late cast failures do not clear cast from a newer title',async()=>{const p=new Page(),a=deferred();people=async(_s,id)=>id==='A'?a.promise:['cast-B'];await p.openDetail(item('A'));await p.openDetail(item('B'));a.reject(Error('fixture'));await settle();assert.equal(p.people[0],'cast-B');});
 await test('current errors are visible, stale errors are silent and mismatched detail identities never commit',async()=>{const p=new Page();detail=async()=>({item:item('wrong'),sources:[]});await p.openDetail(item('A'));assert.equal(p.detail,null);assert.equal(toasts.length,1);const a=deferred();detail=()=>a.promise;const pending=p.openDetail(item('A'));await settle();p.detailItem=null;a.reject(Error('fixture'));await pending;assert.equal(toasts.length,1);});
 await test('rejected gates and superseded gate responses do not open an obsolete title',async()=>{const p=new Page(),pending=deferred();let calls=0;detail=async(_s,id)=>{calls++;return{item:item(id),sources:[]}};gate=async()=>false;await p.openDetail(item('blocked'));assert.equal(calls,0);gate=()=>pending.promise;const old=p.openDetail(item('A'));gate=async()=>true;await p.openDetail(item('B'));pending.resolve(true);await old;assert.equal(calls,1);assert.equal(p.detail.item.id,'B');});
 await test('late watch-later lookup stays bound to the current title generation',async()=>{const p=new Page(),pending=deferred();watchLater=async(_s,id)=>id==='A'?pending.promise:false;await p.openDetail(item('A'));await p.openDetail(item('B'));pending.resolve(true);await settle();assert.equal(p.detailWatchLater,false);assert.equal(p.detail.item.id,'B');});
 console.log(`PASS: ${groups} actual detail/season/cast lifecycle groups. No ArkUI rendering, network or device calls.`);
})().catch(error=>{console.error(error);process.exitCode=1});
