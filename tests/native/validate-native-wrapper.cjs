'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectRoot: root } = require('../test-env.cjs');
const file = path.join(root, 'entry/src/main/ets/common/ai/NativeAudioExtractor.ets');
const declaration = path.join(root, 'entry/src/main/cpp/aisubtitle/types/libai_audio_extractor/index.d.ts');
const virtual = path.join(__dirname, 'NativeAudioExtractor.check.ts');
const source = fs.readFileSync(file, 'utf8');
const bridge = path.join(root, 'entry/src/main/ets/common/ai/AiSourceBridge.ets');
const bridgeContract = path.join(__dirname, 'AiSourceBridge.contract.d.ts');
const options = { strict: true, noEmit: true, skipLibCheck: true, types: [], target: ts.ScriptTarget.ES2020,
  module: ts.ModuleKind.CommonJS, baseUrl: __dirname, paths: { 'libai_audio_extractor.so': [declaration] } };
const host = ts.createCompilerHost(options), original = host.getSourceFile.bind(host);
host.getSourceFile = (name, language, error, create) => path.resolve(name) === virtual
  ? ts.createSourceFile(name, source, language, true) : path.resolve(name) === bridgeContract
    ? ts.createSourceFile(name, `export declare class AiSourceBridge {
      static validSource(source:string):boolean;static numericHttp(source:string):boolean;
      start(source:string,headers:Record<string,string>):Promise<string>;errorCode():string;close():Promise<void>;
    }`, language, true) : original(name, language, error, create);
host.resolveModuleNames = (names, containing) => names.map(name => name === './AiSourceBridge'
  ? {resolvedFileName:bridgeContract,extension:ts.Extension.Dts,isExternalLibraryImport:false}
  : ts.resolveModuleName(name,containing,options,host).resolvedModule);

