'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
function load(name,deps={}){
 const source=fs.readFileSync(projectFile('entry/src/main/ets/common/'+name+'.ets'),'utf8');
 const output=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});
 assert.equal(output.diagnostics.length,0);const ctx={exports:{},require:id=>{assert(deps[id],id);return deps[id]}};
 vm.runInNewContext(output.outputText,ctx);return ctx.exports;
}
const endpoint=load('SourceEndpoint'),profiles=load('SourceProfiles',{'./SourceEndpoint':endpoint});
const {ServerConfig}=load('Models',{'./SourceEndpoint':endpoint});
const pageSource=fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'),'utf8');
function method(name){
 const match=new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m').exec(pageSource);assert(match,name);
 const begin=pageSource.indexOf('{',match.index);let depth=1,end=begin+1;
 for(;depth;end++){if(pageSource[end]==='{')depth++;else if(pageSource[end]==='}')depth--;}
 return pageSource.slice(match.index,end).replace(/^  private /,'  ');
}
const names=['doLogin','sourceProfile','editingSource','sourceCredentialsCompatible','sourceFormSnapshot','applySourceFields',
 'sourceServerDraft','sourceRequestCurrent','sourceRequestError','runSourceRequest','activateSavedSource','invalidateSourceRequest',
 'closeSourceForm','openAddServer','openEditServer','changeSourceKind','changeSourceMode','sourceFields','sourceFieldValue',
 'sourceFieldChanged','sourceFieldPlaceholder','pickSourceFolder','clearSourceCredentials','deleteEditedSource',
 'clearSourceAuthorization','beginSourceAuthorization','openSourceAuthorization','pollSourceAuthorization',
 'sourceDisplayName','rootTitle','rootServerSummary'];
let login=async server=>server,upsertGate=null,pick=async()=>[],choice=async()=>({index:0}),db=[],upserts=[],removed=[],last='',toasts=[],loginInputs=[];
let beginAuth=async()=>{throw Error('not configured')},pollAuth=async()=>{throw Error('not configured')},opened=[],aggregateWrites=[];
const ctx={exports:{},...profiles,ServerConfig,Materials:{popupMaterial:()=>({nativeMaterial:true})},MediaServices:{login:async(server,password)=>{loginInputs.push({server,password});return login(server,password)},
 beginAuthorization:server=>beginAuth(server),pollAuthorization:(server,flow)=>pollAuth(server,flow)},
 Store:{async upsert(server){if(upsertGate)await upsertGate;upserts.push(server);const index=db.findIndex(s=>s.id===server.id);if(index<0)db.push(server);else db[index]=server},
 async loadServers(){return db.slice()},async setLastId(value){last=value},async remove(id){removed.push(id);db=db.filter(s=>s.id!==id)}},
 promptAction:{showToast:item=>toasts.push(item.message),showDialog:options=>choice(options)},
 LocalAccess:{select:(context,folder)=>pick(folder)},ServerOptions:{setAggregate:async(id,enabled)=>aggregateWrites.push({id,enabled}),
  isLocked:async()=>false,get:async()=>({hidden:false}),clear:async()=>{}},
 getContext:()=>({startAbility:async want=>{opened.push(want)}})};
