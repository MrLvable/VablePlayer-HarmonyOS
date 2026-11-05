'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
const {projectFile}=require('./test-env.cjs');
const source=fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'),'utf8');
const start=source.indexOf('// ══════ 剧集卡片（3 列横排）══════');assert(start>=0);
const section=source.slice(start,source.indexOf('// ══════ 相册 ══════',start));
function blockAt(open){let depth=1,end=open+1;for(;depth;end++){if(section[end]==='{')depth++;if(section[end]==='}')depth--;}return{body:section.slice(open+1,end-1),end};}
const rowStart=section.indexOf('Row() {'),row=blockAt(section.indexOf('{',rowStart));
const rowStyle=section.slice(row.end,section.indexOf('}',row.end));
const cardStart=section.indexOf('Column() {',section.indexOf('ForEach(this.visibleEpisodes()'));
const card=blockAt(section.indexOf('{',cardStart));const cardStyle=section.slice(card.end,section.indexOf('.onClick',card.end));
let groups=0;function test(name,run){run();groups++;console.log('PASS: '+name)}
test('actual episode parent Row aligns card tops, independent of overview/year metadata height',()=>{
 assert(/\.alignItems\(VerticalAlign\.Top\)/.test(rowStyle),'Top must belong to the parent Row, not a caption/image child');
 const align=/\.alignItems\(VerticalAlign\.(\w+)\)/.exec(rowStyle)?.[1]??'Center';
 const imageHeight=300/(16/9);
 const variants=[{year:0,title:20,overview:0},{year:16,title:20,overview:0},{year:16,title:20,overview:16},{year:16,title:20,overview:32}];
 const heights=variants.map(value=>imageHeight+18+value.year+value.title+value.overview);
 const maximum=Math.max(...heights);const tops=heights.map(height=>align==='Top'?0:(maximum-height)/2);
 assert(heights.some(height=>height!==maximum),'Fixture must include genuinely shorter cards');
 assert(tops.every(top=>top===tops[0]),'Mixed empty/one/two-line metadata must not move images vertically');
 assert(heights.some(height=>(maximum-height)/2!==0),'The previous default Center layout must fail this regression');
});
test('actual card pins content to its top and keeps the same fixed 16:9 image viewport',()=>{
 assert(/\.width\(300\)/.test(cardStyle));assert(/\.justifyContent\(FlexAlign\.Start\)/.test(cardStyle));assert(/\.alignItems\(HorizontalAlign\.Start\)/.test(cardStyle));
 assert(card.body.includes('.aspectRatio(16 / 9)'));assert(!cardStyle.includes('.layoutWeight('));
 assert(/\.width\('100%'\)\s*\.aspectRatio\(16 \/ 9\)/.test(card.body));
 assert(card.body.includes('if (ep.year > 0)'));assert(card.body.includes('if (ep.overview.length > 0)'));assert(card.body.includes('.maxLines(1)'));assert(card.body.includes('.maxLines(2)'));
 assert(!/\.height\([^)]*overview/.test(card.body));
});
test('existing episode render path remains a horizontal list with stable identity and play action',()=>{
 assert.equal((source.match(/ForEach\(this\.visibleEpisodes\(\)/g)||[]).length,1,'Check all active visibleEpisodes render paths');
 assert(section.includes('.scrollable(ScrollDirection.Horizontal)'));assert(section.includes('}, (ep: MediaItem) => ep.id)'));assert(section.includes('this.playItem(ep)'));
 assert(section.includes('.padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })'));assert(section.includes('.margin({ right: 12 })'));
});
console.log(`PASS: ${groups} actual episode-builder layout contracts; mixed metadata uses SDK Row cross-axis geometry. No device/pixel-render proof.`);
