'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const source=fs.readFileSync(projectFile('entry/src/main/ets/pages/PlayerPage.ets'),'utf8');
function method(name){const m=new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m').exec(source);assert(m,name);const start=source.indexOf('{',m.index);let depth=1,end=start+1;for(;depth;end++){if(source[end]==='{')depth++;if(source[end]==='}')depth--;}return source.slice(m.index,end).replace(/^  private /,'  ')}
const names=['nativeOverlayVisible','hideNativeOverlay','onNativeOverlayChange','nativePopupState','nativeSheetDismiss','nativeSheetGone','openSidePanel','closeSidePanel','onBackPress'];
const code=`class Page {
 panelMounted=true;playbackGen=7;nativeOverlayRevision=0;sideAnimationGen=0;sideProgress=0;sideMode=0;barOpacity=0;hideTimer=-1;
 showSubPanel=false;showSubtitleStyle=false;showRatioPanel=false;showSpeedPanel=false;showAudioPanel=false;showSidePanel=false;showCastPanel=false;showAiPanel=false;showAiSettings=false;showAiWorkbench=false;
 isPlaying=false;locked=false;episodes=[];sources=[];hides=0;shown=0;aiCancels=0;
 scheduleHideBar(){this.hides++}setPlayerStatusBarVisible(){}sidePanelWidth(){return 400}showBarTemporarily(){this.shown++}closeAiSettings(){this.showAiSettings=false}saveNow(){}releaseAll(){}
 ${names.map(method).join('\n')}
}exports.Page=Page;`;
const ctx={exports:{},hilog:{info(){}},router:{back(){}},setTimeout(){throw Error('Native overlay must not add its own animation timer')},clearTimeout(){}};
const out=ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(out.diagnostics.length,0);vm.runInNewContext(out.outputText,ctx);
const flags=['showSubPanel','showSubtitleStyle','showRatioPanel','showSpeedPanel','showAudioPanel','showSidePanel','showCastPanel','showAiPanel'];
function fixture(){const page=new ctx.exports.Page();for(const flag of flags){let value=page[flag];Object.defineProperty(page,flag,{get:()=>value,set(next){if(next===value)return;value=next;page.onNativeOverlayChange(flag)}})}return page}
let groups=0;function test(name,run){run();groups++;console.log('PASS: '+name)}
test('seven content builders are mounted by real native popup/sheet options, not a styled page Stack',()=>{
 const hosts=method('nativePlayerOverlays');assert.equal((hosts.match(/\.bindPopup\(/g)||[]).length,5);assert.equal((hosts.match(/\.bindSheet\(/g)||[]).length,2);assert.equal((hosts.match(/systemMaterial: Materials\.popupMaterial\(true, '#00D2FC'\)/g)||[]).length,7);
 for(const name of ['subtitleMenuPanel','ratioMenuPanel','speedMenuPanel','audioMenuPanel','sidePanel','castConfirmation','aiSubtitlePanel']){const content=method(name);assert(new RegExp('^  '+name+'\\(\\) \\{\\s*Column\\(\\) \\{').test(content),name+' content root must be a native-container body');assert(!content.includes('.backdropBlur('),name);assert(!content.includes('.position('),name+' popup root may not be positioned');assert(hosts.includes('this.'+name+'()'),name);}
 assert(source.includes('this.nativePlayerOverlays()'));assert(!/this\.speedMenuPanel\(\)\s+this\.sidePanel/.test(source));assert.equal((hosts.match(/preferType: SheetType.CENTER/g)||[]).length,2);
});
test('all overlay flags use actual watch isolation and more-menu material has no opaque whole-card fill',()=>{
 for(const flag of flags)assert(new RegExp("@State @Watch\\('onNativeOverlayChange'\\) (?:private )?"+flag+':').test(source),flag);
 const more=method('moreMenu');assert(!more.includes('.backgroundColor('));assert(!more.includes('.border({'));assert(method('hudMore').includes("systemMaterial: Materials.popupMaterial(true, '#00D2FC')"));
});
test('opening one popup dismisses competing native panels while subtitle styles remain in the same popup',()=>{
 const page=fixture();page.showRatioPanel=true;page.showAudioPanel=true;assert.equal(page.showRatioPanel,false);assert.equal(page.showAudioPanel,true);page.showSubPanel=true;assert.equal(page.showAudioPanel,false);page.showSubtitleStyle=true;assert.equal(page.showSubPanel,true);assert.equal(page.showSubtitleStyle,true);page.showAiPanel=true;assert.equal(page.showSubPanel,false);assert.equal(page.showSubtitleStyle,false);assert.equal(page.showAiPanel,true);
});
test('native auto-dismiss closes state and schedules HUD without stopping subtitle work',()=>{
 const page=fixture();page.showSubPanel=true;const callback=page.nativePopupState('subtitle');const revision=page.nativeOverlayRevision;callback({isVisible:true});assert.equal(page.nativeOverlayRevision,revision);callback({isVisible:false});assert.equal(page.showSubPanel,false);assert.equal(page.hides,1);assert.equal(page.aiCancels,0);
});
test('late popup close after reopening or opening a different panel cannot dismiss new state',()=>{
 const page=fixture();page.showRatioPanel=true;const old=page.nativePopupState('ratio');page.showRatioPanel=false;page.showRatioPanel=true;old({isVisible:false});assert.equal(page.showRatioPanel,true);page.showAudioPanel=true;old({isVisible:false});assert.equal(page.showAudioPanel,true);assert.equal(page.showRatioPanel,false);
});
test('playback-generation and terminal guards discard late native events',()=>{
 for(const terminate of [false,true]){const page=fixture();page.showSpeedPanel=true;const close=page.nativePopupState('speed');if(terminate)page.panelMounted=false;else page.playbackGen++;close({isVisible:false});assert.equal(page.showSpeedPanel,true);assert.equal(page.hides,0);}
});
test('center sheet dismissal settles the system action once and does not disable AI',()=>{
 const page=fixture();page.showAiPanel=true;const dismiss=page.nativeSheetDismiss('ai'),gone=page.nativeSheetGone('ai');let settled=0;dismiss({dismiss(){settled++}});gone();assert.equal(settled,1);assert.equal(page.showAiPanel,false);assert.equal(page.hides,1);assert.equal(page.aiCancels,0);
 page.showAiPanel=true;gone();assert.equal(page.showAiPanel,true);const stale=page.nativeSheetDismiss('ai');page.playbackGen++;stale({dismiss(){settled++}});assert.equal(page.showAiPanel,true);assert.equal(settled,2);
});
test('side panel toggles and Back close synchronously, native host owns animation',()=>{
 const page=fixture();page.openSidePanel(0);assert.equal(page.showSidePanel,true);assert.equal(page.sideMode,0);assert.equal(page.sideProgress,1);page.openSidePanel(1);assert.equal(page.showSidePanel,true);assert.equal(page.sideMode,1);assert.equal(page.onBackPress(),true);assert.equal(page.showSidePanel,false);assert.equal(page.sideProgress,0);page.showRatioPanel=true;assert.equal(page.onBackPress(),true);assert.equal(page.showRatioPanel,false);
});
test('full-screen AI setup/workbench and terminal error content retain their original lifecycle roles',()=>{
 assert(source.includes('AiSubtitleSettings({ dark: true, fullScreenOverlay: true'));assert(source.includes('AiSubtitleWorkbench({ dark: true, fullScreenOverlay: true'));assert(source.includes('A terminal playback error is page content, not a dismissible popup'));assert(!method('nativePlayerOverlays').includes('AiSubtitleSettings'));
});
console.log(`PASS: ${groups} actual Player native-overlay contract/lifecycle groups; ArkUI event delivery simulated, no device or visual proof.`);
