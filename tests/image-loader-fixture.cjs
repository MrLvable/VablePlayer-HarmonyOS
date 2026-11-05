'use strict';
const fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
const compile=text=>{const out=ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(out.diagnostics.length,0);return out.outputText};
const identityContext={exports:{},require(name){if(name==='@kit.CryptoArchitectureKit')return{cryptoFramework:{createMd(){const hash=crypto.createHash('sha256');return{updateSync(input){hash.update(input.data)},digestSync(){return{data:new Uint8Array(hash.digest())}}}}}};if(name==='@kit.ArkTS')return{util:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text)}}}};return{}}};
vm.runInNewContext(compile(fs.readFileSync(projectFile('entry/src/main/ets/common/services/SourceIdentity.ets'),'utf8')),identityContext);
const requestContext={exports:{},require(){return{SourceIdentity:identityContext.exports.SourceIdentity}}};
vm.runInNewContext(compile(fs.readFileSync(projectFile('entry/src/main/ets/common/ImageRequest.ets'),'utf8')),requestContext);
function imageLoader(globals={}){const source=fs.readFileSync(projectFile('entry/src/main/ets/components/NetImage.ets'),'utf8');const text=source.slice(source.indexOf('class ImageCache {'),source.indexOf('\n@Component'))+'\nexports.ImageCache=ImageCache;';const context={exports:{},ImageRequest:requestContext.exports.ImageRequest,...globals};vm.runInNewContext(compile(text),context);return context.exports}
module.exports={imageLoader,ImageRequest:requestContext.exports.ImageRequest,SourceIdentity:identityContext.exports.SourceIdentity};
