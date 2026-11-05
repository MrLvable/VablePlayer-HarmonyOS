import { ServerConfig, PlaybackInfo } from '../Models';
import { MediaService, NativePlaybackSession } from './MediaService';
import { LocalCatalog } from './LocalCatalog';
import { LocalAccess } from './LocalAccess';
export class LocalAdapter implements MediaService {
  kind: string = 'local'; catalog: LocalCatalog = new LocalCatalog();
  login(server: ServerConfig, password: string): Promise<ServerConfig> { return this.catalog.login(server, password); }
  async getPlaybackInfo(server: ServerConfig, id: string, _source: string, _ticks: number): Promise<PlaybackInfo> {
    const result = await LocalAccess.openPlayable(this.catalog.root(server), this.catalog.path(id)); result.mediaSourceId = id; return result;
  }
  streamUrl(_server: ServerConfig, _id: string): string { throw new Error('本地播放需先打开已授权文件，并在播放器停止后释放文件描述符'); }
  streamHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  playHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  createNativePlayback(): NativePlaybackSession | null { return null; }
}
