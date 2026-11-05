'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const source=fs.readFileSync(projectFile('entry/src/main/ets/components/VisionPage.ets'),'utf8');
function method(name){const match=new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m').exec(source);assert(match,name);const start=source.indexOf('{',match.index);let depth=1,end=start+1;for(;depth;end++){if(source[end]==='{')depth++;else if(source[end]==='}')depth--;}return source.slice(match.index,end).replace(/^  private /,'  ');}
let notices=[];
const context={module:{exports:{}},VisionController:{scope:servers=>servers.map(server=>server.id+'|'+server.userId).join(',')},
 Metrics:{height:()=>900},promptAction:{showToast:options=>notices.push(options.message)}};
const compiled=ts.transpileModule(`class Page {
 mounted=true;active=true;servers=[{id:'nas',userId:'viewer'}];frame={scope:'nas|viewer',section:0,watchLater:[],watching:[],playlists:[],selectedPlaylistId:''};
 actionGeneration=0;resetDialogOnNextFrame=false;dialog='';dialogBusy=false;dialogError='';nameInput='';activeRow=null;activeList=null;controller=null;
 onPlay=async()=>{};onOpenDetail=async()=>{};onBrowse=()=>{};
 ${['current','rows','open','selectSection','closeDialog','browse','sheetVisible','sheetTitle','sheetHeight','openDialog','saveName','action'].map(method).join('\n')}
}module.exports=Page;`,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(compiled.diagnostics.length,0);
vm.runInNewContext(compiled.outputText,context);const Page=context.module.exports;
const row=(playable=true)=>({server:{id:'nas',userId:'viewer'},title:'Sample',item:{id:'item',isPlayable:()=>playable}});
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return{promise,resolve,reject};}
function fixture(){notices=[];const page=new Page();page.controller={canOpen:async()=>true,selectSection(){},sources:()=>[],playlistRows:()=>[]};return page;}
const turn=async()=>{for(let n=0;n<16;n++)await Promise.resolve();};
let groups=0;async function test(name,run){await run();groups++;console.log('PASS: '+name);}
(async()=>{
 await test('section buttons remain actionable before the first async content frame',async()=>{
  const page=fixture(),selected=[];page.frame.scope='';page.controller.selectSection=index=>selected.push(index);
  page.selectSection(0);page.selectSection(2);assert.deepEqual(selected,[0,2]);page.active=false;page.selectSection(1);assert.deepEqual(selected,[0,2]);
 });
 await test('waiting and watching rows keep their detail/play routing and await callback completion',async()=>{
  const page=fixture(),calls=[],gate=deferred();page.onPlay=async()=>{calls.push('play');await gate.promise;calls.push('played')};page.onOpenDetail=async()=>{calls.push('detail')};
  const opening=page.open(row(),false);await turn();assert.deepEqual(calls,['play']);gate.resolve();await opening;assert.deepEqual(calls,['play','played']);
  await page.open(row(),true);await page.open(row(false),false);assert.deepEqual(calls,['play','played','detail','detail']);
 });
 await test('locked rows and stale section/account confirmations cannot navigate',async()=>{
  const page=fixture();let opened=0;page.onPlay=async()=>{opened++};page.controller.canOpen=async()=>false;await page.open(row(),false);assert.equal(opened,0);assert.equal(notices.length,1);
  const gate=deferred();page.controller.canOpen=()=>gate.promise;const pending=page.open(row(),false);page.frame.section=2;gate.resolve(true);await pending;assert.equal(opened,0);
  const other=deferred();page.controller.canOpen=()=>other.promise;const next=page.open(row(),false);page.servers=[{id:'nas',userId:'other'}];other.resolve(true);await next;assert.equal(opened,0);
 });
 await test('async playback failures surface instead of becoming unhandled promises',async()=>{
  const page=fixture();page.onPlay=async()=>{throw Error('fixture playback failed')};await page.open(row(),false);assert.equal(notices.at(-1),'fixture playback failed');
 });
 await test('a native sheet is visible only for the current scope and closes without retaining row actions',async()=>{
  const page=fixture();page.openDialog('item',row());assert.equal(page.sheetVisible(),true);page.resetDialogOnNextFrame=true;assert.equal(page.sheetVisible(),false);
  page.resetDialogOnNextFrame=false;page.dialogBusy=true;page.closeDialog();assert.equal(page.dialog,'item');page.closeDialog(true);assert.equal(page.dialog,'');assert.equal(page.activeRow,null);assert.equal(page.dialogBusy,false);
 });
 await test('empty state browsing is a real callback and cannot run from inactive pages',async()=>{
  const page=fixture();let browsed=0;page.onBrowse=()=>{browsed++};page.dialog='filter';page.browse();assert.equal(browsed,1);assert.equal(page.dialog,'');page.active=false;page.browse();assert.equal(browsed,1);
 });
 await test('creating a playlist from an item saves the row and opens the resulting list',async()=>{
  const page=fixture(),calls=[];page.dialog='create';page.nameInput='Evening';page.activeRow=row();page.controller.createPlaylist=async name=>{calls.push(['create',name]);return'list'};
  page.controller.addToPlaylist=async(id,item)=>{calls.push(['add',id,item.item.id])};page.controller.selectSection=index=>calls.push(['section',index]);page.controller.openPlaylist=id=>calls.push(['open',id]);
  await page.saveName();assert.deepEqual(calls,[['create','Evening'],['add','list','item'],['section',3],['open','list']]);assert.equal(page.dialog,'');assert.equal(page.dialogBusy,false);
 });
 await test('late list creation cannot reopen a dismissed scope or clear a new dialog',async()=>{
  const page=fixture(),gate=deferred();let opened=0;page.dialog='create';page.nameInput='Old';page.controller.createPlaylist=()=>gate.promise;page.controller.openPlaylist=()=>{opened++};
  const pending=page.saveName();page.closeDialog(true);page.dialog='filter';gate.resolve('late-list');await pending;assert.equal(opened,0);assert.equal(page.dialog,'filter');assert.equal(page.dialogBusy,false);
 });
 await test('list write errors remain in the system sheet for a deliberate retry',async()=>{
  const page=fixture();page.dialog='item';await page.action(async()=>{throw Error('fixture write failed')});assert.equal(page.dialog,'item');assert.equal(page.dialogError,'fixture write failed');assert.equal(page.dialogBusy,false);
 });
 await test('empty state bias stays inside its layout and cannot cover the section buttons',async()=>{
  const empty=source.slice(source.indexOf('  @Builder private empty('),source.indexOf('  @Builder private card('));
  assert.match(empty,/\.layoutWeight\(1\)\.justifyContent\(FlexAlign.Center\)\.padding\(\{ bottom: this\.u\(96\) \}\)/);
  assert(!empty.includes('.translate('),'translating the weighted container moves its blank hit area over the header');
  assert(!empty.includes('.position('),'empty content must participate in the vertical layout');
  // The r34 device measured header bottom at 460px. Translating this full-height
  // default-hit-test sibling by -88px put its blank area over the button at y389.
  // Internal padding preserves that sibling origin while shifting its children.
  const headerBottom=460,oldTop=headerBottom-88,buttonY=389;
  assert(oldTop<buttonY&&buttonY<headerBottom);
  const newTop=headerBottom;assert(buttonY<newTop);
 });
 await test('popup carrier and tap regions use real official APIs without a simulated screen mask',async()=>{
  assert.match(source,/\.bindSheet\(this\.sheetVisible\(\), this\.sheetContent\(\),/);assert.match(source,/preferType: SheetType.CENTER/);
  assert.match(source,/systemMaterial: Materials\.popupMaterial\(this\.darkMode, this\.P\(\)\.accent\)/);assert(!source.includes('private modal()'));assert(!source.includes("backgroundColor('#99000000')"));
  assert.match(source,/Button\(\{ type: ButtonType.Capsule \}\)/);assert.match(source,/\.layoutWeight\(1\)\.height\(44\)/);
  const card=source.slice(source.indexOf('  @Builder private card('),source.indexOf('  @Builder private grid('));assert(!card.includes('stopPropagation'));assert(!card.includes("alignItems(HorizontalAlign.Start).onClick"));
  assert.match(card,/accessibilityText\('影片操作'\)/);assert.match(source,/浏览影片并加入待看/);assert.match(source,/浏览影片开始观看/);
 });
 console.log(`PASS: ${groups} actual Vision UI routing/sheet/tap-contract groups. UI framework is mocked; no render or device proof.`);
})().catch(error=>{console.error(error);process.exitCode=1});