const code=`class Page {
 sourceDraft=new SourceDraft();sourceFormPhase='idle';sourceFormError='';sourceFormStatus='';sourceClearCredentials=false;
 sourceRequestGeneration=0;editingId='';showAdd=false;homeScrollMounted=true;homeScrollPageVisible=true;sourceAuthFlow=null;sourceAuthServer=null;
 servers=[];current=null;currentTab=0;libs=[];rows=[];heroItems=[];resumeItems=[];loads=0;navs=[];tmdbAutoInclude=true;optionReloads=0;
 ensureSubpage(name){if(!this.navs.includes(name))this.navs.push(name)}popNamed(name){this.navs=this.navs.filter(value=>value!==name)}
 reloadServerOptions(){this.optionReloads++}
 P(){return {textDim:'#888',accent:'#0087ff'}}dark(){return true}getUIContext(){return {getPromptAction(){return promptAction}}}loadLibraries(){this.loads++}
 ${names.map(method).join('\n')}
}exports.Page=Page;`;
const output=ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});
assert.equal(output.diagnostics.length,0);vm.runInNewContext(output.outputText,ctx);
function fixture(){db=[];upserts=[];removed=[];last='';toasts=[];loginInputs=[];aggregateWrites=[];upsertGate=null;login=async server=>server;pick=async()=>[];choice=async()=>({index:0});return new ctx.exports.Page()}
function fill(p,kind='fnos'){
 p.openAddServer(kind);p.sourceFieldChanged('address','nas.local');p.sourceFieldChanged('username','viewer');
 p.sourceFieldChanged('password','test-only-password');if(kind==='plex')p.sourceFieldChanged('accessToken','test-only-plex-token');
 return p;
}
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return{promise,resolve,reject}}
async function settle(){for(let i=0;i<12;i++)await Promise.resolve()}
function stored(id='existing',kind='fnos'){
 const server=new ServerConfig(id,kind,'Saved source','old.local',8005,'viewer','test-old-token','test-user');
 server.password='test-old-password';server.nativeToken='test-old-native';server.credentialRef='test-opaque-ref';return server;
}
let groups=0;async function test(name,run){await run();groups++;console.log('PASS: '+name)}
(async()=>{
 await test('all thirteen menu types open fresh type-correct drafts and expose their distinct fields',async()=>{
  const p=fixture();
  for(const profile of profiles.SourceProfiles.all()){
   p.openAddServer(profile.kind);assert.equal(p.sourceDraft.kind,profile.kind);assert.equal(p.sourceDraft.scheme,profile.defaultScheme);
   assert.equal(p.sourceDraft.password,'');assert.equal(p.sourceDraft.accessToken,'');assert.equal(p.editingId,'');
   assert(p.sourceFields().length>0);assert.deepEqual(Array.from(p.navs),['source']);p.closeSourceForm();assert.equal(p.navs.length,0);
  }
  assert.match(method('addServerMenu'),/openAddServer\(SourceProfiles\.forName\(name\)\.kind\)/);
  assert.match(method('sourceFormInput'),/InputType\.Password/);
 });
 await test('successful save validates exact HTTPS/IPv6/base-path configuration, persists and activates the new source',async()=>{
  const p=fill(fixture());p.current=stored('previous');p.sourceFieldChanged('address','https://[2001:db8::7]:8443/reverse/films');
  login=async server=>new ServerConfig('provider-new-id',server.kind,'Provider','wrong.local',80,server.username,'test-new-token','test-user');
  await p.doLogin();assert.equal(upserts.length,1);const saved=upserts[0];
  assert.equal(saved.scheme,'https');assert.equal(saved.host,'2001:db8::7');assert.equal(saved.port,8443);assert.equal(saved.basePath,'/reverse/films');
  assert.equal(saved.password,'test-only-password');assert.equal(saved.id,loginInputs[0].server.id);assert.equal(last,saved.id);
  assert.equal(p.current.id,saved.id);assert.equal(p.showAdd,false);assert.equal(p.sourceDraft.password,'');assert.equal(p.loads,1);
 });
 await test('detect verifies actual provider login without saving or activating and invalid edits clear its status',async()=>{
  const p=fill(fixture());await p.runSourceRequest(false);assert.equal(loginInputs.length,1);assert.equal(upserts.length,0);
  assert.equal(p.current,null);assert.equal(p.showAdd,true);assert(p.sourceFormStatus.includes('尚未保存'));
  p.sourceFieldChanged('address','another.local');assert.equal(p.sourceFormStatus,'');
 });
 await test('cancel, reopen and a late old login cannot save data or overwrite the new form',async()=>{
  const p=fill(fixture()),pending=deferred();login=server=>pending.promise.then(()=>server);
  const run=p.doLogin();assert.equal(p.sourceFormPhase,'logging');p.closeSourceForm();p.openAddServer('plex');
  pending.resolve();await run;assert.equal(upserts.length,0);assert.equal(p.sourceDraft.kind,'plex');assert.equal(p.showAdd,true);assert.equal(p.sourceFormError,'');
 });
 await test('duplicate clicks do not duplicate requests; the accepted local save transaction cannot be dismissed halfway',async()=>{
  const p=fill(fixture()),pending=deferred();upsertGate=pending.promise;
  const first=p.doLogin();await p.doLogin();await settle();assert.equal(loginInputs.length,1);assert.equal(p.sourceFormPhase,'saving');
  p.closeSourceForm();assert.equal(p.showAdd,true);pending.resolve();await first;assert.equal(upserts.length,1);assert.equal(p.showAdd,false);
 });
 await test('editing empty secret inputs preserves only compatible credential identity without exposing secrets in the form',async()=>{
  const p=fixture(),server=stored();db=[server];p.servers=db.slice();p.openEditServer(server);
  assert.equal(p.sourceDraft.password,'');assert.equal(p.sourceDraft.accessToken,'');assert.equal(p.sourceFieldPlaceholder('password'),'留空保留已保存的值');
  p.sourceFieldChanged('address','198.51.100.31');await p.doLogin();
  assert.equal(upserts[0].id,'existing');assert.equal(loginInputs[0].password,'test-old-password');assert.equal(loginInputs[0].server.token,'test-old-token');
  assert.equal(server.host,'old.local','original profile is untouched until persistence');
 });
 await test('changing account or protocol does not borrow old credentials and validation fails before network access',async()=>{
  const p=fixture(),server=stored();db=[server];p.servers=db.slice();p.openEditServer(server);
  p.sourceFieldChanged('username','other-user');await p.doLogin();assert.equal(loginInputs.length,0);assert(p.sourceFormError.includes('密码'));
  p.openEditServer(server);p.changeSourceKind('plex');await p.doLogin();assert.equal(loginInputs.length,0);assert(p.sourceFormError.includes('令牌'));
  assert.equal(upserts.length,0);assert.equal(server.token,'test-old-token');
 });
 await test('invalid endpoints and unsupported provider errors are visible without fake success or credential exposure',async()=>{
  const p=fill(fixture());p.sourceFieldChanged('port','70000');await p.doLogin();assert.equal(loginInputs.length,0);assert(p.sourceFormError.includes('端口'));
  p.sourceFieldChanged('port','');login=async()=>{throw new Error('not registered test-only-password ?token=private-value')};
  await p.doLogin();assert.equal(upserts.length,0);assert.equal(p.showAdd,true);assert.equal(p.sourceFormPhase,'idle');
  assert(!p.sourceFormError.includes('test-only-password'));assert(!p.sourceFormError.includes('private-value'));assert(!p.sourceFormStatus.includes('成功'));
 });
 await test('clear credentials is a confirmed deferred intent and cancel never mutates stored secrets',async()=>{
  const p=fixture(),server=stored();db=[server];p.servers=db.slice();p.openEditServer(server);
  choice=async()=>({index:1});await p.clearSourceCredentials();assert.equal(p.sourceClearCredentials,true);assert.equal(server.token,'test-old-token');
  await p.doLogin();assert.equal(upserts.length,0,'empty password after clear must not reuse the previous one');
  p.closeSourceForm();assert.equal(server.password,'test-old-password');assert.equal(removed.length,0);
 });
 await test('delete requires confirmation, removes the selected profile and activates a real surviving source',async()=>{
  const p=fixture(),first=stored('first'),second=stored('second');db=[first,second];p.servers=db.slice();p.current=first;p.openEditServer(first);
  await p.deleteEditedSource();assert.equal(removed.length,0);
  choice=async()=>({index:1});await p.deleteEditedSource();assert.deepEqual(removed,['first']);assert.equal(p.current.id,'second');assert.equal(last,'second');assert.equal(p.showAdd,false);
 });
 await test('system folder selection uses FOLDER mode; cancellation rejects a late URI and never claims arbitrary path authorization',async()=>{
  const p=fixture(),pending=deferred();p.openAddServer('local');
  pick=folder=>{assert.equal(folder,true);return pending.promise};
  const run=p.pickSourceFolder();p.closeSourceForm();pending.resolve('file://docs/storage/Movies');await run;
  assert.equal(p.showAdd,false);assert.equal(p.sourceDraft.sourceUrl,'');assert.equal(upserts.length,0);
  p.openAddServer('local');pick=async()=>'';p.sourceDraft.sourceUrl='file://docs/storage/old-folder';
  await p.pickSourceFolder();assert.equal(p.sourceDraft.sourceUrl,'file://docs/storage/old-folder');
  pick=async()=>'file://docs/storage/Movies';await p.pickSourceFolder();assert.equal(p.sourceDraft.sourceUrl,'file://docs/storage/Movies');
 });
 await test('IPTV and EPG query-bearing resources retain real runtime values while anonymous authentication clears only auth credentials',async()=>{
  const p=fixture();p.openAddServer('iptv');p.sourceFieldChanged('sourceUrl','https://tv.example/list.m3u?token=test-subscription');
  p.sourceFieldChanged('epgUrl','https://tv.example/guide.xml?key=test-guide');await p.doLogin();
  assert.equal(upserts.length,1);assert.equal(upserts[0].sourceUrl,'https://tv.example/list.m3u?token=test-subscription');
  assert.equal(upserts[0].epgUrl,'https://tv.example/guide.xml?key=test-guide');assert.equal(upserts[0].token,'');assert.equal(upserts[0].password,'');
 });
 await test('page lifecycle invalidates source requests and the sheet guards storage commits rather than losing accepted writes',async()=>{
  assert.match(method('onPageHide'),/invalidateSourceRequest\(\)/);assert.match(method('aboutToDisappear'),/invalidateSourceRequest\(\)/);
  assert.match(pageSource,/\.onBackPressed\(\(\): boolean => this\.sourceFormPhase === 'saving' \|\| this\.sourceFormPhase === 'deleting'\)/);
  const p=fill(fixture()),pending=deferred();login=server=>pending.promise.then(()=>server);
  const run=p.doLogin();p.homeScrollPageVisible=false;p.invalidateSourceRequest();pending.resolve();await run;assert.equal(upserts.length,0);assert.equal(p.sourceFormPhase,'idle');
 });
 await test('new password entry forces real password verification and hidden foreign-type secrets are not forwarded',async()=>{
  const p=fixture(),server=stored();db=[server];p.servers=db.slice();p.openEditServer(server);
  p.sourceFieldChanged('password','new-test-password');await p.runSourceRequest(false);
  assert.equal(loginInputs[0].server.token,'');assert.equal(loginInputs[0].server.nativeToken,'');assert.equal(loginInputs[0].password,'new-test-password');
  p.openAddServer('baidu');p.sourceFieldChanged('clientSecret','old-type-secret');p.sourceFieldChanged('refreshToken','old-type-refresh');
  p.changeSourceKind('fnos');p.sourceFieldChanged('address','nas.local');p.sourceFieldChanged('username','viewer');p.sourceFieldChanged('password','new-test-password');
  await p.runSourceRequest(false);assert.equal(loginInputs.at(-1).server.clientSecret,'');assert.equal(loginInputs.at(-1).server.refreshToken,'');
 });
 await test('custom direct configuration uses real JSON resource URLs and a file picker rather than disguising itself as WebDAV',async()=>{
  const p=fixture();p.openAddServer('custom');assert(p.sourceFields().includes('sourceUrl'));assert(!p.sourceFields().includes('address'));
  pick=async folder=>{assert.equal(folder,false);return 'file://docs/storage/movie.mp4'};
  await p.pickSourceFolder();assert.equal(p.sourceDraft.sourceUrl,'');assert(p.sourceFormError.includes('.json'));
  pick=async()=>'file://docs/storage/library.json';await p.pickSourceFolder();assert.equal(p.sourceDraft.sourceUrl,'file://docs/storage/library.json');
  await p.doLogin();assert.equal(upserts.length,1);assert.equal(upserts[0].kind,'custom');assert.equal(upserts[0].sourceUrl,'file://docs/storage/library.json');
 });

 await test('fixed cloud endpoints expose real client identifiers and separate device authorization from persistence',async()=>{
  const p=fixture();p.openAddServer('guangya');assert(p.sourceFields().includes('clientId'));assert(!p.sourceFields().includes('address'));
  p.openAddServer('baidu');p.sourceFieldChanged('clientId','test-client');p.sourceFieldChanged('clientSecret','test-client-secret');
  beginAuth=async server=>{assert.equal(server.token,'');assert.equal(server.clientId,'test-client');return {provider:'baidu',userCode:'CODE',deviceCode:'private-device',verificationUrl:'https://openapi.baidu.com/device',expiresAt:Date.now()+60000}};
  await p.beginSourceAuthorization();assert.equal(p.sourceFormPhase,'idle');assert.equal(p.sourceAuthFlow.userCode,'CODE');assert.equal(upserts.length,0);
  await p.openSourceAuthorization();assert.equal(opened.at(-1).uri,'https://openapi.baidu.com/device');
  pollAuth=async server=>({state:'authorized',server:Object.assign(server,{token:'test-auth-token',refreshToken:'test-auth-refresh'}),message:''});
  await p.pollSourceAuthorization();assert.equal(p.sourceDraft.accessToken,'test-auth-token');assert.equal(p.sourceDraft.refreshToken,'test-auth-refresh');assert.equal(p.sourceAuthFlow,null);
  assert.equal(upserts.length,0,'an authorization response does not silently save a server');await p.doLogin();assert.equal(upserts.length,1);assert.equal(upserts[0].host,'');assert.equal(upserts[0].token,'test-auth-token');
 });
 await test('configuration edits and cancellation reject a late device-code or token response',async()=>{
  const p=fixture();p.openAddServer('baidu');p.sourceFieldChanged('clientId','test-client');p.sourceFieldChanged('clientSecret','test-client-secret');
  const pending=deferred();beginAuth=()=>pending.promise;const run=p.beginSourceAuthorization();p.closeSourceForm();p.openAddServer('plex');
  pending.resolve({provider:'baidu',userCode:'OLD',verificationUrl:'https://openapi.baidu.com/device'});await run;assert.equal(p.sourceAuthFlow,null);assert.equal(p.sourceDraft.kind,'plex');
  p.openAddServer('baidu');p.sourceFieldChanged('clientId','test-client');p.sourceFieldChanged('clientSecret','test-client-secret');
  beginAuth=async()=>({provider:'baidu',userCode:'NEW',verificationUrl:'https://openapi.baidu.com/device'});await p.beginSourceAuthorization();
  p.sourceFieldChanged('clientId','another-client');assert.equal(p.sourceAuthFlow,null);assert.equal(p.sourceAuthServer,null);
 });
 await test('pending and rejected authorization remain visible and cannot claim a saved login',async()=>{
  const p=fixture();p.openAddServer('baidu');p.sourceFieldChanged('clientId','test-client');p.sourceFieldChanged('clientSecret','test-client-secret');
  beginAuth=async()=>({provider:'baidu',userCode:'CODE',verificationUrl:'https://openapi.baidu.com/device'});await p.beginSourceAuthorization();
  pollAuth=async()=>({state:'pending',server:null,message:'等待用户确认'});await p.pollSourceAuthorization();assert.equal(p.sourceFormStatus,'等待用户确认');assert(p.sourceAuthFlow);
  pollAuth=async()=>({state:'expired',server:null,message:'已过期'});await p.pollSourceAuthorization();assert.equal(p.sourceAuthFlow,null);assert.equal(p.sourceFormStatus,'已过期');assert.equal(upserts.length,0);
 });
 await test('token-only media login requires an explicit user identity and changing it never reuses the previous credential',async()=>{
  const p=fixture();p.openAddServer('emby');p.sourceFieldChanged('address','nas.local');p.sourceFieldChanged('authMode','token');p.sourceFieldChanged('accessToken','test-token');
  await p.doLogin();assert.equal(loginInputs.length,0);assert(p.sourceFormError.includes('用户 ID'));
  p.sourceFieldChanged('userId','actual-user');await p.doLogin();assert.equal(upserts[0].userId,'actual-user');
 });

 await test('an explicit new access token never inherits another account refresh credential',async()=>{
  const p=fixture(),server=stored('oauth-source','baidu');server.authMode='oauth';server.clientId='test-client';server.clientSecret='test-app-secret';server.refreshToken='test-refresh-A';
  db=[server];p.servers=db.slice();p.openEditServer(server);p.sourceFieldChanged('accessToken','test-access-B');
  let draft=p.sourceFormSnapshot();assert.equal(draft.refreshToken,'');assert.equal(draft.clientSecret,'test-app-secret');
  await p.doLogin();assert.equal(upserts[0].token,'test-access-B');assert.equal(upserts[0].refreshToken,'');assert.equal(upserts[0].clearCredentials,true);
  p.servers=[server];p.openEditServer(server);p.sourceFieldChanged('accessToken','test-access-C');p.sourceFieldChanged('refreshToken','test-refresh-C');
  draft=p.sourceFormSnapshot();assert.equal(draft.refreshToken,'test-refresh-C');
 });
 await test('unchanged source edit preserves the user display name when token verification returns no serverName',async()=>{
  const p=fixture(),server=stored();server.name='MrLvable';server.serverName='Original NAS';server.host='198.51.100.31';
  db=[server];p.servers=db.slice();p.openEditServer(server);
  login=async draft=>{draft.serverName='';return draft};await p.doLogin();
  assert.equal(p.current.name,'MrLvable');assert.equal(p.current.serverName,'');
  assert.equal(p.rootTitle(),'MrLvable');assert.equal(p.rootServerSummary(),'MrLvable');
  const fallback=stored();fallback.name='  ';fallback.serverName=' Real server ';assert.equal(p.sourceDisplayName(fallback),'Real server');
  fallback.serverName='';assert.equal(p.sourceDisplayName(fallback),'old.local');
  fallback.host='';assert.equal(p.sourceDisplayName(fallback),profiles.SourceProfiles.forKind('fnos').name);
  fallback.kind='unknown';assert.equal(p.sourceDisplayName(fallback),'媒体来源');
 });
 await test('new-source auto-include preference persists exclusion without changing an edited source option',async()=>{
  const p=fill(fixture());p.tmdbAutoInclude=false;await p.doLogin();assert.equal(aggregateWrites.length,1);assert.equal(aggregateWrites[0].id,p.current.id);assert.equal(aggregateWrites[0].enabled,false);assert.equal(p.optionReloads,1);
  const edited=fixture(),server=stored();db=[server];edited.servers=db.slice();edited.openEditServer(server);edited.tmdbAutoInclude=false;await edited.doLogin();assert.equal(aggregateWrites.length,0);
 });
 console.log(`PASS: ${groups} actual source-form lifecycle groups. SDK/network/Store/picker are mocks; no device or live credential use.`);
})().catch(error=>{console.error(error);process.exitCode=1});
