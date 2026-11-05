import { ServerConfig, PlaybackInfo } from '../Models';
import { MediaService, NativePlaybackSession } from './MediaService';
import { SmbCatalog } from './SmbCatalog';
import { SmbNative } from './SmbNative';
import { SmbRangeBridge } from './SmbRangeBridge';

export class SmbAdapter implements MediaService {
  kind: string = 'smb';
  catalog: SmbCatalog = new SmbCatalog();
  login(server: ServerConfig, password: string): Promise<ServerConfig> { return this.catalog.login(server, password); }
  async getPlaybackInfo(server: ServerConfig, id: string, _source: string, _ticks: number): Promise<PlaybackInfo> {
    const path = SmbNative.fromId(server, id);
    const bridge = new SmbRangeBridge();
    const result = new PlaybackInfo();
    result.url = await bridge.start(server, path); result.headers = {}; result.mediaSourceId = id;
    result.release = (): Promise<void> => bridge.close();
    return result;
  }
  streamUrl(_server: ServerConfig, _id: string): string { throw new Error('SMB 播放必须先建立有生命周期的分块读取连接'); }
  streamHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  playHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  createNativePlayback(): NativePlaybackSession | null { return null; }
}
