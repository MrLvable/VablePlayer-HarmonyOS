import { ServerConfig } from '../Models';
import { DirectSourceHttp, SourceResponse } from './DirectSourceHttp';
import { SourceAuthorization, SourceAuthPoll, SourceAuthConfig, SourceTokenRotation } from './SourceAuthorization';
import { SourceOAuthTokens, SourceTokenRefresh } from './SourceTokenRefresh';
import { SourceJson } from './SourceJson';

interface BaiduOAuthReply {
  device_code?: string; user_code?: string; verification_url?: string; expires_in?: number; interval?: number;
  access_token?: string; refresh_token?: string; error?: string; sub?: string; user_id?: string | number;
}

export class BaiduAuthorization {
  static onRotate: SourceTokenRotation | null = null;
  private transport: DirectSourceHttp = new DirectSourceHttp();
  cancel(): void { this.transport.cancel(); }
  private static parse(response: SourceResponse): BaiduOAuthReply {
    try { return JSON.parse(SourceJson.preserveIntegers(response.text)) as BaiduOAuthReply; }
    catch (e) { throw new Error('百度授权响应格式无效'); }
  }
  private static tokens(reply: BaiduOAuthReply): SourceOAuthTokens {
    if (typeof reply.access_token !== 'string' || reply.access_token.length === 0 || !Number.isFinite(reply.expires_in) || (reply.expires_in as number) <= 0) { throw new Error('百度授权没有返回有效令牌'); }
    const result = new SourceOAuthTokens(); result.accessToken = reply.access_token;
    result.refreshToken = typeof reply.refresh_token === 'string' ? reply.refresh_token : '';
    result.userId = typeof reply.sub === 'string' ? reply.sub : reply.user_id !== undefined ? SourceJson.id(reply.user_id) : '';
    result.expiresAt = Date.now() + (reply.expires_in as number) * 1000; return result;
  }
  async beginDevice(server: ServerConfig): Promise<SourceAuthorization> {
    if (server.clientId.length === 0) { throw new Error('请填写您已注册的百度应用 AppKey'); }
    const clientId = server.clientId;
    const response = await this.transport.request('https://openapi.baidu.com/oauth/2.0/device/code?response_type=device_code&client_id=' + encodeURIComponent(server.clientId) + '&scope=basic%2Cnetdisk', 'GET', {});
    const data = BaiduAuthorization.parse(response);
    if (server.clientId !== clientId) { throw new Error('来源应用配置已改变，已忽略旧设备码'); }
    if (response.status !== 200 || typeof data.device_code !== 'string' || typeof data.user_code !== 'string' || typeof data.verification_url !== 'string'
      || !Number.isFinite(data.expires_in) || (data.expires_in as number) <= 0 || !Number.isFinite(data.interval) || (data.interval as number) <= 0) { throw new Error('无法取得百度设备授权码，请核对应用权限'); }
    const flow = new SourceAuthorization(); flow.provider = 'baidu'; flow.clientId = server.clientId; flow.deviceCode = data.device_code; flow.userCode = data.user_code;
    flow.verificationUrl = DirectSourceHttp.resolve(data.verification_url, data.verification_url); flow.expiresAt = Date.now() + (data.expires_in as number) * 1000;
    flow.intervalSeconds = Math.max(5, data.interval as number); flow.nextPollAt = Date.now() + flow.intervalSeconds * 1000; return flow;
  }
  async poll(server: ServerConfig, flow: SourceAuthorization): Promise<SourceAuthPoll> {
    const result = new SourceAuthPoll(); result.intervalSeconds = flow.intervalSeconds;
    if (flow.provider !== 'baidu' || flow.deviceCode.length === 0 || flow.clientId !== server.clientId) { throw new Error('百度授权会话无效或应用配置已改变'); }
    if (Date.now() >= flow.expiresAt) { result.state = 'expired'; result.message = '设备授权码已过期，请重新发起授权'; return result; }
    if (Date.now() < flow.nextPollAt) { result.message = '等待下一次授权查询'; result.intervalSeconds = Math.max(1, Math.ceil((flow.nextPollAt - Date.now()) / 1000)); return result; }
    if (server.clientId.length === 0 || server.clientSecret.length === 0) { throw new Error('百度设备授权需要您自己的 AppKey 与 SecretKey；请先配置并安全保存'); }
    flow.nextPollAt = Date.now() + flow.intervalSeconds * 1000;
    const snapshot = SourceAuthConfig.copy(server);
    const response = await this.transport.request('https://openapi.baidu.com/oauth/2.0/token?grant_type=device_token&code=' + encodeURIComponent(flow.deviceCode)
      + '&client_id=' + encodeURIComponent(server.clientId) + '&client_secret=' + encodeURIComponent(server.clientSecret), 'GET', {});
    const data = BaiduAuthorization.parse(response);
    if (server.id !== snapshot.id || server.clientId !== snapshot.clientId || server.credentialRef !== snapshot.credentialRef || server.token !== snapshot.token) { throw new Error('来源配置已改变，已忽略旧授权结果'); }
    if (data.error === 'authorization_pending') { result.message = '等待用户确认百度授权'; return result; }
    if (data.error === 'slow_down') { flow.intervalSeconds += 5; flow.nextPollAt = Date.now() + flow.intervalSeconds * 1000; result.state = 'slow'; result.intervalSeconds = flow.intervalSeconds; result.message = '平台要求降低查询频率'; return result; }
    if (data.error === 'expired_token') { result.state = 'expired'; result.message = '设备授权码已过期'; return result; }
    if (response.status !== 200 || data.error !== undefined) { result.state = 'denied'; result.message = '百度授权被拒绝或应用配置不可用，请重新授权'; return result; }
    const next = SourceAuthConfig.copy(server); SourceTokenRefresh.apply(next, BaiduAuthorization.tokens(data));
    result.state = 'authorized'; result.server = next; result.message = '已取得百度用户授权，尚需保存来源配置'; return result;
  }
  static refresh(server: ServerConfig): Promise<ServerConfig> {
    if (server.clientId.length === 0 || server.clientSecret.length === 0) { return Promise.reject(new Error('百度刷新需要 AppKey 与 SecretKey')); }
    return SourceTokenRefresh.run(server, async (snapshot: ServerConfig): Promise<SourceOAuthTokens> => {
      if (snapshot.clientId.length === 0 || snapshot.clientSecret.length === 0) { throw new Error('百度刷新需要 AppKey 与 SecretKey'); }
      const response = await new DirectSourceHttp().request('https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=' + encodeURIComponent(snapshot.refreshToken)
        + '&client_id=' + encodeURIComponent(snapshot.clientId) + '&client_secret=' + encodeURIComponent(snapshot.clientSecret), 'GET', {});
      const data = BaiduAuthorization.parse(response);
      if (response.status !== 200 || data.error !== undefined) { throw new Error('百度刷新失败，需要重新授权'); }
      const tokens = BaiduAuthorization.tokens(data); if (tokens.refreshToken.length === 0 || tokens.refreshToken === snapshot.refreshToken) { throw new Error('百度轮转响应缺少新的 refresh_token，请重新授权'); } return tokens;
    }, BaiduAuthorization.onRotate);
  }
}
