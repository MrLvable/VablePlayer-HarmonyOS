const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const file=projectFile('entry/src/main/ets/pages/PlayerPage.ets');
const source=fs.readFileSync(file,'utf8');
function method(name){const match=new RegExp('  (?:private )?(?:async )?'+name+'\\(').exec(source);assert(match,name);const start=source.indexOf('{',match.index);let depth=1,end=start+1;for(;depth&&end<source.length;end++){if(source[end]==='{')depth++;else if(source[end]==='}')depth--;}return source.slice(match.index,end).replace(/^  private /,'  ');}
let clock=0,onTimer=null;
class MockDate extends Date {static now(){return clock;}}
const mockSetTimeout=(callback,delay)=>{clock+=delay;if(onTimer)onTimer();Promise.resolve().then(callback);return 1;};
const context={exports:{},Date:MockDate,MpvAdapter:class{},media:{VideoScaleType:{VIDEO_SCALE_TYPE_FIT_CROP:1,VIDEO_SCALE_TYPE_SCALED_ASPECT:2},SeekMode:{SEEK_PREV_SYNC:0}},audio:{InterruptMode:{INDEPENDENT_MODE:1}},hilog:{info(){},warn(){}},setTimeout:mockSetTimeout,clearTimeout(){}};
const code=`class Page {
 pendingSelectedSourceId='';selectedSourceId='';switchingPlayback=false;
 duration=0;desiredResumeMs=850680;resumeSeeked=false;resumeSeekPending=false;
 fitCrop=false;info='';seekPending=false;lastSeekTarget=-1;lastSeekAt=0;queuedSeekTarget=-1;playPos=0;
 player=null;plays=0;failures=[];afterTracks=async()=>{};
 currentPlayer(gen,p){return gen===1&&this.player===p;}
 buildInfo(){return '';}
 autoOrient(){}
 async initializePreparedTracks(gen,p){await this.afterTracks(p);}
 playCurrent(gen,p){this.plays++;}
 suspendAiForSeek(){}
 resumeAiAfterSeek(){}
 handlePlaybackFailure(gen,message,code){this.failures.push({gen,message,code});}
 ${method('startPreparedPlayback')}
 ${method('requestSeek')}
}
exports.Page=Page;`;
const out=ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(out.diagnostics.length,0);vm.runInNewContext(out.outputText,context);
function fixture(duration){clock=10000;onTimer=null;const page=new context.exports.Page();const seeks=[];const player={duration,width:0,height:0,engineKind:'mpv',seek:(position)=>seeks.push(position)};page.player=player;return {page,player,seeks};}
async function check(name,run){try{await run();console.log('PASS: '+name);}catch(error){console.error('FAIL: '+name+' — '+error.message);process.exitCode=1;}}
(async()=>{
 await check('known prepared duration seeks to requested resume before play',async()=>{const {page,player,seeks}=fixture(2625835);await page.startPreparedPlayback(1,player);assert.deepEqual(seeks,[850680]);assert.equal(page.plays,0);assert.equal(page.resumeSeekPending,true);});
 await check('duration arriving during track initialization still seeks',async()=>{const {page,player,seeks}=fixture(0);page.afterTracks=async()=>{player.duration=2625835;};await page.startPreparedPlayback(1,player);assert.deepEqual(seeks,[850680],'latest duration must also reach requestSeek duration guard');assert.equal(page.plays,0);});
 await check('unknown duration fails within bound without consuming resume or starting from zero',async()=>{const {page,player,seeks}=fixture(0);const start=clock;await page.startPreparedPlayback(1,player);assert.equal(seeks.length,0);assert.equal(page.resumeSeeked,false);assert.equal(page.plays,0);assert.equal(page.failures.length,1);assert.equal(clock-start,3000);});
 await check('duration arriving during bounded wait seeks before playing',async()=>{const {page,player,seeks}=fixture(0);const start=clock;onTimer=()=>{if(clock-start>=150)player.duration=2625835;};await page.startPreparedPlayback(1,player);assert.deepEqual(seeks,[850680]);assert.equal(page.duration,2625835);assert.equal(page.plays,0);assert.equal(page.failures.length,0);});
 await check('closing while awaiting tracks never seeks or plays',async()=>{const {page,player,seeks}=fixture(2625835);page.afterTracks=async()=>{page.player=null;};await page.startPreparedPlayback(1,player);assert.equal(seeks.length,0);assert.equal(page.plays,0);assert.equal(page.failures.length,0);});
 await check('closing during duration wait never seeks, plays or reports a stale failure',async()=>{const {page,player,seeks}=fixture(0);onTimer=()=>{page.player=null;player.duration=2625835;};await page.startPreparedPlayback(1,player);assert.equal(seeks.length,0);assert.equal(page.plays,0);assert.equal(page.failures.length,0);});
 await check('explicit start from beginning does not seek',async()=>{const {page,player,seeks}=fixture(2625835);page.desiredResumeMs=0;await page.startPreparedPlayback(1,player);assert.equal(seeks.length,0);assert.equal(page.plays,1);});
 await check('stale generation does not seek or play',async()=>{const {page,player,seeks}=fixture(2625835);await page.startPreparedPlayback(2,player);assert.equal(seeks.length,0);assert.equal(page.plays,0);});
 console.log('Extracts current PlayerPage business methods; mocked engine only, no device/network/build calls.');
})().catch(error=>{console.error(error);process.exitCode=1;});
