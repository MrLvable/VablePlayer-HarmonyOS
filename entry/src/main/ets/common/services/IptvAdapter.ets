import { ServerConfig, PlaybackInfo } from '../Models';
import { MediaService, NativePlaybackSession } from './MediaService';
import { IptvCatalog } from './IptvCatalog';

export class IptvAdapter implements MediaService {
  kind: string = 'iptv';
  catalog: IptvCatalog = new IptvCatalog();
  login(server: ServerConfig, password: string): Promise<ServerConfig> { return this.catalog.login(server, password); }
  getPlaybackInfo(server: ServerConfig, id: string, source: string, _ticks: number): Promise<PlaybackInfo> { return this.catalog.playback(server, id, source); }
  streamUrl(server: ServerConfig, id: string): string { return this.catalog.stream(server, id); }
  streamHeaders(server: ServerConfig): Record<string, string> { return this.catalog.headers(server); }
  playHeaders(server: ServerConfig): Record<string, string> { return this.streamHeaders(server); }
  createNativePlayback(): NativePlaybackSession | null { return null; }
}
