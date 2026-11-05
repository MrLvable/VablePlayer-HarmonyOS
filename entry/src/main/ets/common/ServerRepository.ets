import { preferences } from '@kit.ArkData';
import { ServerConfig } from './Models';
import { ServerCredentials, ServerSecretValues } from './ServerCredentials';

interface SavedServer {
  id: string; kind: string; name?: string; host: string; port: number; username?: string;
  token?: string; nativeToken?: string; userId?: string; serverName?: string; version?: string;
  scheme?: string; basePath?: string; rootPath?: string; sourceUrl?: string; epgUrl?: string;
  authMode?: string; connectionMode?: string; domain?: string; shareName?: string;
  clientId?: string; credentialRef?: string;
}
interface PreparedServer { input: ServerConfig; saved: SavedServer; secrets: ServerSecretValues; }

/** Serialized profile commits. Legacy reads are non-destructive; explicit saves migrate secrets to assets. */
export class ServerRepository {
  private static chain: Promise<void> = Promise.resolve();
  private static readonly KEY: string = 'servers_json';

  private static text(value: string | undefined, fallback: string = ''): string {
    return typeof value === 'string' ? value : fallback;
  }

  static async load(pref: preferences.Preferences): Promise<ServerConfig[]> {
    const stored = await pref.get(ServerRepository.KEY, '[]');
    // Legacy preference types must not throw at raw.length; reads never rewrite them.
    if (typeof stored !== 'string') { return []; }
    const raw = stored;
    if (raw.length > 2097152) { throw new Error('服务器配置超过读取上限'); }
    let rows: SavedServer[] = [];
    try { rows = JSON.parse(raw) as SavedServer[]; } catch (e) { return []; }
    if (!Array.isArray(rows)) { return []; }
    const output: ServerConfig[] = [];
    const ids: Set<string> = new Set();
    for (let index = 0; index < Math.min(128, rows.length); index++) {
      const row = rows[index];
      if (row === null || typeof row !== 'object' || typeof row.id !== 'string' || row.id.length === 0
        || typeof row.kind !== 'string' || row.kind.length === 0 || ids.has(row.id)) { continue; }
      const hasEndpoint = typeof row.host === 'string' && row.host.length > 0
        && Number.isInteger(row.port) && row.port >= 1 && row.port <= 65535;
      const addressless = (row.kind === 'local' || row.kind === 'iptv' || row.kind === 'custom'
        || ((row.kind === 'baidu' || row.kind === 'guangya') && row.connectionMode === 'direct'))
        && (row.host === '' || row.host === undefined) && row.port === 0;
      if (!hasEndpoint && !addressless) { continue; }
      const server = new ServerConfig(row.id, row.kind, ServerRepository.text(row.name),
        ServerRepository.text(row.host), row.port, ServerRepository.text(row.username),
        ServerRepository.text(row.token), ServerRepository.text(row.userId),
        ServerRepository.text(row.serverName), ServerRepository.text(row.version), ServerRepository.text(row.nativeToken));
      server.scheme = ServerRepository.text(row.scheme, 'http');
      server.basePath = ServerRepository.text(row.basePath);
      server.rootPath = ServerRepository.text(row.rootPath, '/');
      server.sourceUrl = ServerRepository.text(row.sourceUrl);
      server.epgUrl = ServerRepository.text(row.epgUrl);
      server.authMode = ServerRepository.text(row.authMode, 'password');
      server.connectionMode = ServerRepository.text(row.connectionMode, 'direct');
      server.domain = ServerRepository.text(row.domain);
      server.shareName = ServerRepository.text(row.shareName);
      server.clientId = ServerRepository.text(row.clientId);
      server.credentialRef = ServerRepository.text(row.credentialRef);
      if (server.credentialRef.length > 0) {
        // A vault-backed row must never fall back to stale plaintext tokens in an imported/legacy JSON object.
        server.token = ''; server.nativeToken = ''; server.sourceUrl = ''; server.epgUrl = '';
        try {
          const secrets = await ServerCredentials.read(server.credentialRef);
          if (secrets === null) { server.credentialError = '已保存的凭据不可用，请重新登录'; }
          else { ServerRepository.applySecrets(server, secrets); }
        } catch (e) { server.credentialError = '暂时无法读取安全凭据，请解锁设备后重试'; }
      }
      ids.add(server.id); output.push(server);
    }
    return output;
  }

