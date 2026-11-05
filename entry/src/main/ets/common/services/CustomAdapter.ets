import { ServerConfig, PlaybackInfo } from '../Models';
import { MediaService, NativePlaybackSession } from './MediaService';
import { CustomCatalog } from './CustomCatalog';
export class CustomAdapter implements MediaService {
  kind: string = 'custom'; catalog: CustomCatalog = new CustomCatalog();
  login(server: ServerConfig, password: string): Promise<ServerConfig> { return this.catalog.login(server, password); }
  getPlaybackInfo(server: ServerConfig, id: string, _source: string, _ticks: number): Promise<PlaybackInfo> { return this.catalog.playback(server, id); }
  streamUrl(_server: ServerConfig, _id: string): string { throw new Error('JSON 媒体库播放需先解析当前条目及其认证范围'); }
  streamHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  playHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  createNativePlayback(): NativePlaybackSession | null { return null; }
}
