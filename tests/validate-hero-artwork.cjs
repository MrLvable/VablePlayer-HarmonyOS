'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const pageSource = fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(pageSource);
  assert(match, name); const start = pageSource.indexOf('{', match.index);
  let depth = 1, end = start + 1;
  for (; depth; end++) { if (pageSource[end] === '{') depth++; else if (pageSource[end] === '}') depth--; }
  return pageSource.slice(match.index, end).replace(/^  private /, '  ');
}
function compile(source, context) {
  const result = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal(result.diagnostics.length, 0);
  vm.runInNewContext(result.outputText, context); return context.exports;
}
const { HeroArtwork, HeroPullTracker } = compile(
  fs.readFileSync(projectFile('entry/src/main/ets/common/HeroArtwork.ets'), 'utf8'), { exports: {}, Number });
const touchTypes = { Down: 0, Move: 1, Up: 2, Cancel: 3 };
let render = false, reduce = false, nextTask = 0, onCommit = () => {};
const tasks = new Map(), animations = [];
const methods = ['onArtworkPullTouch', 'commitArtworkPull', 'detailPullAllowed', 'syncDetailPull', 'cancelArtworkPull',
  'onHomeScroll', 'homeScrollAllowed', 'commitHomeScroll', 'syncHomeScroll', 'queueHomeScrollSync',
  'cancelHomeScrollSync', 'onShellChange', 'onPageHide', 'onPageShow', 'detailArtworkHeight', 'onDetailArtworkSize',
  'detailDisplayHeight', 'detailArtworkWidth', 'heroDisplayHeight',
  'detailBackdropScope', 'detailArtworkFeatherStops', 'detailBackdropVeilStops'];
const { Page } = compile(`class Page {
  homeScrollMounted=true;homeScrollPageVisible=true;appActive=true;currentTab=0;
  showAdd=false;showSearch=false;showDownloads=false;locked=false;detailItem=null;browsingLib=null;
  homeScrollTask=-1;homeScrollGeneration=0;pendingHomeScrollY=Number.NaN;
  detailPullTask=-1;detailPullGeneration=0;heroScrollP=0;heroTouching=false;current=null;
  detailArtworkSizeTask=-1;pendingDetailArtworkRatio=16/9;
  homePull=new HeroPullTracker();detailPull=new HeroPullTracker();_ratio=16/9;
  _home=0;_detail=0;writes=[];url='current-backdrop';_dark=true;
  get homeArtworkPull(){return this._home}
  set homeArtworkPull(value){outsideRender();this._home=value;this.writes.push(['home',value]);stateCommitted(this)}
  get detailArtworkPull(){return this._detail}
  set detailArtworkPull(value){outsideRender();this._detail=value;this.writes.push(['detail',value]);stateCommitted(this)}
  get detailArtworkRatio(){return this._ratio}
  set detailArtworkRatio(value){outsideRender();this._ratio=value}
  stackNames(){return []}heroArtworkHeight(){return 460}clamp01(value){return Math.max(0,Math.min(1,value))}
  syncHeroTimer(){}stopHeroTimer(){}restartHeroTimer(){}loadResume(){}
  invalidateSourceRequest(){}cancelLaunchIntro(){}
  detailArtworkUrl(){return this.url}
  dark(){return this._dark}
  detailArtworkScope(){return 'server:user:episode-series'}
  ${methods.map(method).join('\n')}
} exports.Page=Page;`, {
  exports: {}, Number, HeroArtwork, HeroPullTracker, TouchType: touchTypes,
  withAlpha: (color, alpha) => color + '@' + alpha,
  MotionPref: { reduce: () => reduce, dur: value => reduce ? 80 : value },
  MotionSpec: { imageReadyFrame: 16, hero: 420 },
  curves: {springMotion: (response, damping) => ({kind:'spring',response,damping})}, Curve: { EaseOut: 'out' }, Metrics: { width: () => 440 },
  outsideRender() { assert.equal(render, false, 'render/layout callbacks cannot write image State'); },
  stateCommitted: page => onCommit(page),
  animateTo(options, action) { assert.equal(render, false); animations.push(options); action(); },
  setTimeout(action, delay) { assert.equal(delay, 16); const id = ++nextTask; tasks.set(id, action); return id; },
  clearTimeout: id => tasks.delete(id)
});
function fixture(detail = false) {
  tasks.clear(); animations.length = 0; render = false; reduce = false; onCommit = () => {};
  const p = new Page();
  if (detail) p.detailItem = { id: 'episode-series' };
  p.homeScroller = p.detailScroller = { currentOffset: () => ({ yOffset: 0 }) };
  return p;
}
function event(type, x = 100, y = 200) { return { type: touchTypes[type], touches: [{ windowX: x, windowY: y }] }; }
function flush(p, detail = false) {
  const id = detail ? p.detailPullTask : p.homeScrollTask;
  const action = tasks.get(id); assert(action, 'queued image sync'); tasks.delete(id); action();
}
let passed = 0;
function test(name, action) { action(); passed++; console.log('PASS: ' + name); }

