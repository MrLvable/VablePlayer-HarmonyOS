'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const text=fs.readFileSync(projectFile('entry/src/main/ets/common/Materials.ets'),'utf8');
let constructions=0;
class ImmersiveMaterial { constructor(options){this.options=options;constructions++;} }
const ctx={exports:{},require:name=>{
 if(name==='@kit.ArkUI')return{uiMaterial:{ImmersiveMaterial,ImmersiveStyle:{THICK:3}}};
 if(name==='./Theme')return{withAlpha:(color,alpha)=>color+'@'+alpha};
 throw Error(name);
}};
const result=ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});
assert.equal(result.diagnostics.length,0);vm.runInNewContext(result.outputText,ctx);
const Materials=ctx.exports.Materials;
const dark=Materials.popupMaterial(true,'#0087ff');
for(let n=0;n<100;n++)assert.equal(Materials.popupMaterial(true,'#0087ff'),dark);
assert.equal(constructions,1,'rebuilds must reuse the native material instance');
const light=Materials.popupMaterial(false,'#0087ff');assert.notEqual(light,dark);
assert.equal(Materials.popupMaterial(false,'#0087ff'),light);
assert.notEqual(Materials.popupMaterial(true,'#ee8800'),dark);
for(const value of [dark,light]){assert.equal(value.options.style,3);assert.equal(value.options.interactive,true);assert(value.options.lightEffect.color);}
console.log('PASS: actual Materials factory caches native surfaces per theme/accent and enables official interactive light');
const moduleSource=fs.readFileSync(projectFile('entry/src/main/module.json5'),'utf8').replace(/\/\/[^\r\n]*/g,'');
const config=JSON.parse(moduleSource);
assert(config.module.metadata.some(entry=>entry.name==='ohos.arkui.UIMaterial.state'&&entry.value==='enable'));
assert(!config.module.abilities.some(ability=>(ability.metadata||[]).some(entry=>entry.name==='ohos.arkui.UIMaterial.state')));
console.log('PASS: immersive light is enabled on the actual module metadata, not misplaced on one ability');
const index=fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'),'utf8');
assert.equal((index.match(/bindContextMenu\(this\.serverContextMenu\(s\), ResponseType\.LongPress, \{ systemMaterial: Materials\.popupMaterial/g)||[]).length,2);
assert(!index.includes('promptAction.showDialog({'));
console.log('PASS: server long-press menus and source confirmations use native material containers');
console.log('PASS: 3 material lifecycle/configuration groups; native UI rendering and motion require device observation.');
