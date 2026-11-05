'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const { ImageRequest, SourceIdentity } = require('./image-loader-fixture.cjs');
const compile = text => { const out = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true }); assert.equal(out.diagnostics.length, 0); return out.outputText; };
const read = name => fs.readFileSync(projectFile('entry/src/main/ets/common/' + name + '.ets'), 'utf8');
const math = { exports: {} }; vm.runInNewContext(compile(read('PaletteMath')), math);
const MathPalette = math.exports.PaletteMath;
const packed = hex => parseInt(hex.substring(1), 16);
function rgba(colors, width = 24, height = 24, padding = 0, premultiplied = false) {
  const stride = width * 4 + padding, bytes = new Uint8Array(stride * height); bytes.fill(255);
  let pixel = 0;
  for (const [rgb, count, alpha = 255] of colors) {
    for (let index = 0; index < count && pixel < width * height; index++, pixel++) {
      const offset = Math.floor(pixel / width) * stride + (pixel % width) * 4, factor = premultiplied ? alpha / 255 : 1;
      bytes[offset] = Math.round(((rgb >> 16) & 255) * factor); bytes[offset + 1] = Math.round(((rgb >> 8) & 255) * factor); bytes[offset + 2] = Math.round((rgb & 255) * factor); bytes[offset + 3] = alpha;
    }
  }
  return { bytes, stride, width, height };
}
const pick = (pixels, vibrant = true, premultiplied = false) => MathPalette.fromRgba(pixels.bytes, pixels.width, pixels.height, pixels.stride, vibrant, premultiplied);
let count = 0;
async function test(name, action) { await action(); count++; console.log('PASS: ' + name); }
(async () => {
  await test('large pale pink and lavender areas beat dark hair and tiny saturated accents', () => {
    for (const pink of [0xf1cfdf, 0xeadce9, 0xf7e8ed]) {
      const pixels = rgba([[pink, 400], [0x171719, 150], [0x0088ff, 26]]);
      assert.equal(pick(pixels), pink);
    }
    const red = rgba([[0x101010, 420], [0xd41b32, 156]]);
    assert.equal(pick(red), 0xd41b32); assert.equal(pick(red, false), 0x101010);
  });
  await test('neutral posters remain neutral; tiny logos and opposite colors do not become gray averages', () => {
    assert.equal(pick(rgba([[0xf3f3f3, 520], [0xff0000, 28], [0x0000ff, 28]])), 0xf3f3f3);
    const complementary = pick(rgba([[0xee2020, 288], [0x2020ee, 288]]));
    assert(complementary === 0xee2020 || complementary === 0x2020ee);
    assert.equal(pick(rgba([[0, 576]])), 0);
  });
  await test('RGBA stride, alpha, premultiplication and bounded invalid input are handled deterministically', () => {
    assert.equal(pick(rgba([[0xf1cfdf, 500], [0x0000ff, 76, 0]], 24, 24, 8)), 0xf1cfdf);
    const value = pick(rgba([[0xf1cfdf, 576, 128]], 24, 24, 0, true), true, true);
    for (const shift of [0, 8, 16]) assert(Math.abs(((value >> shift) & 255) - ((0xf1cfdf >> shift) & 255)) <= 1);
    assert.equal(pick(rgba([[0xff00ff, 576, 0]])), -1);
    for (const args of [[new Uint8Array(0), 24, 24, 96], [new Uint8Array(4), 0, 1, 4], [new Uint8Array(4), 257, 1, 1028]]) assert.equal(MathPalette.fromRgba(...args, true), -1);
  });
  await test('fields retain source hue/brightness ordering rather than flattening all images to fixed dark luma', () => {
    const pink = 0xf1cfdf, blue = 0x203c84;
    for (const [band, factor] of [[0, .76], [1, .68], [2, .60]]) {
      const result = packed(MathPalette.field(pink, true, band));
      assert(Math.abs(MathPalette.brightness(result) / MathPalette.brightness(pink) - factor) < .004);
      assert(MathPalette.brightness(result) > MathPalette.brightness(packed(MathPalette.field(blue, true, band))));
      assert(((result >> 16) & 255) > (result & 255)); assert((result & 255) > ((result >> 8) & 255));
    }
    assert(MathPalette.brightness(packed(MathPalette.base(pink, true))) > .4, 'Pale pink no longer becomes a .14-luma near-black base');
    assert.equal(MathPalette.base(0, true), '#000000', 'Real black is never given a synthetic brown cast');
    for (const band of [0, 1, 2]) assert(MathPalette.brightness(packed(MathPalette.field(pink, false, band))) >= MathPalette.brightness(pink));
  });

  const calls = [], regions = []; let imageReleases = 0, mapReleases = 0, pickerCalls = 0, requestDestroys = 0;
  const bandColors = [0xf1cfdf, 0xc9b4d5, 0xa97793];
  const sdkImage = { PixelMapFormat: { RGBA_8888: 3 }, AlphaType: { PREMUL: 2, UNPREMUL: 3 }, createImageSource() {
    return { getImageInfoSync: () => ({ size: { width: 90, height: 90 } }),
      async createPixelMap(options) {
        assert.equal(options.desiredPixelFormat, 3); regions.push(options);
        const color = bandColors[Math.min(2, Math.floor((options.desiredRegion?.y ?? 0) / 30))];
        const pixels = rgba([[color, 400], [0x141414, 150], [0x0088ff, 26]], 24, 24, 8);
        return { getImageInfoSync: () => ({ size: { width: 24, height: 24 }, pixelFormat: 3, alphaType: 3 }),
          getPixelBytesNumber: () => pixels.bytes.byteLength, getBytesNumberPerRow: () => pixels.stride,
          async readPixelsToBuffer(buffer) { new Uint8Array(buffer).set(pixels.bytes); }, release() { mapReleases++; } };
      }, release() { imageReleases++; } };
  } };
  const modules = new Map();
  function load(name) {
    if (name === 'PaletteMath') return math.exports;
    if (modules.has(name)) return modules.get(name).exports;
    const module = { exports: {} }; modules.set(name, module);
    vm.runInNewContext(compile(read(name)), { exports: module.exports, require(id) {
      if (id === '@kit.NetworkKit') return { http: { RequestMethod: { GET: 0 }, HttpDataType: { ARRAY_BUFFER: 0 }, createHttp: () => ({
        async request(address, options) { calls.push({ address, options }); return { responseCode: 200, result: new Uint8Array(80).buffer }; }, destroy() { requestDestroys++; }
      }) } };
      if (id === '@kit.ImageKit') return { image: sdkImage };
      if (id === '@kit.ArkGraphics2D') return { effectKit: { async createColorPicker() { pickerCalls++; return { getTopProportionColors: () => [{ red: 241, green: 207, blue: 223 }], isBlackOrWhiteOrGrayColor: () => true }; } } };
      if (id === './ImageRequest') return { ImageRequest };
      if (id === './services/SourceIdentity') return { SourceIdentity };
      if (id === './Theme') return { mix: () => { throw Error('Old forced luma path must be unused'); }, withAlpha: () => '' };
      return load(id.substring(2));
    } }); return module.exports;
  }
  const { Ambient, AmbientPalette } = load('Ambient'), { DominantColor } = load('DominantColor');
  await test('actual three-band decode uses area sampling, preserves generic auth/cache and releases every image/map/request', async () => {
    const key = Ambient.key('account', 'poster', 'tag', { Authorization: 'only-provider' });
    const palette = await Ambient.forUrl(key, 'https://image.invalid/pink.png', 'wrong-old-token', 'wrong-old-auth', { Authorization: 'only-provider' });
    assert.equal(palette.topRgb, bandColors[0]); assert.equal(palette.midRgb, bandColors[1]); assert.equal(palette.botRgb, bandColors[2]);
    assert.equal(pickerCalls, 0, 'A platform gray classification cannot discard a successfully sampled pastel');
    assert.deepEqual(regions.map(value => value.desiredRegion.y), [0, 30, 60]);
    assert.deepEqual(JSON.parse(JSON.stringify(calls[0].options.header)), { authorization: 'only-provider' });
    assert.equal(calls[0].options.usingCache, false); assert.equal(calls[0].options.maxRedirects, 0);
    assert.equal(imageReleases, 1); assert.equal(mapReleases, 3); assert.equal(requestDestroys, 1);
    assert.equal((await Ambient.forUrl(key, 'https://image.invalid/pink.png', '', '', { Authorization: 'only-provider' })).topRgb, palette.topRgb); assert.equal(calls.length, 1);
    assert.equal(AmbientPalette.field(palette.topRgb, true, 0), MathPalette.field(palette.topRgb, true, 0));
    assert.equal(AmbientPalette.baseOf(palette.midRgb, true), MathPalette.base(palette.midRgb, true));
    assert(!AmbientPalette.empty().has); assert.equal(AmbientPalette.field(-1, true, 0), AmbientPalette.NEUTRAL_DARK_FIELD[0]);
  });
  await test('ColorPicker fallback accepts pale colors even if the platform calls them gray', async () => {
    const result = await DominantColor.fromPixelMap({}); assert.equal(result, 0xf1cfdf); assert.equal(pickerCalls, 1);
  });
  console.log('PASS: ' + count + ' palette groups against actual pure math and Ambient/DominantColor paths. SDK transport/decode mocked; no device/build or pixel-equivalence claim.');
})().catch(error => { console.error(error); process.exitCode = 1; });
