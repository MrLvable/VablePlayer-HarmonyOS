import { ServerConfig, PlaybackInfo } from '../Models';
import { FnosAdapter } from './FnosAdapter';
import { FnosPlayback } from '../FnosPlayback';

/** Compatibility catalog with an explicitly negotiated native FnOS playback session. */
export class FnosNativeAdapter extends FnosAdapter {
  kind: string = 'fnos-native';
  async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    const logged = await super.login(server, password);
    if (logged.nativeToken.length === 0) { throw new Error('原生播放需要飞牛原生会话，请使用账号密码登录，或选择飞牛影视兼容模式'); }
    return logged;
  }
  async getPlaybackInfo(server: ServerConfig, itemId: string, mediaSourceId: string, _start: number): Promise<PlaybackInfo> {
    if (server.nativeToken.length === 0) { throw new Error('缺少飞牛原生播放凭据，请重新登录'); }
    const session = new FnosPlayback();
    try {
      const result = await session.resolve(this.streamUrl(server, itemId), server.nativeToken, itemId);
      const info = new PlaybackInfo(); info.url = result.url; info.isHls = result.isHls;
      info.mediaSourceId = mediaSourceId; info.headers = {}; info.release = (): Promise<void> => session.close();
      return info;
    } catch (e) { await session.close(); throw (e as Error); }
  }
}
