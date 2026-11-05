'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const source = fs.readFileSync(projectFile('entry/src/main/ets/components/NetImage.ets'), 'utf8');
const start = source.indexOf('class ImageCache {');
const end = source.indexOf('\nexport class NetImageLoader {', start);
assert(start >= 0 && end > start);
const compiled = ts.transpileModule(source.slice(start, end) + '\nexports.Cache=ImageCache;', {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.length, 0);
function scenario(body) {
  const context = vm.createContext({ exports: {} });
  vm.runInContext(compiled.outputText, context, { timeout: 1000 });
  vm.runInContext(`
    const C=exports.Cache;
    let released=0;
    const large=()=>({getImageInfoSync(){return {size:{width:512,height:512}}},release(){released++}});
    const tiny=()=>({getImageInfoSync(){return {size:{width:1,height:1}}},release(){released++}});
    ${body}
  `, context, { timeout: 1000 });
  return context.result;
}
let groups = 0;
function test(name, run) { run(); groups++; console.log('PASS: ' + name); }

test('all-leased >soft/hard and >80 entries returns without eviction, lease loss or PixelMap release', () => {
  const result = scenario(`
    for(let i=0;i<100;i++){C.acquire('k'+i);C.put('k'+i,large())}
    result={total:C.used(),count:C.keys.length,leases:C.leases.size,
      present:C.map.size,noCandidate:C.evictTail(),admit:C.prepareDecode(),released};
  `);
  assert.equal(result.total, 100 * 1024 * 1024);
  assert.equal(result.count, 100);
  assert.equal(result.present, 100);
  assert.equal(result.leases, 100);
  assert.equal(result.noCandidate, false);
  assert.equal(result.admit, false);
  assert.equal(result.released, 0);
});
test('count-only all-leased overflow also returns; oversized single cache admission remains rejected', () => {
  const result = scenario(`
    for(let i=0;i<100;i++){C.acquire('k'+i);C.put('k'+i,tiny())}
    C.put('oversized',{getImageInfoSync(){return{size:{width:4096,height:4096}}},release(){released++}});
    result={total:C.used(),count:C.keys.length,leases:C.leases.size,big:C.map.has('oversized'),released};
  `);
  assert.equal(result.total, 400);
  assert.equal(result.count, 100);
  assert.equal(result.leases, 100);
  assert.equal(result.big, false);
  assert.equal(result.released, 0);
});
test('releasing leases permits eviction and decode admission resumes without releasing PixelMaps', () => {
  const result = scenario(`
    for(let i=0;i<100;i++){C.acquire('k'+i);C.put('k'+i,large())}
    for(let i=0;i<40;i++){C.releaseKey('k'+i)}
    const allowed=C.prepareDecode();
    C.put('new',large());
    result={allowed,total:C.used(),count:C.keys.length,keptActive:C.map.has('k99'),
      oldEvicted:!C.map.has('k0'),newPresent:C.map.has('new'),activeLease:C.leases.get('k99'),released};
  `);
  assert.equal(result.allowed, true);
  assert.equal(result.total, 64 * 1024 * 1024);
  assert.equal(result.count, 64);
  assert.equal(result.keptActive, true);
  assert.equal(result.oldEvicted, true);
  assert.equal(result.newPresent, true);
  assert.equal(result.activeLease, 1);
  assert.equal(result.released, 0);
});
test('64MiB soft and 96MiB exact hard thresholds, with a leased remainder, stay finite', () => {
  const result = scenario(`
    for(let i=0;i<64;i++){C.acquire('k'+i);C.put('k'+i,large())}
    const soft=C.used(),softAllows=C.prepareDecode();
    for(let i=64;i<96;i++){C.acquire('k'+i);C.put('k'+i,large())}
    const hard=C.used(),hardBlocks=!C.prepareDecode();
    C.releaseKey('k0');
    const oneReleasedAllows=C.prepareDecode();
    result={soft,softAllows,hard,hardBlocks,oneReleasedAllows,total:C.used(),released};
  `);
  assert.equal(result.soft, 64 * 1024 * 1024);
  assert.equal(result.softAllows, true);
  assert.equal(result.hard, 96 * 1024 * 1024);
  assert.equal(result.hardBlocks, true);
  assert.equal(result.oneReleasedAllows, true);
  assert.equal(result.total, 95 * 1024 * 1024, 'active entries may remain above soft; gate is not a reservation');
  assert.equal(result.released, 0);
});
test('ordinary LRU evicts oldest unleased entry and skips active leases', () => {
  const result = scenario(`
    C.put('A',tiny()); C.put('B',tiny()); C.put('C',tiny());
    C.get('A'); C.acquire('B');
    const first=C.evictTail(),second=C.evictTail(),third=C.evictTail();
    result={first,second,third,keys:C.keys.join(','),lease:C.leases.get('B'),total:C.used(),released};
  `);
  assert.equal(result.first, true);
  assert.equal(result.second, true);
  assert.equal(result.third, false);
  assert.equal(result.keys, 'B');
  assert.equal(result.lease, 1);
  assert.equal(result.total, 4);
  assert.equal(result.released, 0);
});

// Execute actual doLoad with a mocked image source and HTTP response. A blocked gate must reach
// the existing undefined/onFail path without calling createPixelMap; re-entry can retry later.
const loaderStart = source.indexOf('export class NetImageLoader {');
const loaderEnd = source.indexOf('\n@Component', loaderStart);
const loaderCode = ts.transpileModule(source.slice(loaderStart, loaderEnd), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
assert.equal(loaderCode.diagnostics.length, 0);
const calls = { decode: 0, sourceRelease: 0, requestDestroy: 0 };
let admitted = false;
const context = {
  ImageRequest: require('./image-loader-fixture.cjs').ImageRequest,
  exports: {}, ImageCache: { prepareDecode: () => admitted, put() {}, get() {} },
  http: { RequestMethod: { GET: 0 }, HttpDataType: { ARRAY_BUFFER: 0 }, createHttp: () => ({
    request: async () => ({ responseCode: 206, result: new ArrayBuffer(120) }),
    destroy: () => calls.requestDestroy++
  }) },
  image: { createImageSource: () => ({
    getImageInfo: async () => ({ size: { width: 512, height: 512 } }),
    createPixelMap: async () => { calls.decode++; return { decoded: true }; },
    release: () => calls.sourceRelease++
  }) }
};
vm.runInNewContext(loaderCode.outputText, context);
(async () => {
  const loader = context.exports.NetImageLoader;
  assert.equal(await loader.doLoad('test-key', 'test-url', '', '', 420), undefined);
  assert.equal(calls.decode, 0);
  assert.equal(calls.sourceRelease, 1);
  assert.equal(calls.requestDestroy, 1);
  admitted = true;
  const result = await loader.doLoad('test-key', 'test-url', '', '', 420);
  assert.equal(result.decoded, true);
  assert.equal(calls.decode, 1);
  assert.equal(calls.sourceRelease, 2);
  assert.equal(calls.requestDestroy, 2);
  groups++;
  console.log('PASS: actual decode gate declines allocation, cleans request/source and allows a later retry');
  console.log(`PASS: ${groups} image-cache groups. VM timeout bounds deadlock regressions; no real decoding/device/network.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
