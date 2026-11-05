'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { ts, projectFile } = require('./test-env.cjs');
const source = fs.readFileSync(projectFile('entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source); assert(match, name);
  const start = source.indexOf('{', match.index); let depth = 1, end = start + 1;
  for (; depth; end++) { if (source[end] === '{') depth++; else if (source[end] === '}') depth--; }
  return source.slice(match.index, end).replace(/^  private /, '  ');
}
// The official bridge calls setNativeStack during Navigation.create, and
// the stack notifies nativeStack.onStateChanged for actual push/pop operations.
// This small framework mock checks that application behavior needs no State proxy.
class NavPathStack {
  constructor() { this.pathArray = []; this.nativeStack = undefined; this.pushes = 0; this.pops = 0; }
  setNativeStack(stack) { this.nativeStack = stack; }
  getAllPathName() { return this.pathArray.map(entry => entry.name); }
  pushPathByName(name, param) { this.pathArray.push({ name, param }); this.pushes++; this.nativeStack?.onStateChanged(); }
  pop() { const item = this.pathArray.pop(); this.pops++; this.nativeStack?.onStateChanged(); return item?.param; }
}
const declaration = /  private readonly navStack: NavPathStack = new NavPathStack\(\);/.exec(source);
assert(declaration, 'Navigation uses a stable plain controller');
assert(!/@State[^\n]*\bnavStack\b/.test(source), 'Native bridge fields must not be proxied as Index State');
assert.equal((source.match(/HdsNavigation\(this\.navStack\)/g) || []).length, 1, 'Account initialization must not remount a second navigation branch');
const names = ['stackNames', 'pushSubpage', 'ensureSubpage', 'onSubpageGone', 'clearSubState', 'popSubpage', 'popNamed'];
const text = `class Entry {
 ${declaration[0].replace('private readonly ', '')}
 navNames=[];detailItem=null;detail=null;people=[];showSearch=false;searchQuery='';searchResults=[];
 browsingLib=null;showDownloads=false;closeLibrary(){this.browsingLib=null;}
 ${names.map(method).join('\n')}
} exports.Entry=Entry;`;
const result = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(result.diagnostics.length, 0);
const context = { exports: {}, NavPathStack, hilog: { info() {} } };
vm.runInNewContext(result.outputText, context);
function fixture() {
  const page = new context.exports.Entry(); let notifications = 0;
  page.navStack.setNativeStack({ onStateChanged() { notifications++; } });
  return { page, notifications: () => notifications };
}
let passed = 0;
function test(name, body) { body(); passed++; console.log('PASS ' + name); }
test('native initialization mutates only a plain controller, preserves identity and does not write application State', () => {
  const page = new context.exports.Entry(), stack = page.navStack;
  // Reproduce why observing framework-owned internals can report a render write.
  const observed = new Proxy(new NavPathStack(), { set() { throw Error('State changed during render'); } });
  assert.throws(() => observed.setNativeStack({}), /State changed during render/);
  let changes = 0; const native = { onStateChanged() { changes++; } };
  page.navStack.setNativeStack(native); native.onStateChanged();
  assert.equal(page.navStack, stack); assert.equal(changes, 1); assert.equal(page.stackNames().length, 0);
});
test('native stack callback performs real pushes/pops without replacing the controller or depending on State', () => {
  const state = fixture(), page = state.page, stack = page.navStack;
  page.ensureSubpage('search'); page.ensureSubpage('search'); page.ensureSubpage('detail');
  assert.deepEqual(Array.from(page.stackNames()), ['search', 'detail']); assert.equal(stack.pushes, 2);
  page.popNamed('search');
  assert.equal(page.stackNames().length, 0); assert.equal(stack.pops, 2); assert.equal(state.notifications(), 4);
  assert.equal(page.navStack, stack);
});
test('system back uses the real stack, clears only the popped destination and permits re-entry', () => {
  const { page } = fixture(); page.showSearch = true; page.searchQuery = 'query';
  page.ensureSubpage('search'); page.detailItem = { id: 'detail' }; page.detail = {}; page.people = [{}]; page.ensureSubpage('detail');
  page.navStack.pop(); page.onSubpageGone('detail');
  assert.deepEqual(Array.from(page.stackNames()), ['search']); assert.equal(page.detailItem, null); assert.equal(page.showSearch, true);
  page.ensureSubpage('detail'); assert.deepEqual(Array.from(page.stackNames()), ['search', 'detail']);
  page.navStack.pop(); page.onSubpageGone('detail'); page.navStack.pop(); page.onSubpageGone('search');
  assert.equal(page.showSearch, false); assert.equal(page.searchQuery, ''); assert.equal(page.stackNames().length, 0);
});
test('explicit pop updates the native stack before shell-state watchers observe destination cleanup', () => {
  const { page } = fixture(); let value = { id: 'detail' }, stackAtClear = null;
  Object.defineProperty(page, 'detailItem', {
    get() { return value; },
    set(next) { value = next; if (next === null) stackAtClear = Array.from(page.stackNames()); }
  });
  page.ensureSubpage('detail'); page.popSubpage();
  assert.deepEqual(stackAtClear, [], 'Home resume guards must see the already-popped native stack');
});
test('player route coverage does not clear a detail that remains on the native navigation stack', () => {
  const { page } = fixture(); page.detailItem = { id: 'current' }; const detail = page.detailItem;
  page.ensureSubpage('detail'); page.onSubpageGone('detail');
  assert.equal(page.detailItem, detail); assert.deepEqual(Array.from(page.stackNames()), ['detail']);
  page.ensureSubpage('detail'); assert.equal(page.navStack.pushes, 1);
});
test('plain names snapshot cannot mutate the native stack; query failure retains the existing fallback behavior', () => {
  const { page } = fixture(); page.ensureSubpage('library'); page.ensureSubpage('downloads');
  const names = page.stackNames(); names.pop(); assert.equal(page.stackNames().length, 2);
  page.navStack.getAllPathName = () => { throw Error('bridge unavailable'); };
  assert.deepEqual(Array.from(page.stackNames()), ['library', 'downloads']);
});
console.log('PASS: ' + passed + ' actual Index navigation groups. Framework bridge mocked; no ArkUI render/device/build proof.');
