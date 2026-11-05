'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {ts,projectFile}=require('./test-env.cjs');
let scenario=null,requests=[],servers=[],timers=new Map(),timerId=0,closedConnections=0;
const http={RequestMethod:{GET:'GET'},createHttp(){
 const handlers=new Map(),request={destroyed:false,handlers,options:null,url:'',
  on(name,callback){handlers.set(name,callback)},destroy(){this.destroyed=true},
  requestInStream(address,options){this.url=address;this.options=options;return scenario(this,handlers);}
 };requests.push(request);return request;
}};
const socket={constructTCPSocketServerInstance(){const events=new Map(),server={closed:false,events,
 on(name,callback){events.set(name,callback)},async listen(options){this.listenOptions=options},async getLocalAddress(){return{port:19001}},async close(){this.closed=true}};servers.push(server);return server;}};
const cryptoKit={cryptoFramework:{createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(crypto.randomBytes(n))})})}};
function load(relative,deps={}){const source=fs.readFileSync(projectFile('entry/src/main/ets/common/ai/'+relative+'.ets'),'utf8');
 const output=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});assert.equal(output.diagnostics.length,0);
 const module={exports:{}};vm.runInNewContext(output.outputText,{module,exports:module.exports,URL,ArrayBuffer,Uint8Array,Date,Number,Promise,
 setTimeout:(callback,delay)=>{timers.set(++timerId,{callback,delay});return timerId},clearTimeout:id=>timers.delete(id),
 require:name=>{if(name==='@kit.NetworkKit')return{http,socket};if(name==='@kit.ArkTS')return{url:{URL}};if(name==='@kit.CryptoArchitectureKit')return cryptoKit;if(deps[name])return deps[name];throw Error(name);}});return module.exports;}
