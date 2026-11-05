import { url } from '@kit.ArkTS';
import { ServerConfig } from '../Models';
import { DirectSourceHttp, SourceResponse } from './DirectSourceHttp';
import { SourceAuthorization, SourceAuthPoll, SourceAuthConfig, SourceTokenRotation } from './SourceAuthorization';
import { SourceOAuthTokens, SourceTokenRefresh } from './SourceTokenRefresh';

interface GuangyaOAuthReply {
  device_code?: string; user_code?: string; verification_uri_complete?: string; verification_url?: string;
  expires_in?: number; interval?: number; device_id?: string; project_id?: string;
  access_token?: string; refresh_token?: string; sub?: string; error?: string;
}
interface GuangyaTokenBody { client_id: string; grant_type: string; device_code?: string; refresh_token?: string; }
interface GuangyaBrokerBody { client_id: string; }

export class GuangyaAuthorization {
  static onRotate: SourceTokenRotation | null = null;
  private transport: DirectSourceHttp = new DirectSourceHttp();
  cancel(): void { this.transport.cancel(); }
  private static parse(response: SourceResponse): GuangyaOAuthReply {
    try { return JSON.parse(response.text) as GuangyaOAuthReply; } catch (e) { throw new Error('光鸭授权响应格式无效'); }
  }
  private static tokens(data: GuangyaOAuthReply): SourceOAuthTokens {
    if (typeof data.access_token !== 'string' || data.access_token.length === 0 || !Number.isFinite(data.expires_in) || (data.expires_in as number) <= 0) { throw new Error('光鸭授权没有返回有效令牌'); }
    const tokens = new SourceOAuthTokens(); tokens.accessToken = data.access_token; tokens.refreshToken = typeof data.refresh_token === 'string' ? data.refresh_token : '';
    tokens.userId = typeof data.sub === 'string' ? data.sub : ''; tokens.expiresAt = Date.now() + (data.expires_in as number) * 1000; return tokens;
  }
  async authorize(server: ServerConfig): Promise<SourceAuthorization> {
    if (server.clientId.length === 0 || server.authBrokerUrl.length === 0) { throw new Error('光鸭设备授权需要已注册的 client_id 和您配置的授权代理；也可导入已有用户令牌'); }
    const broker = server.authBrokerUrl;
    const address = DirectSourceHttp.resolve(broker, broker); const parsed = new url.URL(address);
    const clientId = server.clientId;
    if (parsed.protocol !== 'https:' && parsed.hostname !== '127.0.0.1' && parsed.hostname !== 'localhost') { throw new Error('光鸭授权代理必须使用 HTTPS'); }
    const body: GuangyaBrokerBody = { client_id: server.clientId };
    const response = await this.transport.request(address, 'POST', { 'Content-Type': 'application/json' }, JSON.stringify(body));
    const data = GuangyaAuthorization.parse(response);
    if (server.clientId !== clientId || server.authBrokerUrl !== broker) { throw new Error('来源授权代理或应用配置已改变，已忽略旧设备码'); }
    if (response.status !== 200 || typeof data.device_code !== 'string' || typeof data.user_code !== 'string' || !Number.isFinite(data.expires_in) || (data.expires_in as number) <= 0
      || !Number.isFinite(data.interval) || (data.interval as number) <= 0 || typeof data.project_id !== 'string' || typeof data.device_id !== 'string') { throw new Error('授权代理须返回官方设备码及 project_id、device_id 上下文'); }
    const verification = typeof data.verification_uri_complete === 'string' ? data.verification_uri_complete : data.verification_url;
    if (typeof verification !== 'string' || verification.length === 0) { throw new Error('授权代理未返回用户授权地址'); }
    const flow = new SourceAuthorization(); flow.provider = 'guangya'; flow.clientId = server.clientId; flow.deviceCode = data.device_code; flow.userCode = data.user_code;
    flow.deviceId = data.device_id; flow.projectId = data.project_id; flow.verificationUrl = DirectSourceHttp.resolve(verification, verification);
    flow.expiresAt = Date.now() + (data.expires_in as number) * 1000; flow.intervalSeconds = data.interval as number;
    flow.nextPollAt = Date.now() + flow.intervalSeconds * 1000; return flow;
  }
  async poll(server: ServerConfig, flow: SourceAuthorization): Promise<SourceAuthPoll> {
    const result = new SourceAuthPoll(); result.intervalSeconds = flow.intervalSeconds;
    if (flow.provider !== 'guangya' || flow.deviceCode.length === 0 || flow.projectId.length === 0 || flow.deviceId.length === 0 || flow.clientId !== server.clientId || server.clientId.length === 0) { throw new Error('光鸭授权会话或应用上下文无效'); }
    if (Date.now() >= flow.expiresAt) { result.state = 'expired'; result.message = '设备授权码已过期，请重新授权'; return result; }
    if (Date.now() < flow.nextPollAt) { result.intervalSeconds = Math.max(1, Math.ceil((flow.nextPollAt - Date.now()) / 1000)); result.message = '等待下一次授权查询'; return result; }
    flow.nextPollAt = Date.now() + flow.intervalSeconds * 1000;
    const snapshot = SourceAuthConfig.copy(server);
    const body: GuangyaTokenBody = { client_id: server.clientId, grant_type: 'urn:ietf:params:oauth:grant-type:device_code', device_code: flow.deviceCode };
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'x-client-id': server.clientId, 'x-device-id': flow.deviceId, 'x-project-id': flow.projectId };
    const response = await this.transport.request('https://openapi-account.guangyapan.com/v1/auth/token', 'POST', headers, JSON.stringify(body));
    if (server.id !== snapshot.id || server.clientId !== snapshot.clientId || server.credentialRef !== snapshot.credentialRef || server.token !== snapshot.token) { throw new Error('来源配置已改变，已忽略旧授权结果'); }
    if (response.text.trim() === 'authorization_pending') { result.message = '等待用户确认光鸭授权'; return result; }
    const data = GuangyaAuthorization.parse(response);
    if (data.error === 'slow_down') { flow.intervalSeconds += 5; flow.nextPollAt = Date.now() + flow.intervalSeconds * 1000; result.state = 'slow'; result.intervalSeconds = flow.intervalSeconds; return result; }
    if (data.error === 'expired_token') { result.state = 'expired'; result.message = '设备授权码已过期'; return result; }
    if (response.status !== 200 || data.error !== undefined) { result.state = 'denied'; result.message = '光鸭授权被拒绝或应用配置不可用'; return result; }
    const next = SourceAuthConfig.copy(server); SourceTokenRefresh.apply(next, GuangyaAuthorization.tokens(data)); result.state = 'authorized'; result.server = next;
    result.message = '已取得光鸭用户授权，尚需保存来源配置'; return result;
  }
  static refresh(server: ServerConfig): Promise<ServerConfig> {
    if (server.clientId.length === 0) { return Promise.reject(new Error('光鸭刷新需要应用 client_id')); }
    return SourceTokenRefresh.run(server, async (snapshot: ServerConfig): Promise<SourceOAuthTokens> => {
      if (snapshot.clientId.length === 0) { throw new Error('光鸭刷新需要应用 client_id'); }
      const body: GuangyaTokenBody = { client_id: snapshot.clientId, grant_type: 'refresh_token', refresh_token: snapshot.refreshToken };
      const response = await new DirectSourceHttp().request('https://openapi-account.guangyapan.com/v1/auth/token', 'POST',
        { 'Content-Type': 'application/json', 'x-client-id': snapshot.clientId }, JSON.stringify(body));
      const data = GuangyaAuthorization.parse(response); if (response.status !== 200 || data.error !== undefined) { throw new Error('光鸭令牌刷新失败，请重新授权'); }
      return GuangyaAuthorization.tokens(data);
    }, GuangyaAuthorization.onRotate, false);
  }
}
