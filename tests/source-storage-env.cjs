'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const { TextEncoder, TextDecoder } = require('node:util');
const { ts, projectFile } = require('./test-env.cjs');

module.exports = function createStorageFixture() {
  const values = new Map(), writes = [], assets = new Map();
  const control = { locked: false, addCalls: 0, failAddAt: 0, failFlush: 0, uuid: 0 };
  const tag = { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, RETURN_LIMIT: 4, ACCESSIBILITY: 5, SYNC_TYPE: 6 };
  const decode = bytes => new TextDecoder().decode(bytes);
  const asset = { Tag: tag, ReturnType: { ALL: 1 }, Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, SyncType: { NEVER: 1 },
    query: async query => {
      if (control.locked) throw Object.assign(Error('locked fixture'), { code: 24000001 });
      const bytes = assets.get(decode(query.get(tag.ALIAS)));
      return bytes ? [new Map([[tag.SECRET, Uint8Array.from(bytes)]])] : [];
    },
    add: async record => {
      control.addCalls++;
      if (control.locked || control.failAddAt === control.addCalls) throw Error('fixture asset failure');
      const key = decode(record.get(tag.ALIAS));
      assert(!assets.has(key), 'Versioned assets must not overwrite an old credential');
      const bytes = record.get(tag.SECRET);
      assert(bytes.length <= 1024, 'Small individual assets, including long signed URL payloads');
      assets.set(key, Uint8Array.from(bytes));
      await Promise.resolve();
    },
    remove: async query => {
      if (control.locked) throw Error('fixture asset locked');
      const key = decode(query.get(tag.ALIAS));
      if (!assets.delete(key)) throw Object.assign(Error('fixture not found'), { code: 24000002 });
    }
  };
  const pref = { get: async (key, fallback) => values.has(key) ? values.get(key) : fallback,
    put: async (key, value) => { writes.push(key); values.set(key, value); },
    flush: async () => { if (control.failFlush > 0) { control.failFlush--; throw Error('fixture flush failure'); } } };
  const util = { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
    TextDecoder: class { decodeToString(value) { return new TextDecoder().decode(value); } },
    generateRandomUUID: () => '00000000-0000-4000-8000-' + String(++control.uuid).padStart(12, '0') };
  function load(relative, imports) {
    const code = ts.transpileModule(fs.readFileSync(projectFile(relative), 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.equal(code.diagnostics.length, 0);
    const moduleObject = { exports: {} };
    vm.runInNewContext(code.outputText, { exports: moduleObject.exports, Uint8Array, require: name => {
      assert.ok(Object.prototype.hasOwnProperty.call(imports, name), 'Known module ' + name); return imports[name];
    } });
    return moduleObject.exports;
  }
  const models = load('entry/src/main/ets/common/Models.ets', {});
  const vault = load('entry/src/main/ets/common/ServerCredentials.ets', {
    '@kit.AssetStoreKit': { asset }, '@kit.ArkTS': { util }
  });
  const repository = load('entry/src/main/ets/common/ServerRepository.ets', {
    './Models': models, './ServerCredentials': vault
  });
  const { Store } = load('entry/src/main/ets/common/Store.ets', {
    '@kit.ArkData': { preferences: { getPreferences: async () => pref } },
    './Models': models, './ServerRepository': repository
  });
  return { models, ...vault, ...repository, Store, values, writes, assets, control, pref };
};
