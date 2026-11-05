import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServerConfig, PlaybackInfo } from '../Models';
import { EmbyClient } from '../EmbyClient';
import { FnosPlayback } from '../FnosPlayback';
import { EmbyCatalog } from './EmbyCatalog';
import { MediaService, NativePlaybackSession } from './MediaService';
import { SourceConfig } from './SourceConfig';

/** FnOS catalog intentionally remains an Emby compatibility bridge for this increment. */
class FnosCompatCatalog extends EmbyCatalog {
  backdropUrl(server: ServerConfig, itemId: string, maxWidth: number, backdropTag: string, primaryTag: string): string {
    const type = backdropTag.length > 0 ? 'Backdrop' : 'Primary';
    const tag = backdropTag.length > 0 ? backdropTag : primaryTag;
    if (tag.length === 0) { return ''; }
    return server.baseUrl() + '/Items/' + itemId + '/Images/' + type
      + '?maxWidth=' + maxWidth.toString() + '&quality=85&tag=' + encodeURIComponent(tag)
      + '&X-Emby-Token=' + encodeURIComponent(server.token);
  }
}

export class FnosAdapter implements MediaService {
  kind: string = 'fnos';
  catalog: EmbyCatalog = new FnosCompatCatalog();
  async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    const logged = SourceConfig.preserve(server, await EmbyClient.login(server, password));
    try {
      logged.nativeToken = await FnosPlayback.login(logged.baseUrl(), logged.username, password);
    } catch (e) {
      // Preserve the existing catalog-only login outcome; UI can report missing native capability.
      hilog.warn(0x0001, 'NasPlay', 'FnOS native playback login unavailable');
    }
    return logged;
  }
  async getPlaybackInfo(server: ServerConfig, itemId: string, mediaSourceId: string, startTicks: number): Promise<PlaybackInfo> {
    const info = new PlaybackInfo();
    info.url = this.streamUrl(server, itemId);
    info.mediaSourceId = mediaSourceId;
    return info;
  }
  streamUrl(server: ServerConfig, itemId: string): string {
    return server.baseUrl() + '/v/api/v1/media/range/' + encodeURIComponent(itemId);
  }
  streamHeaders(server: ServerConfig): Record<string, string> {
    return { 'Authorization': server.token, 'X-Emby-Token': server.token };
  }
  playHeaders(server: ServerConfig): Record<string, string> { return this.streamHeaders(server); }
  createNativePlayback(): NativePlaybackSession | null { return new FnosPlayback(); }
}