const bridgeModule=load('AiSourceBridge'),Bridge=bridgeModule.AiSourceBridge;
function client(){return{alive:true,request:null,cancel:null,connection:{async close(){closedConnections++},async send(){}},timer:-1};}
function response(handlers,{code=206,start=0,end=0,total=100,data=new Uint8Array([1]),contentType='video/mp4',range=true,encoding='' }={}){
 const headers={'status-line':'HTTP/1.1 '+code,'content-type':contentType};if(range)headers['content-range']=`bytes ${start}-${end}/${total}`;if(encoding)headers['content-encoding']=encoding;
 handlers.get('headersReceive')(headers);if(data)handlers.get('dataReceive')(data.buffer);handlers.get('dataEnd')();return Promise.resolve(code);
}
function reset(){requests=[];servers=[];timers.clear();scenario=null;}
let groups=0;async function test(name,run){reset();await run();groups++;console.log('PASS: '+name)}
(async()=>{
 await test('transport accepts file HTTP(S) sources while refusing credentials, fragments and HLS',async()=>{
  assert(Bridge.validSource('https://nas.example/movie.mkv?token=fixture-only'));assert(Bridge.validSource('http://nas.example/movie.mp4'));
  for(const source of ['https://u:p@nas.example/a','https://nas.example/a#x','https://nas.example/a.m3u8','file:///etc/passwd','https://nas.example/a\r\nx'])assert(!Bridge.validSource(source),source);
  assert(Bridge.numericHttp('http://198.51.100.30:8005/path'));assert(!Bridge.numericHttp('https://198.51.100.30/path'));assert(!Bridge.numericHttp('http://nas.example/path'));
 });
 await test('request headers preserve exact generic authentication and replace only transport fields',async()=>{
  const source={Authorization:'Bearer fixture','X-Plex-Token':'fixture-plex',Cookie:'fixture=cookie',Range:'bytes=0-999',Host:'wrong',Connection:'keep-alive'};
  const output=Bridge.requestHeaders(source,10,19);assert.equal(output.Authorization,source.Authorization);assert.equal(output['X-Plex-Token'],source['X-Plex-Token']);assert.equal(output.Cookie,source.Cookie);
  assert.equal(output.Range,'bytes=10-19');assert.equal(output['Accept-Encoding'],'identity');assert.equal(output.Host,undefined);assert.equal(output.Connection,undefined);
  assert.throws(()=>Bridge.requestHeaders({'X-A':'value\r\nInjected: yes'},0,0),/HEADERS_INVALID/);
 });
 await test('TLS/DNS bridge binds loopback with unpredictable paths, redirects off and bounded streaming',async()=>{
  const bridge=new Bridge();const local=await bridge.start('https://nas.example/movie.mkv',{Authorization:'fixture'});
  assert.match(local,/^http:\/\/127\.0\.0\.1:19001\/ai\/[a-f0-9]{48}\/source$/);assert.equal(servers[0].listenOptions.address,'127.0.0.1');
  scenario=(_request,handlers)=>response(handlers);const part=await bridge.fetch(0,0,client(),bridge.generation);assert.equal(part.total,100);assert.equal(part.data.byteLength,1);
  assert.equal(requests[0].options.maxRedirects,0);assert.equal(requests[0].options.usingCache,false);assert.equal(requests[0].options.header.Authorization,'fixture');assert.equal(requests[0].url,'https://nas.example/movie.mkv');
  assert(requests[0].destroyed);await bridge.close();assert(servers[0].closed);assert.equal(timers.size,0);
 });
 await test('a 200 whole-file reply is rejected at headers before body can accumulate',async()=>{
  const bridge=new Bridge();await bridge.start('https://nas.example/movie.mkv',{});let readBody=false;
  scenario=(request,handlers)=>{handlers.get('headersReceive')({'status-line':'HTTP/1.1 200 OK','content-length':'2000000000'});readBody=!request.destroyed;return Promise.resolve(200);};
  await assert.rejects(bridge.fetch(0,0,client(),bridge.generation),/RANGE_REQUIRED/);assert.equal(readBody,false);assert(requests[0].destroyed);await bridge.close();
 });
 await test('oversized range streams are destroyed immediately with no full-file fallback',async()=>{
  const bridge=new Bridge();await bridge.start('https://nas.example/movie.mkv',{});
  scenario=(request,handlers)=>{handlers.get('headersReceive')({'content-range':'bytes 0-0/2000000000'});handlers.get('dataReceive')(new Uint8Array(64).buffer);assert(request.destroyed);return Promise.resolve(206);};
  await assert.rejects(bridge.fetch(0,0,client(),bridge.generation),/READ_BUDGET/);await bridge.close();
 });
 await test('206 identity, total and exact requested boundaries must match',async()=>{
  const bridge=new Bridge();await bridge.start('https://nas.example/movie.mkv',{});
  for(const values of [{start:1,end:1},{total:0},{encoding:'gzip'},{contentType:'application/vnd.apple.mpegurl'}]){
   scenario=(_request,handlers)=>response(handlers,values);await assert.rejects(bridge.fetch(0,0,client(),bridge.generation),/RANGE_|SOURCE_/);
  }await bridge.close();
 });
 await test('overlapping client events account bytes immediately before their range promises finish',async()=>{
  const bridge=new Bridge();await bridge.start('https://nas.example/movie.mkv',{});bridge.bytes=Bridge.BUDGET-3;const jobs=[];
  scenario=(request,handlers)=>new Promise(resolve=>{jobs.push({request,handlers,resolve});});
  const first=bridge.fetch(0,1,client(),bridge.generation),second=bridge.fetch(0,1,client(),bridge.generation);
  const secondRejected=assert.rejects(second,/READ_BUDGET/);assert.equal(jobs.length,2);
  for(const job of jobs)job.handlers.get('headersReceive')({'content-range':'bytes 0-1/100'});
  jobs[0].handlers.get('dataReceive')(new Uint8Array([1,2]).buffer);assert.equal(bridge.bytes,Bridge.BUDGET-1);
  jobs[1].handlers.get('dataReceive')(new Uint8Array([3,4]).buffer);assert(jobs[1].request.destroyed);
  jobs[0].handlers.get('dataEnd')();jobs[0].resolve(206);jobs[1].resolve(206);await first;await secondRejected;
  assert.equal(bridge.bytes,Bridge.BUDGET-1);await bridge.close();
 });
 await test('closing a request explicitly rejects even if platform destroy never settles its promise',async()=>{
  const bridge=new Bridge();await bridge.start('https://nas.example/movie.mkv',{});const connected=client();bridge.clients.push(connected);
  scenario=()=>new Promise(()=>{});const pending=bridge.fetch(0,0,connected,bridge.generation);const rejected=assert.rejects(pending,/CANCELLED/);await bridge.close();await rejected;
  assert(requests[0].destroyed);assert.equal(bridge.clients.length,0);assert.equal(timers.size,0);
 });
 await test('wrapper owns each TLS bridge, hides upstream authentication from native and closes on completion',async()=>{
  let forwarded=null;const native={async extractAudio(options){forwarded=options;return{path:options.outputPath}},extractTextSubtitles:async()=>({cues:[]}),cancelExtraction(){}};
  const {NativeAudioExtractor:Extractor}=load('NativeAudioExtractor',{'./AiSourceBridge':bridgeModule,'libai_audio_extractor.so':native});
  const extractor=new Extractor();await extractor.extractAudio({url:'https://nas.example/a.mkv',headers:{Authorization:'fixture-secret'},outputPath:'/private/cache/out.wav',startMs:1000,durationMs:3000,sampleRate:16000,jobId:'tls-job'});
  assert.match(forwarded.url,/^http:\/\/127\.0\.0\.1:19001\/ai\//);assert.equal(Object.keys(forwarded.headers).length,0);assert.equal(forwarded.durationMs,3000);
  assert(servers[0].closed);assert.equal(timers.size,0);
 });
 await test('cancelling TLS extraction closes bridge immediately but retains the native queue until settlement',async()=>{
  let settle,cancelled=[];const native={extractAudio:()=>new Promise(resolve=>{settle=resolve}),extractTextSubtitles:async()=>({cues:[]}),cancelExtraction:id=>cancelled.push(id)};
  const {NativeAudioExtractor:Extractor}=load('NativeAudioExtractor',{'./AiSourceBridge':bridgeModule,'libai_audio_extractor.so':native});
  const extractor=new Extractor();const work=extractor.extractAudio({url:'https://nas.example/a.mkv',headers:{},outputPath:'/private/cache/out.wav',startMs:0,durationMs:3000,sampleRate:16000,jobId:'cancel-tls'});
  const cancelledWork=assert.rejects(work,/CANCELLED/);for(let i=0;i<12;i++)await Promise.resolve();assert(settle);
  extractor.cancelAll();await cancelledWork;assert(servers[0].closed);assert.deepEqual(cancelled,['cancel-tls']);settle({path:'/private/cache/out.wav'});
  for(let i=0;i<12;i++)await Promise.resolve();assert.equal(timers.size,0);
 });
 await test('wrapper advertises exact file transport capability and no HLS or invalid descriptor',async()=>{
  const native={extractAudio:async()=>({path:'/cache/a.wav'}),extractTextSubtitles:async()=>({cues:[]}),cancelExtraction(){}};
  const {NativeAudioExtractor:Extractor}=load('NativeAudioExtractor',{'./AiSourceBridge':bridgeModule,'libai_audio_extractor.so':native});
  for(const source of ['https://nas.example/a.mkv','http://nas.example/a.mp4','fd://80','/cache/movie.mkv'])assert(Extractor.supportsSource(source),source);
  for(const source of ['https://nas.example/a.m3u8','/cache/a.m3u8','fd://2147483648','fdclose://80','https://u:p@nas.example/a'])assert(!Extractor.supportsSource(source),source);
  assert(!Extractor.supportsSource('https://nas.example/a',true));assert.match(Extractor.sourceError('https://nas.example/a',true),/外挂字幕/);
 });
 console.log(`PASS: ${groups} actual AI transport bridge groups. Network/socket/native are controlled mocks; no device/network proof.`);
})().catch(error=>{console.error(error);process.exitCode=1});