const diagnostics = ts.getPreEmitDiagnostics(ts.createProgram([virtual], options, host));
for (const diagnostic of diagnostics) console.error(ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n'));
assert.equal(diagnostics.length, 0, 'Wrapper strict types must match actual native declaration');
const calls = [], cancelled = [], pendingNative = new Map(), forwardedOptions = new Map();
let activeNative = 0, maxNative = 0;
function startNative(kind, options) {
  calls.push({ kind, id: options.jobId });
  forwardedOptions.set(options.jobId, options);
  activeNative++;
  maxNative = Math.max(maxNative, activeNative);
  assert.equal(activeNative, 1, 'The real bridge permits only one active extraction');
  return new Promise((resolve, reject) => {
    pendingNative.set(options.jobId, {
      resolve: value => { activeNative--; pendingNative.delete(options.jobId); resolve(value); },
      reject: error => { activeNative--; pendingNative.delete(options.jobId); reject(error); }
    });
  });
}
const native = {
  extractAudio: options => startNative('audio', options),
  extractTextSubtitles: options => startNative('subtitle', options),
  // A real cancellation takes time. It must not release the JS queue itself.
  cancelExtraction: id => cancelled.push(id)
};
const moduleObject = { exports: {} };
const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
vm.runInNewContext(output.outputText, { module: moduleObject, exports: moduleObject.exports,
  require: name => { if(name==='./AiSourceBridge'){return {AiSourceBridge:class {static validSource(value){return /^https?:\/\//.test(value)}static numericHttp(value){return /^http:\/\/127\.0\.0\.1/.test(value)}}};}assert.equal(name, 'libai_audio_extractor.so'); return native; } });
(async () => {
  const Extractor = moduleObject.exports.NativeAudioExtractor;
  const extractor = new Extractor(), nextSession = new Extractor(), preview = new Extractor();
  const flush = () => new Promise(resolve => setImmediate(resolve));
  const request = { url: 'http://127.0.0.1/media', headers: {}, outputPath: '/private/cache/unique.wav',
    startMs: 15000, durationMs: 12000, sampleRate: 16000, jobId: 'audio-test' };
  const audioResult = { path: request.outputPath, startMs: 15000, endMs: 27000, sampleRate: 16000, channels: 1,
    sourceBytes: 1000, sourceOpenBytes: 100, sourceProbeBytes: 200, sourceSeekBytes: 300, sourceDecodeBytes: 400 };
  const subtitleRequest = { url: request.url, headers: {}, startMs: 15000, durationMs: 12000,
    jobId: 'subtitle-test', subtitleOrdinal: 0, preferredLanguage: 'eng' };
  const subtitleResult = { cues: [{ startMs: 14000, endMs: 18000, text: 'actual source cue' }], language: 'eng', streamIndex: 2, sourceBytes: 1 };
  await assert.rejects(extractor.extractAudio({ ...request, durationMs: 30001 }), /INVALID_AUDIO_WINDOW/);
  await assert.rejects(extractor.extractAudio({ ...request, sampleRate: 48000 }), /INVALID_AUDIO_WINDOW/);
  await assert.rejects(extractor.extractTextSubtitles({ ...subtitleRequest, startMs: NaN }), /INVALID_SUBTITLE_WINDOW/);
  for (const preRollMs of [-1, 30001, NaN, 1.5]) {
    await assert.rejects(extractor.extractTextSubtitles({ ...subtitleRequest, preRollMs }), /INVALID_SUBTITLE_PREROLL/);
  }
  assert.equal(calls.length, 0);

  // Session A is running while a new session queues text extraction and a preview queues audio.
  const pending = extractor.extractAudio(request);
  const cancelledAudio = assert.rejects(pending, /EXTRACTION_CANCELLED/);
  await flush();
  assert.deepEqual(calls, [{ kind: 'audio', id: 'audio-test' }]);
  await assert.rejects(extractor.extractAudio(request), /JOB_ID_IN_USE/);
  const queued = nextSession.extractTextSubtitles(subtitleRequest);
  const cancelledQueued = assert.rejects(queued, /EXTRACTION_CANCELLED/);
  const survivor = preview.extractAudio({ ...request, jobId: 'preview' });
  nextSession.cancelAll();
  await cancelledQueued;
  assert.deepEqual(cancelled, [], 'A queued job has never entered native and must not send native cancellation');
  extractor.cancelAll();
  extractor.cancelAll();
  await cancelledAudio;
  assert.deepEqual(cancelled, ['audio-test'], 'Running cancellation is forwarded once');
  await flush();
  assert.equal(calls.length, 1, 'Prompt caller rejection must still retain the native slot until worker completion');
  pendingNative.get('audio-test').resolve(audioResult);
  await flush();
  assert.deepEqual(calls.map(call => call.id), ['audio-test', 'preview'], 'Cancelled queued work must never execute');
  pendingNative.get('preview').resolve(audioResult);
  const survivedResult = await survivor;
  assert.equal(survivedResult.endMs, 27000);
  assert.equal(survivedResult.sourceOpenBytes + survivedResult.sourceProbeBytes + survivedResult.sourceSeekBytes
    + survivedResult.sourceDecodeBytes, survivedResult.sourceBytes, 'Source phase counters are forwarded unchanged');
  await flush();
  extractor.cancelAll(); preview.cancelAll();
  assert.deepEqual(cancelled, ['audio-test'], 'Completed jobs are not retained');

  // A pre-start cancellation can reuse its ID without stale cleanup removing the new job.
  const blocker = extractor.extractAudio({ ...request, jobId: 'blocker' });
  await flush();
  const oldQueued = nextSession.extractTextSubtitles(subtitleRequest);
  const oldCancelled = assert.rejects(oldQueued, /EXTRACTION_CANCELLED/);
  nextSession.cancelExtraction('subtitle-test');
  await oldCancelled;
  const subtitles = nextSession.extractTextSubtitles(subtitleRequest);
  await assert.rejects(nextSession.extractTextSubtitles(subtitleRequest), /JOB_ID_IN_USE/);
  pendingNative.get('blocker').resolve(audioResult);
  await blocker;
  await flush();
  assert.equal(calls.filter(call => call.id === 'subtitle-test').length, 1);
  await assert.rejects(nextSession.extractTextSubtitles(subtitleRequest), /JOB_ID_IN_USE/);
  pendingNative.get('subtitle-test').resolve(subtitleResult);
  const result = await subtitles;
  assert.equal(result.cues[0].startMs, 14000, 'Wrapper preserves real overlapping cue boundaries');
  nextSession.cancelAll();
  assert.deepEqual(cancelled, ['audio-test']);

  // Native failures also release the global slot for the following instance.
  const failed = extractor.extractAudio({ ...request, jobId: 'failure' });
  const expectedFailure = assert.rejects(failed, /REAL_NATIVE_FAILURE/);
  const afterFailure = nextSession.extractTextSubtitles({ ...subtitleRequest, jobId: 'after-failure', preRollMs: 30000 });
  await flush();
  pendingNative.get('failure').reject(new Error('REAL_NATIVE_FAILURE'));
  await expectedFailure;
  await flush();
  assert.equal(calls.at(-1).id, 'after-failure');
  assert.equal(forwardedOptions.get('after-failure').preRollMs, 30000, 'A bounded diagnostic pre-roll is forwarded exactly');
  pendingNative.get('after-failure').resolve(subtitleResult);
  await afterFailure;
  const noPreRoll = preview.extractTextSubtitles({ ...subtitleRequest, jobId: 'zero-preroll', preRollMs: 0 });
  await flush();
  assert.equal(forwardedOptions.get('zero-preroll').preRollMs, 0, 'Zero pre-roll is a valid explicit choice');
  pendingNative.get('zero-preroll').resolve(subtitleResult);
  await noPreRoll;
  assert.equal(activeNative, 0);
  assert.equal(maxNative, 1);
  console.log('PASS: actual wrapper/native declaration strict types; window/pre-roll validation, global serial handoff, prompt running/queued cancellation, skipped cancelled work, ID reuse, native failure recovery and real cue forwarding. Mock NAPI only, no device proof.');
})().catch(error => { console.error(error); process.exitCode = 1; });
