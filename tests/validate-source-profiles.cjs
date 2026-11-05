'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ts,projectFile}=require('./test-env.cjs');
function load(name,dependencies={}){
 const source=fs.readFileSync(projectFile('entry/src/main/ets/common/'+name+'.ets'),'utf8');
 const output=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});
 assert.equal(output.diagnostics.length,0);
 const context={exports:{},require:id=>{assert(dependencies[id],id);return dependencies[id]}};
 vm.runInNewContext(output.outputText,context);return context.exports;
}
const endpoint=load('SourceEndpoint'),{SourceEndpoint}=endpoint;
const {SourceProfiles,SourceDraft}=load('SourceProfiles',{'./SourceEndpoint':endpoint});
let groups=0;function test(name,run){run();groups++;console.log('PASS: '+name)}
test('HTTP/HTTPS, reverse-proxy paths, explicit/default ports and case normalization use the actual parser',()=>{
 let e=SourceEndpoint.normalize('HTTPS://Nas.Example/emby/','',8096);
 assert.equal(e.host,'nas.example');assert.equal(e.scheme,'https');assert.equal(e.port,443);assert.equal(e.basePath,'/emby');
 assert.equal(SourceEndpoint.baseUrl(e.scheme,e.host,e.port,e.basePath),'https://nas.example:443/emby');
 e=SourceEndpoint.normalize('198.51.100.20','8005',8096);assert.equal(e.port,8005);
 e=SourceEndpoint.normalize('nas.local','',8096,'http','/影视/');assert.equal(e.basePath,'/%E5%BD%B1%E8%A7%86');
 e=SourceEndpoint.normalize('http://nas.local:8096/a%20b','8096',8005,'http','/a%20b');assert.equal(e.basePath,'/a%20b');
});
test('IPv6 literals, embedded IPv4 and interface scopes preserve a valid formatted authority',()=>{
 for(const host of ['2001:db8::1','::1','::ffff:192.0.2.2','1:2:3:4:5:6:7:8','fe80::1%wlan0']){
  const e=SourceEndpoint.normalize(host,'8096',80);assert.equal(e.host,host);
  assert(SourceEndpoint.baseUrl(e.scheme,e.host,e.port).startsWith('http://['));
 }
 let e=SourceEndpoint.normalize('https://[2001:DB8::1]:8443/plex','8443',80);
 assert.equal(e.host,'2001:db8::1');assert.equal(e.port,8443);assert.equal(e.basePath,'/plex');
 e=SourceEndpoint.normalize('http://[fe80::1%25wlan0]:8005','',80);
 assert.equal(e.host,'fe80::1%wlan0');assert.equal(SourceEndpoint.baseUrl(e.scheme,e.host,e.port),'http://[fe80::1%25wlan0]:8005');
});
test('malformed addresses, ambiguous conflicting fields and invalid ports never silently save',()=>{
 for(const value of ['','bad host','https://user:secret@nas.local','https://nas.local/?token=secret','ftp://nas.local','999.1.2.3','01.2.3.4','http://2001:db8::1','[1::2::3]','[1:2:3]','[1:2:3:4:5:6:7:8:9]','nas.local:']){
  assert.throws(()=>SourceEndpoint.normalize(value,'',8005),value);
 }
 for(const port of ['0','65536','-1','1.5','12abc','Infinity'])assert.throws(()=>SourceEndpoint.normalize('nas.local',port,80));
 assert.throws(()=>SourceEndpoint.normalize('http://nas.local:8096','8005',80));
 assert.throws(()=>SourceEndpoint.normalize('https://nas.local/one','','443','https','/two'));
});
test('base paths reject traversal and unsafe encodings without double-encoding valid URLs',()=>{
 for(const path of ['/../x','/%2e%2e/x','/a%2f../x','/a%5cb','/bad%XX','/a?token=x','/a#fragment'])assert.throws(()=>SourceEndpoint.path(path),path);
 assert.equal(SourceEndpoint.path('/library/%E5%BD%B1%E8%A7%86/'),'/library/%E5%BD%B1%E8%A7%86');
});
test('all thirteen source descriptors retain reference order and explicit families',()=>{
 const names=['Emby','Jellyfin','Plex','飞牛影视','飞牛影视（原生）','WebDAV','CloudDrive2','光鸭云盘','百度网盘','SMB','IPTV','自定义媒体库','本地文件夹'];
 assert.deepEqual(Array.from(SourceProfiles.all(),p=>p.name),names);
 assert.equal(SourceProfiles.forKind('local').family,'files');assert.equal(SourceProfiles.forKind('iptv').family,'iptv');
 assert.throws(()=>SourceProfiles.forKind('invented'));assert.throws(()=>SourceProfiles.forName('unknown'));
});
test('type-specific and aggregate fields do not pretend OAuth credentials are WebDAV passwords',()=>{
 assert(SourceProfiles.fieldsFor('baidu','direct').includes('refreshToken'));
 assert(!SourceProfiles.fieldsFor('baidu','aggregate').includes('refreshToken'));
 assert(SourceProfiles.fieldsFor('baidu','aggregate').includes('username'));
 assert(SourceProfiles.fieldsFor('smb','direct').includes('shareName'));
 assert.equal(SourceProfiles.authModesFor('local','direct')[0],'anonymous');
 for(const field of ['password','accessToken','clientSecret','refreshToken','sourceUrl'])assert(SourceProfiles.secretField(field));
});
function draft(kind='fnos'){
 const d=new SourceDraft(),p=SourceProfiles.forKind(kind);d.kind=kind;d.address='nas.local';d.scheme=p.defaultScheme;
 d.username='viewer';d.password='test-only-password';d.authMode=p.authModes[0];return d;
}
test('actual draft validation preserves endpoint semantics and requires real credentials unless explicitly retained',()=>{
 const d=draft();let v=SourceProfiles.validate(d);assert.equal(v.endpoint.port,8005);assert.equal(v.name,'nas.local');
 d.address='https://nas.local:8006/films';v=SourceProfiles.validate(d);assert.equal(v.endpoint.scheme,'https');assert.equal(v.endpoint.port,8006);assert.equal(v.endpoint.basePath,'/films');
 d.password='';assert.throws(()=>SourceProfiles.validate(d));d.preserveCredentials=true;SourceProfiles.validate(d);
 d.authMode='anonymous';assert.throws(()=>SourceProfiles.validate(d));
 const plex=draft('plex');plex.accessToken='';assert.throws(()=>SourceProfiles.validate(plex));plex.accessToken='test-only-token';SourceProfiles.validate(plex);
});
test('SMB shares, anonymous WebDAV and OAuth fields validate their actual distinct data',()=>{
 const smb=draft('smb');assert.throws(()=>SourceProfiles.validate(smb));smb.shareName='Media';smb.domain='HOME';let v=SourceProfiles.validate(smb);assert.equal(v.endpoint.scheme,'smb');assert.equal(v.endpoint.port,445);
 const dav=draft('webdav');dav.authMode='anonymous';dav.username='';dav.password='';dav.rootPath='/My Movies/动漫';v=SourceProfiles.validate(dav);assert.equal(v.rootPath,'/My Movies/动漫');
 const baidu=draft('baidu');baidu.password='';assert.throws(()=>SourceProfiles.validate(baidu));baidu.refreshToken='test-only-refresh';assert.throws(()=>SourceProfiles.validate(baidu));baidu.clientId='test-app';assert.throws(()=>SourceProfiles.validate(baidu));baidu.clientSecret='test-secret';SourceProfiles.validate(baidu);
 baidu.connectionMode='aggregate';baidu.authMode='anonymous';SourceProfiles.validate(baidu);
});
test('IPTV retains legitimate subscription query while local folders require a system URI and safe path',()=>{
 const iptv=draft('iptv');iptv.username='';iptv.password='';iptv.sourceUrl='https://tv.example/list.m3u?token=test-only';
 const v=SourceProfiles.validate(iptv);assert.equal(v.sourceUrl,iptv.sourceUrl);assert.equal(v.endpoint.host,'');
 iptv.sourceUrl='https://user:password@tv.example/list.m3u';assert.throws(()=>SourceProfiles.validate(iptv));
 const local=draft('local');local.sourceUrl='file://docs/storage/Users/currentUser/Movies';SourceProfiles.validate(local);
 local.sourceUrl='/storage/Movies';assert.throws(()=>SourceProfiles.validate(local));
 local.sourceUrl='file://docs/storage/%2e%2e/private';assert.throws(()=>SourceProfiles.validate(local));
 local.sourceUrl='file://docs/storage/show..movie';SourceProfiles.validate(local);
});
test('custom direct manifests and Guangya broker/token setup expose only their actual supported credential fields',()=>{
 const custom=draft('custom');custom.sourceUrl='https://catalog.example/library.json';
 let v=SourceProfiles.validate(custom);assert.equal(v.endpoint.host,'');assert.equal(v.sourceUrl,custom.sourceUrl);
 custom.sourceUrl='file://docs/storage/library.json';SourceProfiles.validate(custom);
 custom.connectionMode='aggregate';custom.authMode='anonymous';v=SourceProfiles.validate(custom);assert.equal(v.endpoint.host,'nas.local');assert.equal(v.sourceUrl,'');
 const guangya=draft('guangya');guangya.accessToken='test-only-token';guangya.authBrokerUrl='https://own.example/authorize';assert.throws(()=>SourceProfiles.validate(guangya));guangya.clientId='test-client';v=SourceProfiles.validate(guangya);
 assert.equal(v.authBrokerUrl,'https://own.example/authorize');assert(!SourceProfiles.fieldsFor('guangya','direct').includes('clientSecret'));
 assert.equal(SourceProfiles.authModesFor('guangya','direct')[0],'token');
});
test('SMB URI paths become actual shares and logical roots, while local picker URIs remain byte-for-byte unchanged',()=>{
 const smb=draft('smb');smb.address='smb://[2001:db8::1]/My%20Movies/动漫';smb.shareName='';
 let v=SourceProfiles.validate(smb);assert.equal(v.endpoint.host,'2001:db8::1');assert.equal(v.shareName,'My Movies');assert.equal(v.rootPath,'/动漫');assert.equal(v.endpoint.basePath,'');
 smb.shareName='Other';assert.throws(()=>SourceProfiles.validate(smb));smb.shareName='My Movies';smb.rootPath='/Another';assert.throws(()=>SourceProfiles.validate(smb));
 smb.address='https://nas.local/Movies';smb.rootPath='/';assert.throws(()=>SourceProfiles.validate(smb));
 const local=draft('local');local.sourceUrl='file://docs/storage/My Movies ';v=SourceProfiles.validate(local);
 assert.equal(v.sourceUrl,local.sourceUrl);assert.equal(v.endpoint.scheme,'file');
});

test('CloudDrive direct uses a token while its aggregate keeps WebDAV auth, and Guangya keeps an actual folder ID',()=>{
 assert.deepEqual(Array.from(SourceProfiles.authModesFor('clouddrive','direct')),['token']);
 assert(SourceProfiles.authModesFor('clouddrive','aggregate').includes('password'));
 const drive=draft('clouddrive');drive.accessToken='test-drive-token';SourceProfiles.validate(drive);drive.authMode='password';assert.throws(()=>SourceProfiles.validate(drive));
 const guangya=draft('guangya');guangya.clientId='test-client';guangya.accessToken='test-token';guangya.rootPath='1834567890123456789';assert.equal(SourceProfiles.validate(guangya).rootPath,guangya.rootPath);
 guangya.rootPath='/183456789';assert.throws(()=>SourceProfiles.validate(guangya));guangya.rootPath='/';SourceProfiles.validate(guangya);
});
console.log(`PASS: ${groups} actual endpoint/source-profile groups. No network, device or credential-vault calls.`);