  private static compatible(next: ServerConfig, old: ServerConfig): boolean {
    return next.kind === old.kind && next.connectionMode === old.connectionMode && next.authMode === old.authMode
      && next.username === old.username && next.domain === old.domain && next.clientId === old.clientId
      && (next.userId.length === 0 || old.userId.length === 0 || next.userId === old.userId);
  }

  private static values(server: ServerConfig): ServerSecretValues {
    const secrets = new ServerSecretValues();
    secrets.token = ServerRepository.text(server.token); secrets.nativeToken = ServerRepository.text(server.nativeToken);
    secrets.password = ServerRepository.text(server.password); secrets.clientSecret = ServerRepository.text(server.clientSecret);
    secrets.refreshToken = ServerRepository.text(server.refreshToken); secrets.sourceUrl = ServerRepository.text(server.sourceUrl);
    secrets.epgUrl = ServerRepository.text(server.epgUrl); secrets.authBrokerUrl = ServerRepository.text(server.authBrokerUrl);
    return secrets;
  }

  private static applySecrets(server: ServerConfig, secrets: ServerSecretValues): void {
    server.token = secrets.token; server.nativeToken = secrets.nativeToken; server.password = secrets.password;
    server.clientSecret = secrets.clientSecret; server.refreshToken = secrets.refreshToken;
    server.sourceUrl = secrets.sourceUrl; server.epgUrl = secrets.epgUrl; server.authBrokerUrl = secrets.authBrokerUrl;
  }

  private static publicRow(server: ServerConfig, ref: string): SavedServer {
    return { id: server.id, kind: server.kind, name: server.name, host: server.host, port: server.port,
      username: server.username, userId: server.userId, serverName: server.serverName, version: server.version,
      scheme: server.scheme, basePath: server.basePath, rootPath: server.rootPath,
      authMode: server.authMode, connectionMode: server.connectionMode, domain: server.domain,
      shareName: server.shareName, clientId: server.clientId, credentialRef: ref };
  }

  private static nonempty(values: ServerSecretValues): boolean {
    return values.token.length + values.nativeToken.length + values.password.length + values.clientSecret.length
      + values.refreshToken.length + values.sourceUrl.length + values.epgUrl.length + values.authBrokerUrl.length > 0;
  }

  private static enqueue(task: () => Promise<void>): Promise<void> {
    const next = ServerRepository.chain.then(task);
    ServerRepository.chain = next.then(() => {}, () => {});
    return next;
  }

