const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const base=projectFile('entry/src/main/ets')+'/';
function compile(source){const out=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(out.diagnostics.length,0);return out.outputText;}
const mm={exports:{}};vm.runInNewContext(compile(fs.readFileSync(base+'common/Models.ets','utf8')),{module:mm,exports:mm.exports});
const M=mm.exports;let detail,playback,history=[],playbackCalls=0;
function pureModule(file){const module={exports:{}};vm.runInNewContext(compile(fs.readFileSync(base+'common/'+file+'.ets','utf8')),{module,exports:module.exports,setTimeout,clearTimeout});return module.exports;}
const leaseModule=pureModule('SourcePlaybackLeases'),policyModule=pureModule('SourcePlaybackPolicy');
const services={getItemDetail:async()=>detail,directStreamUrl:(s,id)=>s.kind==='fnos'?'http://invalid/v/api/v1/media/range/'+id:'http://invalid/Videos/'+id+'/stream?Static=true',getPlaybackInfo:async()=>{playbackCalls++;return playback},streamHeaders:()=>({'X-Emby-Token':'redacted'}),subtitleUrl:()=>'/external.srt'};
const navModule={exports:{}};vm.runInNewContext(compile(fs.readFileSync(base+'common/PlaybackNavigation.ets','utf8')),{module:navModule,exports:navModule.exports,require:name=>name==='./Models'?M:name==='./services/MediaServices'?{MediaServices:services}:name==='./SourcePlaybackLeases'?leaseModule:name==='./SourcePlaybackPolicy'?policyModule:{ProgressRepository:{loadForAccount:async()=>history}}});
const Navigation=navModule.exports.PlaybackNavigation;
function getMethod(name){const src=fs.readFileSync(base+'pages/PlayerPage.ets','utf8');const regex=new RegExp('  (?:private )?(?:async )?'+name+'\\(');const m=regex.exec(src);assert(m,name);const begin=src.indexOf('{',m.index);let depth=1,n=begin+1;for(;n<src.length&&depth;n++){if(src[n]==='{')depth++;else if(src[n]==='}')depth--;}return src.slice(m.index,n).replace(/^  private /,'  ');}
const methods=['requestSeek','suspendAiForSeek','resumeAiAfterSeek','updateAiFileCaption','handleScrub','canInteractWithTimeline','hideControls','seekBy','initializePreparedTracks','disableNativeSubtitles','currentSubtitleSelection','selectSubtitle','selectAudio','enterPip','episodePanelProgress','sideSourceQuality','sideSourceMetadata'];
const source='class Business { panelMounted=true;playbackGen=0;duration=100000;playPos=0;lastSeekTarget=-1;lastSeekAt=0;seekPending=false;queuedSeekTarget=-1;lastProgressAt=0;subtitles=[];curSubtitle=-1;curAudio=-1;audioTracks=[];nativeSubtitleIndices=[];subtitleSelectionGen=0;aiEnabled=false;stopAiCount=0;hideTimer=-1;errMsg="";pipCtl=null;switchingPlayback=false;barOpacity=1;locked=false;barShowCount=0;currentPlayer(gen,p){return gen===this.playbackGen && this.player===p && this.panelMounted;} scheduleHideBar(){} showBarTemporarily(){this.barShowCount++;} setPlayerStatusBarVisible(){} activeSurfaceController(){return {};} stopAiSubtitles(restore){this.stopAiCount++;this.lastAiRestore=restore;this.aiEnabled=false;} '+methods.map(getMethod).join('\n')+' } exports.Business=Business;';
const toasts=[];let pipFactory;
const businessModule={exports:{}};const context={exports:businessModule.exports,require:()=>({}),media:{SeekMode:{SEEK_PREV_SYNC:1},SwitchMode:{SMOOTH:0},MediaType:{MEDIA_TYPE_VID:1,MEDIA_TYPE_AUD:0,MEDIA_TYPE_SUBTITLE:2}},SliderChangeMode:{Begin:0,Moving:1,End:2,Click:3},TrackInfo:M.TrackInfo,hilog:{info(){},warn(){}},promptAction:{showToast(options){toasts.push(options.message);}},getContext:()=>({}),PiPWindow:{PiPTemplateType:{VIDEO_PLAY:0},isPiPEnabled:()=>true,create:async()=>pipFactory()},setTimeout,clearTimeout};vm.runInNewContext(compile(source),context);
class TestMpvAdapter { constructor(fileSize){this.core={surfaceController:{native:{getProperty:key=>key==='file-size'?fileSize:0}}};} }
context.MpvAdapter=TestMpvAdapter;
Object.assign(businessModule.exports.Business.prototype,{aiSession:null,aiFileCues:[],aiSeekSuspended:false});
(async()=>{
 const item=new M.MediaItem();item.id='episode-2';item.type='Episode';item.seriesId='series';item.name='ep2';detail=new M.ItemDetail();detail.item=item;const src=new M.MediaSource();src.id='version-2';detail.sources=[src];const embedded=new M.MediaStream();embedded.type='Subtitle';embedded.index=8;src.streams.push(embedded);const external=new M.MediaStream();external.type='Subtitle';external.index=9;external.isExternal=true;src.streams.push(external);const fnos=new M.ServerConfig('s','fnos','s','invalid',8005,'u','x','u','','');history=[{itemId:item.id,positionMs:45000}];playback=new M.PlaybackInfo();playback.url=services.directStreamUrl(fnos,item.id);const target=await Navigation.resolve(fnos,item,'',-1,false);assert.equal(target.positionMs,45000);assert.equal(target.subtitles.length,1);assert.equal(target.subtitles[0].isExternal,true);assert.equal(playbackCalls,1);await assert.rejects(Navigation.resolve(fnos,item,src.id,20000,true));const emby=new M.ServerConfig('s','emby','s','invalid',8005,'u','x','u','','');playback=new M.PlaybackInfo();playback.url=services.directStreamUrl(emby,item.id);const chosen=await Navigation.resolve(emby,item,src.id,20000,true);assert(chosen.url.endsWith('&MediaSourceId=version-2'));assert.equal(chosen.positionMs,20000);playback.mediaSourceId='other';await assert.rejects(Navigation.resolve(emby,item,src.id,20000,true));
 const b=new businessModule.exports.Business();const seeks=[];b.player={seek:p=>seeks.push(p)};b.handleScrub(5000,3);b.handleScrub(5000,2);assert.equal(seeks.length,1);b.handleScrub(15000,2);b.handleScrub(25000,2);assert.equal(seeks.length,1);assert.equal(b.queuedSeekTarget,25000);
 const blockedTimelineCases=[['hidden',{barOpacity:0}],['fade threshold',{barOpacity:0.5}],['locked',{locked:true}],['route left',{panelMounted:false}],['episode changing',{switchingPlayback:true}],['error visible',{errMsg:'connection failed'}]];
 for(const [label,state] of blockedTimelineCases){
  const page=new businessModule.exports.Business();const calls=[];page.player={seek:value=>calls.push(value)};Object.assign(page,state);
  assert.equal(page.canInteractWithTimeline(),false,label);
  for(const mode of [0,1,3,2]){page.isScrubbing=true;page.handleScrub(42000,mode);assert.equal(page.isScrubbing,false,label+' clears stale scrub state');}
  assert.equal(calls.length,0,label+' UI callbacks cannot seek');assert.equal(page.queuedSeekTarget,-1);
 }
 const hidden=new businessModule.exports.Business();const backgroundSeeks=[];hidden.player={seek:value=>backgroundSeeks.push(value)};
 hidden.isScrubbing=true;hidden.hideControls();assert.equal(hidden.isScrubbing,false);assert.equal(hidden.barOpacity,0);
 hidden.handleScrub(12000,2);assert.equal(backgroundSeeks.length,0,'Late UI End after hide cannot seek');
 hidden.locked=true;assert.equal(hidden.requestSeek(18000),true,'Generic seek remains available to AVSession while HUD is hidden/locked');assert.deepEqual(backgroundSeeks,[18000]);
 const c=new businessModule.exports.Business();let selected=[],added=0,chosenIndex=-1;const descs=Array.from({length:17},(_,n)=>({track_type:2,track_index:n+2,codec_mime:'ass',language:'chi'}));c.player={getTrackDescription:async()=>descs,getSelectedTracks:async()=>selected,selectTrack:async i=>{chosenIndex=i;selected=[i]},deselectTrack:async i=>{selected=selected.filter(v=>v!==i)},addSubtitleFromUrl:async()=>{added++}};await c.initializePreparedTracks(0,c.player);assert.equal(c.subtitles.length,17);assert.equal(c.subtitles[0].isExternal,false);assert.equal(c.subtitles[0].url,'');await c.selectSubtitle(3);assert.equal(chosenIndex,5);assert.equal(c.curSubtitle,3);assert.equal(added,0);await c.selectSubtitle(-1);assert.equal(c.curSubtitle,-1);assert.equal(selected.length,0);c.player.getSelectedTracks=async()=>{throw new Error('unknown')};await c.initializePreparedTracks(0,c.player);assert.equal(c.subtitles.length,17);assert.equal(c.curSubtitle,-2);
 assert(c.barShowCount>=2,'Subtitle actions must retain their HUD-show dependency');
 const Business=businessModule.exports.Business;
 // A server-generated URL for an embedded track must not create a second copy
 // beside the real native track. Repeated preparation is idempotent.
 const catalogSubs=new Business();catalogSubs.subtitles=[{index:2,language:'en',title:'embedded via server',isExternal:false,url:'/same-embedded.srt'},{index:99,language:'ja',title:'external',isExternal:true,url:'/external.srt'}];catalogSubs.player={getTrackDescription:async()=>descs,getSelectedTracks:async()=>[],deselectTrack:async()=>{}};
 await catalogSubs.initializePreparedTracks(0,catalogSubs.player);assert.equal(catalogSubs.subtitles.length,18);assert.equal(catalogSubs.subtitles.filter(track=>!track.isExternal&&track.index===2).length,1);assert.equal(catalogSubs.subtitles.filter(track=>track.isExternal).length,1);assert.equal(catalogSubs.subtitles.at(-1).url,'/external.srt');await catalogSubs.initializePreparedTracks(0,catalogSubs.player);assert.equal(catalogSubs.subtitles.length,18);
 const subtitleFixture=()=>{const page=new Business();page.subtitles=[{index:2,language:'en',title:'English',isExternal:false,url:''},{index:3,language:'ja',title:'Japanese',isExternal:false,url:''}];return page};
 // Native commands are submitted in order, while their confirmations may arrive
 // late. Only the latest same-player operation may update the UI or toast.
 const fast=subtitleFixture();let nativeSelected=[],finishOldSelection;fast.player={selectTrack:index=>{nativeSelected=[index];return index===2?new Promise(resolve=>{finishOldSelection=resolve}):Promise.resolve()},getSelectedTracks:async()=>nativeSelected};const oldSubtitle=fast.selectSubtitle(0);await fast.selectSubtitle(1);assert.equal(fast.curSubtitle,1);finishOldSelection();await oldSubtitle;assert.equal(fast.curSubtitle,1,'Late same-session selection cannot overwrite the latest selection');
 const failedOld=subtitleFixture();let failOldSelection;nativeSelected=[];failedOld.player={selectTrack:index=>{nativeSelected=[index];return index===2?new Promise((_resolve,reject)=>{failOldSelection=reject}):Promise.resolve()},getSelectedTracks:async()=>nativeSelected};const oldSubtitleFailure=failedOld.selectSubtitle(0);await failedOld.selectSubtitle(1);const beforeOldSubtitleToast=toasts.length;failOldSelection(Error('late old selection'));await oldSubtitleFailure;assert.equal(failedOld.curSubtitle,1);assert.equal(toasts.length,beforeOldSubtitleToast,'Superseded failures are not reported against the current selection');
 const fastClose=subtitleFixture();fastClose.curSubtitle=0;let finishOldClose;nativeSelected=[2];fastClose.player={getTrackDescription:async()=>descs,getSelectedTracks:async()=>nativeSelected,deselectTrack:()=>{nativeSelected=[];return new Promise(resolve=>{finishOldClose=resolve})},selectTrack:async index=>{nativeSelected=[index]}};const oldClose=fastClose.selectSubtitle(-1);for(let n=0;n<100&&typeof finishOldClose!=='function';n++)await Promise.resolve();assert.equal(typeof finishOldClose,'function');await fastClose.selectSubtitle(1);finishOldClose();await oldClose;assert.equal(fastClose.curSubtitle,1,'A late close cannot clear a newer subtitle choice');
 const preparedRace=subtitleFixture();let finishOldDescription;nativeSelected=[];preparedRace.player={getTrackDescription:()=>new Promise(resolve=>{finishOldDescription=resolve}),selectTrack:async index=>{nativeSelected=[index]},getSelectedTracks:async()=>nativeSelected};const oldPrepared=preparedRace.initializePreparedTracks(0,preparedRace.player);await preparedRace.selectSubtitle(1);finishOldDescription(descs);await oldPrepared;assert.equal(preparedRace.curSubtitle,1,'Late prepared metadata cannot reset the user choice');assert.equal(preparedRace.subtitles.length,2);
 const aiToNative=subtitleFixture();aiToNative.aiEnabled=true;nativeSelected=[];aiToNative.player={selectTrack:async index=>{nativeSelected=[index]},getSelectedTracks:async()=>nativeSelected};await aiToNative.selectSubtitle(0);assert.equal(aiToNative.stopAiCount,1);assert.equal(aiToNative.lastAiRestore,false,'Native subtitle selection stops AI without restoring an older native choice');assert.equal(aiToNative.curSubtitle,0);
 const audio=new Business();let pickedAudio=-1;audio.curAudio=3;audio.player={selectTrack:async index=>{pickedAudio=index;}};
 await audio.selectAudio(new M.TrackInfo(8,'audio8'));assert.equal(pickedAudio,8);assert.equal(audio.curAudio,8);assert.equal(audio.barShowCount,1);
 let finishSelection;const oldPlayer={selectTrack:()=>new Promise(resolve=>{finishSelection=resolve;})};audio.player=oldPlayer;
 const lateSuccess=audio.selectAudio(new M.TrackInfo(9,'old audio'));audio.playbackGen++;audio.player={};audio.curAudio=44;finishSelection();await lateSuccess;
 assert.equal(audio.curAudio,44,'Late old-session success cannot change the new audio checkmark');
 let failSelection;audio.player={selectTrack:()=>new Promise((_resolve,reject)=>{failSelection=reject;})};
 const lateFailure=audio.selectAudio(new M.TrackInfo(10,'old audio'));audio.playbackGen++;audio.player={};audio.curAudio=45;
 const beforeLateToast=toasts.length;failSelection(new Error('old player released'));await lateFailure;
 assert.equal(audio.curAudio,45);assert.equal(toasts.length,beforeLateToast,'Old-session failures must not toast in a new session');assert.equal(audio.errMsg,'');
 audio.player={selectTrack:async()=>{throw new Error('cannot select');}};const beforeAudioToast=toasts.length;
 await audio.selectAudio(new M.TrackInfo(11,'unavailable audio'));assert.equal(audio.curAudio,45);assert.equal(audio.errMsg,'','Audio operation errors cannot set fatal playback state');assert.equal(toasts.length,beforeAudioToast+1);
 function controller(overrides={}){return Object.assign({stopCount:0,on(){},async startPiP(){},async stopPiP(){this.stopCount++;},async isPiPActive(){return true;},async getPiPSettingSwitch(){return true;}},overrides);}
 const pip=new Business();pip.player={state:'playing'};let ctl=controller({async startPiP(){throw {code:1300005};}});pipFactory=()=>ctl;
 const beforePipToast=toasts.length;await pip.enterPip();assert.equal(pip.errMsg,'','PiP errors cannot become fatal playback errors');assert.equal(pip.player.state,'playing');assert.equal(toasts.length,beforePipToast+1,'PiP start failures must be visible');
 // The existing-controller branch must also route failures to a nonfatal toast.
 const beforeExistingToast=toasts.length;await pip.enterPip();assert.equal(toasts.length,beforeExistingToast+1);assert.equal(pip.errMsg,'');
 pip.pipCtl=null;ctl=controller({async isPiPActive(){return false;}});pipFactory=()=>ctl;
 const beforeInactiveToast=toasts.length;await pip.enterPip();assert.equal(toasts.length,beforeInactiveToast+1,'Inactive PiP must not silently claim success');assert.equal(pip.errMsg,'');
 pip.pipCtl=null;ctl=controller({async startPiP(){throw {code:1300013};}});pipFactory=()=>ctl;
 const beforeAlreadyStartedToast=toasts.length;await pip.enterPip();assert.equal(toasts.length,beforeAlreadyStartedToast,'Only known already-started status is tolerated');assert.equal(pip.errMsg,'');
 pip.pipCtl=null;let finishCreate;ctl=controller();pipFactory=()=>new Promise(resolve=>{finishCreate=resolve;});
 const stalePip=pip.enterPip();pip.playbackGen++;const beforeStalePipToast=toasts.length;finishCreate(ctl);await stalePip;
 assert.equal(ctl.stopCount,1,'Late PiP creation is stopped after route/session replacement');assert.equal(pip.pipCtl,null);assert.equal(toasts.length,beforeStalePipToast);assert.equal(pip.errMsg,'');
 const panel=new Business();panel.itemId='current';panel.duration=100000;panel.playPos=25000;
 const routeEpisode=JSON.parse(JSON.stringify(Object.assign(new M.MediaItem(),{id:'other',runtimeTicks:10000000,progressTicks:5000000})));
 assert.equal(typeof routeEpisode.progressRatio,'undefined','Fixture must reproduce router plain data without prototype');
 assert.equal(panel.episodePanelProgress(routeEpisode),0.5,'Non-current unfinished episode uses plain numeric fields');
 assert.equal(panel.episodePanelProgress({...routeEpisode,id:'current'}),0.25,'Current episode uses live player progress');
 assert.equal(panel.episodePanelProgress({...routeEpisode,played:true}),1);
 for(const duration of [0,-1,NaN,Infinity])assert.equal(panel.episodePanelProgress({...routeEpisode,runtimeTicks:duration}),0);
 for(const position of [NaN,Infinity,-10])assert.equal(panel.episodePanelProgress({...routeEpisode,progressTicks:position}),0);
 assert.equal(panel.episodePanelProgress({...routeEpisode,progressTicks:20000000}),1,'History overshoot is clamped');
 panel.playPos=200000;assert.equal(panel.episodePanelProgress({...routeEpisode,id:'current'}),1,'Current overshoot is clamped');
 panel.playPos=-100;assert.equal(panel.episodePanelProgress({...routeEpisode,id:'current'}),0);
 const routeSource=new M.MediaSource();routeSource.id='plain-source';routeSource.sizeBytes=2*1073741824;
 const video=new M.MediaStream();video.type='Video';video.height=1080;video.bitrate=4500000;video.frameRate=23.976;video.videoRange='HDR';routeSource.streams.push(video);
 const plainSource=JSON.parse(JSON.stringify(routeSource));
 assert.equal(typeof plainSource.videoStream,'undefined');assert.equal(typeof plainSource.streams[0].qualityLabel,'undefined');
 assert.equal(panel.sideSourceQuality(plainSource),'1080P');
 assert.equal(panel.sideSourceMetadata(plainSource),'2.00 GB  4.5 Mbps  23.98fps  HDR');
 const emptySource=JSON.parse(JSON.stringify(new M.MediaSource()));emptySource.id='empty';
 assert.equal(panel.sideSourceQuality(emptySource),'原画');assert.equal(panel.sideSourceMetadata(emptySource),'');
 plainSource.sizeBytes=0;plainSource.streams[0].bitrate=0;plainSource.streams[0].frameRate=0;plainSource.streams[0].videoRange='';plainSource.streams[0].isHdr=true;
 assert.equal(panel.sideSourceMetadata(plainSource),'HDR','Explicit HDR boolean remains available on plain metadata');
 plainSource.streams[0].isHdr=false;panel.selectedSourceId=plainSource.id;panel.player=new TestMpvAdapter(3*1073741824);panel.technicalFields=['','','24fps','','','SDR'];
 assert.equal(panel.sideSourceMetadata(plainSource),'3.00 GB  24fps  SDR','Active-source fallbacks use native facts after plain source parsing');
 console.log('PASS: provider-aware targets/history/source IDs; native subtitle population/select/close, embedded-URL dedup, same-session selection/close/prepared races and AI-to-native handoff; Slider dedup/queue and hidden/locked/left/switching/error UI guards without blocking generic AVSession seek; audio generation/nonfatal errors; PiP errors/late cleanup; plain-router episode progress and source metadata. Actual Page methods with SDK/UI mocks; no network/device calls or HAP compile.');
})().catch(e=>{console.error(e);process.exitCode=1});
