'use strict';
// Runs the real Models/EmbyClient methods with a bounded HTTP fixture. No live
// server, runtime account, key, or password is used by this suite.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { ts, projectFile } = require('./test-env.cjs');
const common = projectFile('entry/src/main/ets/common');
let passed = 0;

function environment() {
  const modules = new Map(), pending = [], requests = [], debug = [];
  let created = 0, destroyed = 0;
  function load(file) {
    file = path.resolve(file);
    if (modules.has(file)) return modules.get(file).exports;
    const module = { exports: {} }; modules.set(file, module);
    const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
      reportDiagnostics: true,
    });
    assert.equal((result.diagnostics || []).length, 0, file);
    const requireForModule = name => {
      if (name === './Dbg') return { Dbg: {
        setApi: (...values) => debug.push(values), setImage: (...values) => debug.push(values),
      } };
      if (name === '@kit.NetworkKit') return { http: {
        RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE' },
        HttpDataType: { STRING: 'STRING' },
        createHttp() {
          created++;
          let closed = false;
          return {
            destroy() { assert(!closed, 'HTTP request is destroyed exactly once'); closed = true; destroyed++; },
            async request(url, options) {
              requests.push({ url, options });
              assert(pending.length > 0, 'Unexpected HTTP request');
              const response = pending.shift();
              if (response.error) throw response.error;
              return { responseCode: response.code, result: response.raw };
            },
          };
        },
      } };
      assert(name.startsWith('.'), 'Unexpected external dependency: ' + name);
      return load(path.resolve(path.dirname(file), name + '.ets'));
    };
    vm.runInNewContext(result.outputText, {
      module, exports: module.exports, require: requireForModule,
    }, { filename: file });
    return module.exports;
  }
  const { ServerConfig } = load(path.join(common, 'Models.ets'));
  const { EmbyClient } = load(path.join(common, 'EmbyClient.ets'));
  return {
    client: EmbyClient, requests, debug,
    server(kind = 'jellyfin') {
      const server = new ServerConfig('fixture-device-"中"', kind, 'Fixture', 'media.example.invalid',
        9443, 'fixture-account', 'fixture-session-token', 'fixture-user-id');
      server.scheme = 'https'; server.basePath = '/jellyfin';
      return server;
    },
    reply(code = 200, value = {}) { pending.push({ code, raw: typeof value === 'string' ? value : JSON.stringify(value) }); },
    networkError(error) { pending.push({ error }); },
    complete() {
      assert.equal(pending.length, 0, 'Every fixture response was consumed');
      assert.equal(created, destroyed, 'All HTTP requests are released on success and failure');
    },
  };
}

function modern(header, server, token = server.token) {
  assert(header && typeof header.Authorization === 'string');
  assert.match(header.Authorization, /^MediaBrowser /);
  assert.match(header.Authorization, /^[\x20-\x7e]+$/, 'HTTP header is ASCII even for a quoted/Unicode device id');
  const parameters = {};
  for (const match of header.Authorization.matchAll(/([A-Za-z0-9]+)="([^"]*)"/g)) {
    parameters[match[1]] = decodeURIComponent(match[2]);
  }
  assert.equal(parameters.Client, 'VablePlayer');
  assert.equal(parameters.Device, 'HarmonyOS');
  assert.equal(parameters.DeviceId, 'nasplayer-' + server.id);
  assert.equal(parameters.Version, '1.0.0');
  if (token === null) assert(!Object.hasOwn(parameters, 'Token'), 'Password login must not send a stale access token');
  else assert.equal(parameters.Token, token);
  assert(!Object.hasOwn(header, 'X-Emby-Authorization'));
  assert(!Object.hasOwn(header, 'X-Emby-Token'));
}

async function test(name, body) {
  const env = environment();
  await body(env);
  env.complete();
  passed++;
  console.log('PASS ' + name);
}

