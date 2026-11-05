'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const pageSource = fs.readFileSync(projectFile('entry/src/main/ets/pages/PlayerPage.ets'), 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(pageSource);
  assert(match, name);
  const start = pageSource.indexOf('{', match.index); let depth = 1, end = start + 1;
  for (; depth; end++) { if (pageSource[end] === '{') depth++; else if (pageSource[end] === '}') depth--; }
  return pageSource.slice(match.index, end).replace(/^  private /, '  ');
}
class Effect {
  constructor(kind, options) { this.effects = [{ kind, options }]; }
  combine(effect) { this.effects.push(...effect.effects); return this; }
  animation(options) { this.animationOptions = options; return this; }
}
const TransitionEffect = {
  get OPACITY() { return new Effect('opacity'); },
  scale: options => new Effect('scale', options), translate: options => new Effect('translate', options),
  asymmetric: (enter, leave) => ({ enter, leave })
};
let factor = 1;
class MpvAdapter {
  constructor() { this.calls = []; this.fail = false; }
  applyScreenRatio(mode) { this.calls.push(mode); if (this.fail) throw Error('readback'); }
}
const toasts = [];
const areaBinding = pageSource.lastIndexOf('.onAreaChange((_old: Area, area: Area) => {');
assert.ok(areaBinding >= 0); const areaStart = pageSource.indexOf('{', areaBinding);
let areaDepth = 1, areaEnd = areaStart + 1;
for (; areaDepth; areaEnd++) { if (pageSource[areaEnd] === '{') areaDepth++; else if (pageSource[areaEnd] === '}') areaDepth--; }
const areaCallback = 'onSurfaceArea(_old: unknown, area: {width: number; height: number}) ' + pageSource.slice(areaStart, areaEnd);
const source = 'class Page { player=null;screenRatioMode="默认";fitCrop=false;showRatioPanel=true;shown=0;hudWidth=0;hudHeight=0;readHudInsets(){}hudUnit(value){return value;}showBarTemporarily(){this.shown++;}'
  + ['applyScreenRatio', 'playerPopupTransition', 'playerPopupLayerTransition'].map(method).join('\n') + areaCallback + '} exports.Page=Page;';
const moduleObject = { exports: {} };
const result = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(result.diagnostics.length, 0);
vm.runInNewContext(result.outputText, {
  exports: moduleObject.exports, MpvAdapter, TransitionEffect,
  Curve: { EaseOut: 'out', EaseIn: 'in' }, MotionSpec: { menuIn: 200, menuOut: 160 },
  MotionPref: { dur: value => value * factor }, promptAction: { showToast: value => toasts.push(value.message) },
  media: { VideoScaleType: { VIDEO_SCALE_TYPE_SCALED_ASPECT: 2, VIDEO_SCALE_TYPE_FIT_CROP: 1, VIDEO_SCALE_TYPE_FIT: 0 } }
});
const Page = moduleObject.exports.Page;
const page = new Page(); page.player = new MpvAdapter();
page.applyScreenRatio('4:3');
assert.equal(page.screenRatioMode, '4:3'); assert.equal(page.showRatioPanel, false); assert.equal(page.shown, 1);
page.showRatioPanel = true; page.player.fail = true; page.applyScreenRatio('裁切');
assert.equal(page.screenRatioMode, '4:3'); assert.equal(page.fitCrop, false); assert.equal(page.showRatioPanel, true);
assert.equal(page.shown, 1); assert.equal(toasts.length, 1);
page.player.fail = false; page.applyScreenRatio('裁切'); assert.equal(page.fitCrop, true);
page.showRatioPanel = true; page.applyScreenRatio('默认'); assert.equal(page.fitCrop, false);
console.log('PASS UI commits ratio/checkmark and closes menu only after native confirmation; failure retains selection');
page.applyScreenRatio('平铺'); assert.equal(toasts.at(-1), '等比铺满，保留原始比例');
assert.equal(page.fitCrop, true, 'Tile crop policy survives source preparation/retry');
const ratioCalls = page.player.calls.length;
page.onSurfaceArea({}, { width: 1000, height: 500 }); page.onSurfaceArea({}, { width: 500, height: 1000 });
assert.equal(page.player.calls.length, ratioCalls);
assert.equal(page.hudWidth, 500); assert.equal(page.hudHeight, 1000);
assert.ok(!pageSource.includes('updateSurfaceSize('));
console.log('PASS surface callback retains HUD layout without crop-cap native resets; tile has the reference description');
const local = new Page(); local.player = { videoScaleType: -1 };
local.applyScreenRatio('默认'); assert.equal(local.player.videoScaleType, 2); assert.equal(local.fitCrop, false);
local.applyScreenRatio('平铺'); assert.equal(local.player.videoScaleType, 1); assert.equal(local.fitCrop, true);
local.applyScreenRatio('拉伸'); assert.equal(local.player.videoScaleType, 0); assert.equal(local.fitCrop, false);
local.applyScreenRatio('裁切'); assert.equal(local.player.videoScaleType, 1); assert.equal(local.fitCrop, true);
console.log('PASS local AVPlayer uses SDK FIT_CROP for aspect-preserving tile/crop and keeps stretch a separate mode');
const hosts = method('nativePlayerOverlays');
assert.match(hosts, /\.bindPopup\(this\.showRatioPanel/);
assert.match(hosts, /builder: this\.ratioMenuPanel\(\)/);
assert.match(hosts, /systemMaterial: Materials\.popupMaterial/);
for (const builder of ['ratioMenuPanel', 'subtitleMenuPanel', 'speedMenuPanel', 'audioMenuPanel', 'castConfirmation', 'aiSubtitlePanel']) {
  const body = method(builder);
  assert(!body.includes('.transition(this.playerPopupTransition())'), builder + ' must not double animate native presentation');
  assert(!body.includes('.transition(this.playerPopupLayerTransition())'), builder + ' must not add a simulated fullscreen fade');
}
console.log('PASS ratio is hosted by an official material Popup; related native panels do not add a duplicate custom transition. Native motion still needs device observation.');