test('shared reveal extension follows a constant linear slope up to its safety bound', () => {
  let previous=0; const width=440,limit=width*.85;
  for(let offset=0;offset>=-100000;offset-=10){
    const extension=HeroArtwork.pullExtension(offset,width,false);
    assert(extension>=previous&&extension<=limit);previous=extension;
  }
  for(const value of [0,1,999,NaN,Infinity,-Infinity]) assert.equal(HeroArtwork.pullExtension(value,width,false),0);
  assert.equal(HeroArtwork.pullExtension(-200,width,true),0);
  assert.equal(HeroArtwork.pullExtension(-100,width,false),100);
  assert(HeroArtwork.pullExtension(-500,width,false)>width*.7);
  for(const pull of [10,50,100,200,280,320,360]) assert.equal(HeroArtwork.pullExtension(-pull,width,false),pull);
  assert.equal(HeroArtwork.pullExtension(-100000,width,false),limit);
});

test('home/detail equal finger steps produce equal image steps and never animate during dragging', () => {
  for(const detail of [false,true]){
    const p=fixture(detail);p.onArtworkPullTouch(event('Down'),detail);
    let previous=0;
    for(const distance of [100,200,300,400,500,600]){
      p.onArtworkPullTouch(event('Move',100,200+distance),detail);flush(p,detail);
      const actual=detail?p.detailArtworkPull:p.homeArtworkPull;
      assert(Math.abs(actual-distance*.55)<1e-8);
      assert(Math.abs(actual-previous-55)<1e-8);previous=actual;
      assert.equal(animations.length,0,'Finger tracking never starts an implicit animation');
    }
    p.onArtworkPullTouch(event('Up'),detail);flush(p,detail);
    assert.equal(animations.length,1,'Only release starts the shared spring');
    assert.equal(detail?p.detailArtworkPull:p.homeArtworkPull,0);
  }
});
test('passive tracker follows top-edge vertical pulls and axis-locks horizontal Swiper movements', () => {
  const t = new HeroPullTracker();
  t.begin(0, 0, 0); t.move(1, 100); assert(Math.abs(t.offset + 55) < 1e-8);
  t.move(1, 20); assert(Math.abs(t.offset + 11) < 1e-8); t.move(1, -20); assert.equal(t.offset, 0);
  t.finish(); assert.equal(t.offset, 0); assert.equal(t.releasing, true);
  t.begin(0, 0, 0); t.move(80, 20); t.move(90, 150); assert.equal(t.offset, 0);
  t.begin(0, 0, 100); t.move(0, 200); assert.equal(t.offset, 0);
  t.begin(0, 0, NaN); assert.equal(t.active, false);
  t.begin(0, 0, -20); t.move(0, 50); assert(t.offset < 0);
});
test('home actual touch and scroll methods coalesce outside render even when Scroller clamps overscroll to zero', () => {
  const p = fixture(); p.onArtworkPullTouch(event('Down'), false);
  p.onArtworkPullTouch(event('Move', 101, 300), false);
  render = true; for (let n = 0; n < 20; n++) p.syncHomeScroll(); render = false;
  assert.equal(p.writes.length, 0); assert.equal(tasks.size, 1);
  flush(p); assert(p.homeArtworkPull > 0); assert.equal(p.detailArtworkPull, 0);
  p.onArtworkPullTouch(event('Up'), false); assert(p.homeArtworkPull > 0); flush(p);
  assert.equal(p.homeArtworkPull, 0); assert.equal(animations.length, 1);
  assert.equal(animations[0].curve.kind,'spring');
  assert.equal(animations[0].curve.response,HeroArtwork.returnResponse);
  assert.equal(animations[0].curve.damping,HeroArtwork.returnDamping);
});
test('detail shares the same pull curve and returns smoothly after cancel; plain browsing never zooms', () => {
  const p = fixture(true); p.onArtworkPullTouch(event('Down'), true);
  p.onArtworkPullTouch(event('Move', 100, 300), true);
  render = true; p.syncDetailPull(); render = false;
  assert.equal(p.writes.length, 0); flush(p, true);
  assert(Math.abs(p.detailArtworkPull - HeroArtwork.pullExtension(-55, 440, false)) < 1e-8);
  p.onArtworkPullTouch(event('Cancel'), true); flush(p, true);
  assert.equal(p.detailArtworkPull, 0); assert.equal(animations.length, 1);
  p.onArtworkPullTouch(event('Down'), true); p.onArtworkPullTouch(event('Move', 100, 120), true); flush(p, true);
  assert.equal(p.detailArtworkPull, 0);
});
test('page hiding invalidates old detail callbacks; returning to another item cannot clear its new task', () => {
  const p = fixture(true); p.onArtworkPullTouch(event('Down'), true); p.onArtworkPullTouch(event('Move', 100, 360), true);
  const oldId = p.detailPullTask, late = tasks.get(oldId); p.onPageHide();
  assert.equal(tasks.has(oldId), false); assert.equal(p.detailArtworkPull, 0);
  p.homeScrollPageVisible = true; p.detailItem = { id: 'different-series' };
  p.onArtworkPullTouch(event('Down'), true); p.onArtworkPullTouch(event('Move', 100, 280), true);
  const newId = p.detailPullTask; late(); assert.equal(p.detailPullTask, newId); flush(p, true);
  assert(p.detailArtworkPull > 0);
});
test('shell changes and background guards stop zoom; reduce-motion keeps both image layers still', () => {
  const p = fixture(); p.onArtworkPullTouch(event('Down'), false); p.onArtworkPullTouch(event('Move', 100, 400), false);
  flush(p); assert(p.homeArtworkPull > 0); p.currentTab = 2; p.onShellChange();
  assert.equal(p.homeArtworkPull, 0); assert.equal(tasks.size, 0);
  const d = fixture(true); d.onArtworkPullTouch(event('Down'), true); d.onArtworkPullTouch(event('Move', 100, 400), true);
  d.appActive = false; flush(d, true); assert.equal(d.detailArtworkPull, 0);
  const reduced = fixture(); reduce = true;
  reduced.onArtworkPullTouch(event('Down'), false); reduced.onArtworkPullTouch(event('Move', 100, 400), false); flush(reduced);
  assert.equal(reduced.homeArtworkPull, 0);
});
test('complete foreground uses decoded image dimensions with safe tall-image cap and rejects stale or invalid sizes', () => {
  const p = fixture(true), scope = 'server:user:episode-series';
  function size(url, width, height, identity = scope) {
    render = true; p.onDetailArtworkSize(url, identity, width, height); render = false;
    const id = p.detailArtworkSizeTask, action = tasks.get(id);
    if (action) { tasks.delete(id); action(); }
  }
  size('current-backdrop', 1920, 1080);
  assert.equal(p.detailArtworkHeight(), 247.5);
  size('old-backdrop', 1000, 1500); assert.equal(p.detailArtworkHeight(), 247.5);
  size('current-backdrop', 1000, 1500, 'different-server:user:episode-series'); assert.equal(p.detailArtworkHeight(), 247.5);
  size('current-backdrop', 1000, 1500); assert(Math.abs(p.detailArtworkHeight() - 506) < 1e-8);
  size('current-backdrop', 0, 1080); assert.equal(p.detailArtworkRatio, 2 / 3);
  assert.equal(HeroArtwork.imageHeight(NaN, NaN), 247.5);
  const builder = method('detailHeroArtwork'); assert.match(builder, /fit:\s*ImageFit\.Contain/);
  assert.match(builder, /width\(this\.detailArtworkWidth\(\)\)\.height\(this\.detailDisplayHeight\(\)\)/);
  assert.doesNotMatch(builder,/margin\(\{ top: this\.safeTopVp/);
  const detail = method('detailView'); assert.match(detail, /Scroll\(this\.detailScroller\)/);
  assert.match(detail, /\.onDidScroll\(\(\) => \{ this\.syncDetailPull\(\); \}\)/);
  assert.doesNotMatch(detail, /margin\(\{ top: 170 \}\)/);
});
test('cached image size delivery waits a turn; canceled old callback cannot mutate the next detail', () => {
  const p = fixture(true), scope = 'server:user:episode-series';
  render = true; p.onDetailArtworkSize('current-backdrop', scope, 1000, 1500); render = false;
  assert.equal(p.detailArtworkRatio, 16 / 9);
  const oldId = p.detailArtworkSizeTask, late = tasks.get(oldId);
  p.onPageHide(); assert.equal(tasks.has(oldId), false);
  p.homeScrollPageVisible = true; p.onDetailArtworkSize('current-backdrop', scope, 2000, 1000);
  const newId = p.detailArtworkSizeTask; late(); assert.equal(p.detailArtworkSizeTask, newId);
  const action = tasks.get(newId); tasks.delete(newId); action(); assert.equal(p.detailArtworkRatio, 2);
});
test('multitouch cancels the passive pull and never introduces a pinch recognizer or permanent zoom', () => {
  const p = fixture(); p.onArtworkPullTouch(event('Down'), false);
  p.onArtworkPullTouch(event('Move', 100, 400), false); flush(p); assert(p.homeArtworkPull > 0);
  p.onArtworkPullTouch({type: touchTypes.Down, touches: [{windowX:100,windowY:400},{windowX:200,windowY:400}]}, false);
  flush(p); assert.equal(p.homeArtworkPull, 0); assert.equal(p.homePull.active, false);
});
test('two decoded URLs within one render turn coalesce to the current artwork rather than losing its dimensions', () => {
  const p = fixture(true), scope = 'server:user:episode-series';
  render = true;
  p.onDetailArtworkSize('current-backdrop', scope, 1000, 1500);
  const id = p.detailArtworkSizeTask;
  p.url = 'new-backdrop';
  p.onDetailArtworkSize('new-backdrop', scope, 2000, 1000);
  p.onDetailArtworkSize('current-backdrop', scope, 1000, 1500);
  render = false;
  assert.equal(tasks.size, 1); assert.equal(p.detailArtworkSizeTask, id);
  assert.equal(p.detailArtworkRatio, 16 / 9);
  const action = tasks.get(id); tasks.delete(id); action();
  assert.equal(p.detailArtworkRatio, 2, 'new URL dimensions survive the old timer handle');
});
test('home/detail Scroll keep native displacement off while zero-offset passive pulls reveal the Hero', () => {
  for (const [builder, detail] of [['catalogHomeView', false], ['detailView', true]]) {
    const view = method(builder);
    assert.match(view, /\.edgeEffect\(EdgeEffect\.None\)/, builder + ': native content does not spring down');
    assert.doesNotMatch(view, /\.edgeEffect\(EdgeEffect\.Spring/, builder);
    assert.match(view, new RegExp('onArtworkPullTouch\\(event, ' + detail + '\\)'), builder + ': touch observation remains bound');
    const p = fixture(detail);
    p.onArtworkPullTouch(event('Down'), detail);
    p.onArtworkPullTouch(event('Move', 101, 400), detail);
    flush(p, detail);
    assert((detail ? p.detailArtworkPull : p.homeArtworkPull) > 0, builder + ': no negative native offset is required');
    assert.equal(p.heroScrollP, 0, builder + ': logical content offset stays at the top');
    p.onArtworkPullTouch(event('Up'), detail); flush(p, detail);
    assert.equal(detail ? p.detailArtworkPull : p.homeArtworkPull, 0);
    assert.equal(animations.length, 1, builder + ': image retains release animation');
  }
});
test('controlled Hero height moves the following content; normal scroll progress still uses the fixed resting height', () => {
  const p=fixture(); assert.equal(p.heroDisplayHeight(),460);
  p.homeArtworkPull=220; assert.equal(p.heroDisplayHeight(),680);
  p.homePull.offset=-220; p.commitHomeScroll(230);
  assert.equal(p.heroScrollP,.5,'reveal height never changes normal scroll normalization');
  const home=method('catalogHomeView'); assert.match(home,/height\(this\.heroDisplayHeight\(\)\)/);
  assert.doesNotMatch(method('heroSlide'),/scale\(/,'portrait cover naturally reveals/zooms as the frame grows');
  const d=fixture(true); d.detailArtworkPull=150;
  assert.equal(d.detailDisplayHeight(),d.detailArtworkHeight()+150);
  assert.match(method('detailView'),/height\(this\.detailDisplayHeight\(\)\)/);
});
test('detail starts complete at the top and grows with a constant source aspect rather than a sudden fit switch', () => {
  for(const ratio of [16/9,2/3,3]){
    const p=fixture(true); p.detailArtworkRatio=ratio;
    assert(p.detailArtworkWidth()<=440+.0001);
    for(const extension of [0,1,100,350]){
      p.detailArtworkPull=extension;
      assert(Math.abs(p.detailArtworkWidth()/p.detailDisplayHeight()-ratio)<1e-8);
    }
  }
  const builder=method('detailHeroArtwork');
  assert.match(builder,/position\(\{ x: \(Metrics\.width\(\) - this\.detailArtworkWidth\(\)\) \/ 2, y: 0 \}\)/);
  assert.doesNotMatch(builder,/safeTopVp/,'foreground starts at top; toolbar remains a separate overlaid row');
});
test('layout callbacks caused by reveal commits settle once; fast release and cancel cannot leave stale extension', () => {
  const p=fixture();
  onCommit=subject=>{render=true;subject.syncHomeScroll();render=false;};
  p.onArtworkPullTouch(event('Down'),false);
  for(const y of [240,280,340]){
    p.onArtworkPullTouch(event('Move',100,y),false);flush(p);
    assert.equal(tasks.size,1);flush(p);assert.equal(tasks.size,0);
  }
  const before=p.writes.length;
  p.onArtworkPullTouch(event('Up'),false);flush(p);flush(p);
  assert.equal(p.homeArtworkPull,0);assert.equal(p.writes.length,before+1);
  const fast=fixture();fast.onArtworkPullTouch(event('Down'),false);
  fast.onArtworkPullTouch(event('Move',100,650),false);fast.onArtworkPullTouch(event('Up'),false);flush(fast);
  assert.equal(fast.homeArtworkPull,0);assert.equal(fast.writes.length,0,'sub-frame gesture does not flash a delayed maximum');
  fast.onArtworkPullTouch(event('Down'),false);fast.onArtworkPullTouch(event('Move',100,600),false);
  const id=fast.homeScrollTask,late=tasks.get(id);fast.onPageHide();late();
  assert.equal(fast.homeArtworkPull,0);assert.equal(tasks.size,0);
});
test('detail foreground feathers into the actual decoded backdrop instead of ending at an opaque black rectangle', () => {
  const p=fixture(true), stops=p.detailArtworkFeatherStops();
  assert.equal(stops[0][1],0); assert.equal(stops.at(-1)[1],1);
  assert.equal(Number(stops[0][0].split('@')[1]),1);
  assert.equal(Number(stops.at(-1)[0].split('@')[1]),0);
  for(let i=1;i<stops.length;i++){
    assert(stops[i][1]>stops[i-1][1]);
    assert(Number(stops[i][0].split('@')[1])<=Number(stops[i-1][0].split('@')[1]));
  }
  const foreground=method('detailHeroArtwork');
  assert.match(foreground,/detailArtworkFeatherStops\(\)/); assert.match(foreground,/BlendMode\.DST_IN/);
  assert.match(foreground,/BlendMode\.SRC_OVER/); assert.match(foreground,/fit:\s*ImageFit\.Contain/);
});
test('dark and light detail veils remain translucent over the whole decoded image and use account-isolated fade layers', () => {
  const p=fixture(true);
  for(const dark of [true,false]){
    p._dark=dark;
    const stops=p.detailBackdropVeilStops();
    assert.equal(stops[0][1],0);assert.equal(stops.at(-1)[1],1);
    for(const [color,position] of stops){
      assert(color.startsWith(dark?'#000000@':'#FFFFFF@'));
      const alpha=Number(color.split('@')[1]); assert(alpha>=0&&alpha<.5); assert(position>=0&&position<=1);
    }
  }
  p.current={id:'server-A',userId:'account-1'};
  assert.equal(p.detailBackdropScope(),'server-A:account-1');
  p.detailItem={id:'another-film'};assert.equal(p.detailBackdropScope(),'server-A:account-1');
  p.current={id:'server-A',userId:'account-2'};assert.equal(p.detailBackdropScope(),'server-A:account-2');
  const background=method('detailBackdrop');
  assert.match(background,/LibraryBackdrop\(/); assert.match(background,/scopeId: this\.detailBackdropScope\(\)/);
  assert.match(background,/detailBackdropVeilStops\(\)/);
  assert(method('detailView').indexOf('this.detailBackdrop()')<method('detailView').indexOf('Scroll(this.detailScroller)'));
});
console.log(`PASS: ${passed} actual-method Hero image/pull groups. No device, network or build calls.`);