(async () => {
  await test('password login uses the official JSON DTO and token-free MediaBrowser header', async env => {
    const server = env.server(), password = '  fixture!?+"\\.密碼  ';
    env.reply(200, { AccessToken: 'fixture-new-session', User: { Id: 'fixture-new-user' } });
    const logged = await env.client.login(server, password);
    const request = env.requests[0];
    assert.equal(request.url, 'https://media.example.invalid:9443/jellyfin/Users/AuthenticateByName');
    assert.equal(request.options.method, 'POST');
    assert.equal(request.options.header['Content-Type'], 'application/json');
    assert.deepEqual(JSON.parse(request.options.extraData), { Username: server.username, Pw: password });
    modern(request.options.header, server, null);
    assert.equal(logged.token, 'fixture-new-session');
    assert.equal(logged.userId, 'fixture-new-user');
    assert.equal(server.token, 'fixture-session-token', 'Login does not mutate a saved source before its caller commits');
  });

  await test('empty-password Jellyfin accounts still authenticate and receive a real user session', async env => {
    const server = env.server(); server.token = '';
    env.reply(200, { AccessToken: 'fixture-empty-password-session', User: { Id: server.userId } });
    const logged = await env.client.login(server, '');
    assert.equal(JSON.parse(env.requests[0].options.extraData).Pw, '');
    modern(env.requests[0].options.header, server, null);
    assert.equal(logged.token, 'fixture-empty-password-session');
  });

  await test('authenticated catalog GET preserves HTTPS and a reverse-proxy base path', async env => {
    const server = env.server();
    env.reply(200, { Items: [{ Id: 'fixture-library', Name: 'Movies', Type: 'CollectionFolder' }] });
    const views = await env.client.getViews(server);
    assert.equal(views.length, 1); assert.equal(views[0].id, 'fixture-library');
    assert.equal(env.requests[0].url, server.baseUrl() + '/Users/' + server.userId + '/Views');
    assert.equal(env.requests[0].options.method, 'GET');
    modern(env.requests[0].options.header, server);
  });

  await test('token-user verification sends the modern header and checks the actual returned identity', async env => {
    const server = env.server();
    env.reply(200, { Id: server.userId }); await env.client.verifyTokenUser(server);
    modern(env.requests[0].options.header, server);
    env.reply(200, { Id: 'another-fixture-user' });
    await assert.rejects(env.client.verifyTokenUser(server), /身份不匹配/);
  });

  await test('PlaybackInfo and progress POSTs use the same authenticated MediaBrowser session', async env => {
    const server = env.server();
    env.reply(200, { MediaSources: [{ Id: 'fixture-source', SupportsDirectPlay: true,
      DirectStreamUrl: '/Videos/fixture-item/stream?Static=true' }] });
    const info = await env.client.getPlaybackInfo(server, 'fixture-item', 'fixture-source', 120000000);
    assert(info.url.includes('/Videos/fixture-item/stream'));
    assert(env.requests[0].url.startsWith(server.baseUrl() + '/Items/fixture-item/PlaybackInfo?'));
    modern(env.requests[0].options.header, server);
    env.reply(204, ''); await env.client.reportProgress(server, 'fixture-item', 150000000, false);
    assert.equal(env.requests[1].url, server.baseUrl() + '/Sessions/Playing/Progress');
    modern(env.requests[1].options.header, server);
    assert.equal(JSON.parse(env.requests[1].options.extraData).PositionTicks, 150000000);
  });

  await test('player, stream, and image headers remain valid when legacy Jellyfin auth is disabled', async env => {
    const server = env.server(); server.token = 'fixture-token-with-"quote",comma+%';
    for (const method of ['playHeaders', 'streamHeaders', 'imageHeaders']) modern(env.client[method](server), server);
  });

  await test('Jellyfin artwork URLs contain no access token and use explicit image headers', async env => {
    const server = env.server();
    const urls = [env.client.imageUrl(server, 'fixture-item', 640, 'fixture-tag'),
      env.client.backdropUrl(server, 'fixture-item', 1280, 'fixture-backdrop', ''),
      env.client.backdropUrl(server, 'fixture-item', 1280, '', 'fixture-primary'),
      env.client.personImageUrl(server, 'fixture-person', 320)];
    for (const value of urls) {
      const url = new URL(value);
      assert(value.startsWith(server.baseUrl() + '/Items/'));
      assert(!value.includes(server.token));
      assert([...url.searchParams.keys()].every(key => !/token|api.?key|authorization/i.test(key)));
    }
    assert(!JSON.stringify(env.debug).includes(server.token));
    modern(env.client.imageHeaders(server), server);
  });

  await test('headerless subtitle APIs receive only the official case-sensitive encoded ApiKey fallback', async env => {
    const server = env.server(); server.token = 'fixture-subtitle-token+%&"中';
    for (const [codec, extension] of [['ass', 'ass'], ['SSA', 'ass'], ['webvtt', 'vtt'], ['srt', 'srt']]) {
      const value = env.client.subtitleUrl(server, 'fixture-item', 'fixture-source', 3, codec);
      const url = new URL(value);
      assert.equal(url.pathname, '/jellyfin/Videos/fixture-item/fixture-source/Subtitles/3/0/Stream.' + extension);
      assert.deepEqual([...url.searchParams.keys()], ['ApiKey']);
      assert.equal(url.searchParams.get('ApiKey'), server.token);
      assert(!value.includes(server.token));
    }
    assert(new URL(env.client.subtitleUrl(server, 'fixture-item', '', 0, 'srt')).pathname.includes('/fixture-item/fixture-item/'));
  });

  await test('item details, favorite state, and people requests include the current Jellyfin user context', async env => {
    const server = env.server(); server.userId = 'fixture-user+"中';
    env.reply(200, { Id: 'fixture-item', Name: 'Fixture movie', Type: 'Movie', UserData: { IsFavorite: true } });
    const detail = await env.client.getItemDetail(server, 'fixture-item');
    assert.equal(detail.item.name, 'Fixture movie');
    env.reply(200, { UserData: { IsFavorite: true } });
    assert.equal(await env.client.isFavorite(server, 'fixture-item'), true);
    env.reply(200, { People: [{ Id: 'fixture-person', Name: 'Fixture actor', Type: 'Actor' }] });
    const people = await env.client.getPeople(server, 'fixture-item');
    assert.equal(people[0].id, 'fixture-person');
    assert.equal(env.requests.length, 3);
    for (const request of env.requests) {
      assert.equal(new URL(request.url).searchParams.get('UserId'), server.userId);
      modern(request.options.header, server);
    }
  });

  await test('favorite DELETE uses modern authorization and rejects forbidden updates without body leakage', async env => {
    const server = env.server();
    env.reply(204, ''); await env.client.removeFavorite(server, 'fixture-item');
    assert.equal(env.requests[0].url, server.baseUrl() + '/Users/' + server.userId + '/FavoriteItems/fixture-item');
    assert.equal(env.requests[0].options.method, 'DELETE'); modern(env.requests[0].options.header, server);
    env.reply(403, 'fixture-private-response');
    await assert.rejects(env.client.removeFavorite(server, 'fixture-item'), error => {
      assert.match(error.message, /权限/); assert.match(error.message, /HTTP 403/);
      assert(!error.message.includes('fixture-private-response')); return true;
    });
  });

  await test('HTTP 401 is classified before JSON parsing and never echoes the response body', async env => {
    const server = env.server(), marker = 'fixture-upstream-secret-do-not-display';
    env.reply(401, '<html>' + marker + '</html>');
    await assert.rejects(env.client.login(server, 'fixture-password'), error => {
      assert.match(error.message, /账号或密码/); assert.match(error.message, /HTTP 401/);
      assert(!error.message.includes(marker)); assert(!error.message.includes('JSON')); return true;
    });
    assert(!JSON.stringify(env.debug).includes(marker));
    assert.deepEqual(env.debug, [['/Users/AuthenticateByName', 'HTTP 401']]);
  });

  await test('expired catalog tokens produce a re-login error instead of a password or parsing error', async env => {
    const server = env.server(); env.reply(401, 'fixture-untrusted-body');
    await assert.rejects(env.client.getViews(server), error => {
      assert.match(error.message, /重新登录/); assert.match(error.message, /HTTP 401/);
      assert(!error.message.includes('fixture-untrusted-body')); return true;
    });
  });

  await test('permission, wrong endpoint, throttling, and server failures retain only safe status diagnostics', async env => {
    const server = env.server();
    for (const [status, expected] of [[400, /请求失败/], [403, /权限/], [404, /端口.*子路径/],
      [429, /频繁/], [500, /服务器或反向代理/], [502, /服务器或反向代理/]]) {
      env.reply(status, 'fixture-sensitive-response-' + status);
      await assert.rejects(env.client.login(server, 'fixture-password'), error => {
        assert.match(error.message, expected); assert(error.message.includes('HTTP ' + status));
        assert(!error.message.includes('fixture-sensitive-response')); return true;
      });
    }
    assert(!JSON.stringify(env.debug).includes('fixture-sensitive-response'));
  });

  await test('successful HTTP with HTML, malformed JSON, or non-object login results is rejected safely', async env => {
    const server = env.server();
    for (const raw of ['<html>fixture-not-an-api</html>', '{bad-json', 'null', '[]', 'true', '"fixture-string"']) {
      env.reply(200, raw);
      await assert.rejects(env.client.login(server, 'fixture-password'), error => {
        assert.match(error.message, /登录失败/);
        assert(!error.message.includes('fixture-not-an-api')); assert(!error.message.includes('{bad-json'));
        return true;
      });
    }
  });

  await test('malformed or missing token/user values cannot become a falsely successful login', async env => {
    const server = env.server();
    for (const body of [{}, { AccessToken: '', User: { Id: server.userId } },
      { AccessToken: 42, User: { Id: server.userId } }, { AccessToken: 'fixture-session', User: null },
      { AccessToken: 'fixture-session', User: { Id: 42 } }]) {
      env.reply(200, body);
      await assert.rejects(env.client.login(server, 'fixture-password'), /登录失败.*token/);
    }
  });

  await test('transport failures release the native HTTP handle on login and catalog paths', async env => {
    const server = env.server();
    for (const action of [() => env.client.login(server, 'fixture-password'), () => env.client.getViews(server)]) {
      const error = new Error('fixture-network-unavailable'); env.networkError(error);
      await assert.rejects(action(), value => value === error);
    }
  });

  await test('FnOS and Emby keep their existing legacy protocol and password payload', async env => {
    for (const kind of ['fnos', 'fnos-native', 'emby']) {
      const server = env.server(kind), password = 'fixture-legacy!? '; 
      env.reply(200, { AccessToken: 'fixture-legacy-session', User: { Id: server.userId } });
      await env.client.login(server, password);
      const request = env.requests.at(-1), headers = request.options.header;
      assert.deepEqual(JSON.parse(request.options.extraData), { Username: server.username, Pw: password, Password: password });
      assert.equal(headers['X-Emby-Authorization'], server.authHeader());
      assert.equal(headers['X-Emby-Token'], server.token);
      assert(!Object.hasOwn(headers, 'Authorization'));
      for (const method of ['playHeaders', 'imageHeaders']) {
        assert.equal(env.client[method](server)['X-Emby-Authorization'], server.authHeader());
        assert.equal(env.client[method](server)['X-Emby-Token'], server.token);
      }
      assert.equal(env.client.streamHeaders(server).Authorization, server.token);
      assert.equal(env.client.streamHeaders(server)['X-Emby-Token'], server.token);
      for (const url of [env.client.imageUrl(server, 'fixture-item', 640, 'fixture-tag'),
        env.client.backdropUrl(server, 'fixture-item', 1280, 'fixture-backdrop', ''),
        env.client.personImageUrl(server, 'fixture-person', 320)]) {
        assert.equal(new URL(url).searchParams.get('X-Emby-Token'), server.token);
      }
      const subtitle = new URL(env.client.subtitleUrl(server, 'fixture-item', 'fixture-source', 1, 'srt'));
      assert.equal(subtitle.searchParams.get('X-Emby-Token'), server.token);
      assert.equal(subtitle.searchParams.get('api_key'), server.token);
      assert(!subtitle.searchParams.has('ApiKey'));
    }
  });

  console.log('PASS Jellyfin official authentication regression: ' + passed + ' groups (real methods; mocked HTTP, no live-server claim)');
})().catch(error => { console.error(error); process.exitCode = 1; });
