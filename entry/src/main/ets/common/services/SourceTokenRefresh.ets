import { ServerConfig } from '../Models';
import { SourceIdentity } from './SourceIdentity';
import { SourceAuthConfig, SourceTokenRotation } from './SourceAuthorization';

export class SourceOAuthTokens {
  accessToken: string = '';
  refreshToken: string = '';
  userId: string = '';
  expiresAt: number = 0;
}
class SourceRefreshReplay {
  next: ServerConfig;
  savedAt: number = 0;
  accessExpiresAt: number = 0;
  constructor(next: ServerConfig, expires: number) { this.next = SourceAuthConfig.copy(next); this.savedAt = Date.now(); this.accessExpiresAt = expires; }
}

/** No network retry: rotating refresh tokens must never be reused after a failed exchange. */
export class SourceTokenRefresh {
  private static active: Map<string, Promise<ServerConfig>> = new Map();
  private static consumed: Set<string> = new Set();
  private static recent: Map<string, SourceRefreshReplay> = new Map();
  private static readonly REPLAY_TTL: number = 3600000;
  private static identity(server: ServerConfig): string {
    // Names/version are presentation metadata. All credential and endpoint identity participates in the digest.
    return SourceIdentity.key(JSON.stringify([server.kind, server.id, server.credentialRef, server.clientId,
      server.scheme, server.host, server.port, server.basePath, server.rootPath, server.sourceUrl, server.epgUrl,
      server.authBrokerUrl, server.connectionMode, server.authMode, server.username, server.domain, server.shareName,
      server.userId, server.token, server.refreshToken, server.clientSecret, server.password, server.nativeToken]));
  }
  private static prune(): void {
    SourceTokenRefresh.recent.forEach((entry: SourceRefreshReplay, key: string) => {
      if (Date.now() - entry.savedAt >= SourceTokenRefresh.REPLAY_TTL) { SourceTokenRefresh.recent.delete(key); }
    });
    while (SourceTokenRefresh.recent.size > 64) { let first = ''; SourceTokenRefresh.recent.forEach((_entry: SourceRefreshReplay, key: string) => { if (first.length === 0) { first = key; } }); SourceTokenRefresh.recent.delete(first); }
  }
  private static adopt(target: ServerConfig, next: ServerConfig): void {
    target.token = next.token; target.refreshToken = next.refreshToken; target.userId = next.userId;
    target.credentialRef = next.credentialRef; target.credentialError = next.credentialError;
  }
  static apply(server: ServerConfig, tokens: SourceOAuthTokens): void {
    if (tokens.accessToken.length === 0) { throw new Error('授权响应没有有效 access_token'); }
    server.token = tokens.accessToken;
    server.credentialError = '';
    if (tokens.refreshToken.length > 0) { server.refreshToken = tokens.refreshToken; }
    // This app-local progress namespace is not a remote UID. A valid refresh
    // keeps it stable; an explicit new authorization clears it before applying tokens.
    if (tokens.userId.length > 0 && !server.userId.startsWith('local:')) { server.userId = tokens.userId; }
  }
  static async run(server: ServerConfig, exchange: (snapshot: ServerConfig) => Promise<SourceOAuthTokens>,
                   onRotate: SourceTokenRotation | null, singleUse: boolean = true): Promise<ServerConfig> {
    if (server.refreshToken.length === 0) { throw new Error('需要重新授权：没有可用的 refresh_token'); }
    const ref = server.credentialRef; const original = server.refreshToken; const originalToken = server.token;
    const key = SourceTokenRefresh.identity(server);
    SourceTokenRefresh.prune(); let replay = SourceTokenRefresh.recent.get(key);
    if (replay !== undefined) {
      const seen: Set<string> = new Set([key]);
      for (let hop = 0; hop < 64; hop++) {
        const nextKey = SourceTokenRefresh.identity(replay.next); const further = SourceTokenRefresh.recent.get(nextKey);
        if (further === undefined) { break; }
        if (seen.has(nextKey)) { throw new Error('来源刷新记录异常，请重新载入已保存来源'); } seen.add(nextKey); replay = further;
      }
      const next = SourceAuthConfig.copy(replay.next); const expires = replay.accessExpiresAt;
      // Callers may hold an ArkUI-observed profile; never replay credentials on the invoking render stack.
      await Promise.resolve();
      if (SourceTokenRefresh.identity(server) !== key) { throw new Error('来源配置已改变，已忽略旧刷新结果'); }
      SourceTokenRefresh.adopt(server, next);
      if (!Number.isFinite(expires) || expires <= Date.now() + 5000) { return SourceTokenRefresh.run(server, exchange, onRotate, singleUse); }
      return server;
    }
    const prior = SourceTokenRefresh.active.get(key);
    let operation = prior;
    if (operation === undefined) {
      const consumed = SourceIdentity.key(server.kind + '\u0000' + server.clientId + '\u0000' + original);
      if (SourceTokenRefresh.consumed.has(consumed)) { throw new Error('此刷新凭据已使用或失败，请重新授权，不能循环重试旧令牌'); }
      SourceTokenRefresh.consumed.add(consumed);
      if (SourceTokenRefresh.consumed.size > 512) { let first = ''; SourceTokenRefresh.consumed.forEach((id: string) => { if (first.length === 0) { first = id; } }); SourceTokenRefresh.consumed.delete(first); }
      const snapshot = SourceAuthConfig.copy(server);
      operation = SourceTokenRefresh.exchange(server, snapshot, ref, exchange, onRotate);
      SourceTokenRefresh.active.set(key, operation);
    }
    try {
      const result = await operation;
      const unchanged = SourceTokenRefresh.identity(server) === key;
      const applied = SourceTokenRefresh.identity(server) === SourceTokenRefresh.identity(result);
      if (!unchanged && !applied) { throw new Error('来源授权已被其他操作更新，已忽略旧刷新结果'); }
      SourceTokenRefresh.adopt(server, result);
      if (!singleUse && result.refreshToken === original) { SourceTokenRefresh.consumed.delete(SourceIdentity.key(server.kind + '\u0000' + server.clientId + '\u0000' + original)); }
      return server;
    } catch (e) {
      if (server.token === originalToken) { server.credentialError = '令牌刷新失败，请重新授权'; }
      const error = e as Error; throw new Error(error.message.startsWith('来源') || error.message.startsWith('令牌') ? error.message : '令牌刷新失败，请重新授权');
    } finally { if (SourceTokenRefresh.active.get(key) === operation) { SourceTokenRefresh.active.delete(key); } }
  }
  private static async exchange(server: ServerConfig, snapshot: ServerConfig, ref: string,
    request: (snapshot: ServerConfig) => Promise<SourceOAuthTokens>, onRotate: SourceTokenRotation | null): Promise<ServerConfig> {
    const tokens = await request(snapshot);
    const originalIdentity = SourceTokenRefresh.identity(snapshot);
    if (SourceTokenRefresh.identity(server) !== originalIdentity) { throw new Error('来源授权已被其他操作更新，已忽略旧刷新结果'); }
    const next = SourceAuthConfig.copy(snapshot); SourceTokenRefresh.apply(next, tokens);
    // Keep the newly rotated token in this request's runtime even when secure persistence fails.
    SourceTokenRefresh.apply(server, tokens);
    if (onRotate !== null) {
      try { await onRotate(next, ref); }
      catch (e) { server.credentialError = '令牌已轮换，但安全保存未完成，请重新保存来源配置'; throw new Error(server.credentialError); }
    }
    const pending = SourceAuthConfig.copy(next); pending.credentialRef = ref;
    if (SourceTokenRefresh.identity(server) !== SourceTokenRefresh.identity(pending) && SourceTokenRefresh.identity(server) !== SourceTokenRefresh.identity(next)) { throw new Error('来源授权已被其他操作更新，已忽略旧刷新结果'); }
    // The storage CAS callback may replace the credential reference after its successful commit.
    server.credentialRef = next.credentialRef;
    if (onRotate !== null && ref.length > 0 && next.credentialRef.length > 0 && next.credentialRef !== ref) {
      SourceTokenRefresh.recent.delete(originalIdentity); SourceTokenRefresh.recent.set(originalIdentity, new SourceRefreshReplay(next, tokens.expiresAt)); SourceTokenRefresh.prune();
    }
    return next;
  }
}