  private static async commit(pref: preferences.Preferences, input: ServerConfig[]): Promise<void> {
    if (input.length > 128) { throw new Error('服务器数量已达上限'); }
    const previousRaw = await pref.get(ServerRepository.KEY, '[]') as string;
    const old = await ServerRepository.load(pref);
    const prepared: PreparedServer[] = [];
    const created: string[] = [];
    const ids: Set<string> = new Set();
    try {
      for (let index = 0; index < input.length; index++) {
        const server = input[index];
        if (server.id.length === 0 || server.kind.length === 0 || ids.has(server.id)) { throw new Error('服务器标识无效或重复'); }
        ids.add(server.id);
        const prior = old.find((value: ServerConfig) => value.id === server.id);
        const secrets = ServerRepository.values(server);
        const preserve = prior !== undefined && !server.clearCredentials && ServerRepository.compatible(server, prior);
        if (preserve && prior !== undefined) {
          if (secrets.token.length === 0) { secrets.token = prior.token; }
          if (secrets.nativeToken.length === 0) { secrets.nativeToken = prior.nativeToken; }
          if (secrets.password.length === 0) { secrets.password = prior.password; }
          if (secrets.clientSecret.length === 0) { secrets.clientSecret = prior.clientSecret; }
          if (secrets.refreshToken.length === 0) { secrets.refreshToken = prior.refreshToken; }
        }
        // Resource URLs are this edit's values, including a deliberate empty EPG; clearing authentication does not erase them.
        let ref = '';
        if (preserve && prior !== undefined && prior.credentialRef.length > 0
          && JSON.stringify(secrets) === JSON.stringify(ServerRepository.values(prior))) { ref = prior.credentialRef; }
        else if (ServerRepository.nonempty(secrets)) { ref = await ServerCredentials.write(secrets); created.push(ref); }
        prepared.push({ input: server, saved: ServerRepository.publicRow(server, ref), secrets: secrets });
      }
    } catch (e) {
      for (let index = 0; index < created.length; index++) { try { await ServerCredentials.remove(created[index]); } catch (cleanupError) {} }
      throw (e as Error);
    }
    const nextRaw = JSON.stringify(prepared.map((value: PreparedServer) => value.saved));
    try { await pref.put(ServerRepository.KEY, nextRaw); await pref.flush(); }
    catch (e) {
      let restored = false;
      try { await pref.put(ServerRepository.KEY, previousRaw); await pref.flush(); restored = true; } catch (rollbackError) {}
      // If rollback cannot be confirmed, retaining the encrypted asset is safer than breaking a possibly committed reference.
      if (restored) {
        for (let index = 0; index < created.length; index++) { try { await ServerCredentials.remove(created[index]); } catch (cleanupError) {} }
      }
      throw new Error('服务器配置保存失败，请重新打开配置检查后重试');
    }
    for (let index = 0; index < prepared.length; index++) {
      const value = prepared[index]; value.input.credentialRef = ServerRepository.text(value.saved.credentialRef);
      value.input.credentialError = ''; value.input.clearCredentials = false;
      ServerRepository.applySecrets(value.input, value.secrets);
    }
    const live = new Set(prepared.map((value: PreparedServer) => value.saved.credentialRef));
    for (let index = 0; index < old.length; index++) {
      const ref = old[index].credentialRef;
      if (ref.length > 0 && !live.has(ref)) { try { await ServerCredentials.remove(ref); } catch (cleanupError) {} }
    }
  }

  static save(pref: preferences.Preferences, list: ServerConfig[]): Promise<void> {
    return ServerRepository.enqueue(() => ServerRepository.commit(pref, list));
  }

  static upsert(pref: preferences.Preferences, server: ServerConfig): Promise<void> {
    return ServerRepository.enqueue(async () => {
      const list = await ServerRepository.load(pref);
      const at = list.findIndex((value: ServerConfig) => value.id === server.id);
      if (at < 0) { list.push(server); } else { list[at] = server; }
      await ServerRepository.commit(pref, list);
    });
  }

  static remove(pref: preferences.Preferences, id: string): Promise<void> {
    return ServerRepository.enqueue(async () => {
      const list = (await ServerRepository.load(pref)).filter((value: ServerConfig) => value.id !== id);
      await ServerRepository.commit(pref, list);
    });
  }

  static async refresh(pref: preferences.Preferences, server: ServerConfig, expectedRef: string): Promise<boolean> {
    let updated = false;
    await ServerRepository.enqueue(async () => {
      const list = await ServerRepository.load(pref);
      const prior = list.find((value: ServerConfig) => value.id === server.id);
      if (prior === undefined || prior.credentialRef !== expectedRef || !ServerRepository.compatible(server, prior)
        || prior.host !== server.host || prior.port !== server.port || prior.scheme !== server.scheme
        || prior.basePath !== server.basePath || prior.sourceUrl !== server.sourceUrl
        || (prior.userId.length > 0 && prior.userId !== server.userId)) { return; }
      // Refresh only secrets. A concurrent display-name or browsing preference edit stays authoritative.
      prior.token = server.token;
      if (server.nativeToken.length > 0) { prior.nativeToken = server.nativeToken; }
      if (server.refreshToken.length > 0) { prior.refreshToken = server.refreshToken; }
      await ServerRepository.commit(pref, list);
      server.credentialRef = prior.credentialRef;
      updated = true;
    });
    return updated;
  }
}
