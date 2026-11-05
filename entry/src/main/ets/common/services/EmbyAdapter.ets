import { ServerConfig, PlaybackInfo } from '../Models';
import { EmbyClient } from '../EmbyClient';
import { EmbyCatalog } from './EmbyCatalog';
import { MediaService, NativePlaybackSession } from './MediaService';

export class EmbyAdapter implements MediaService {
  kind: string = 'emby';
  catalog: EmbyCatalog = new EmbyCatalog();
  login(server: ServerConfig, password: string): Promise<ServerConfig> { return EmbyClient.login(server, password); }
  getPlaybackInfo(server: ServerConfig, itemId: string, mediaSourceId: string, startTicks: number): Promise<PlaybackInfo> {
    return EmbyClient.getPlaybackInfo(server, itemId, mediaSourceId, startTicks);
  }
  streamUrl(server: ServerConfig, itemId: string): string { return EmbyClient.streamUrl(server, itemId); }
  streamHeaders(server: ServerConfig): Record<string, string> { return EmbyClient.playHeaders(server); }
  playHeaders(server: ServerConfig): Record<string, string> { return EmbyClient.playHeaders(server); }
  createNativePlayback(): NativePlaybackSession | null { return null; }
}
