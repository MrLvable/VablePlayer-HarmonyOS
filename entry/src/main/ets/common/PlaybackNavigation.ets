import { ServerConfig, MediaItem, MediaSource, SubtitleTrack } from './Models';
import { MediaServices } from './services/MediaServices';
import { ProgressRepository } from './ProgressRepository';
import { SourcePlaybackLeases } from './SourcePlaybackLeases';
import { SourcePlaybackPolicy } from './SourcePlaybackPolicy';

export class PlaybackTarget {
  server: ServerConfig;
  item: MediaItem;
  sources: MediaSource[] = [];
  sourceId: string = '';
  url: string = '';
  isHls: boolean = false;
  positionMs: number = 0;
  subtitles: SubtitleTrack[] = [];
  headers: Record<string, string> = {};
  leaseId: string = '';
  useMpv: boolean = false;
  isLive: boolean = false;
  constructor(server: ServerConfig, item: MediaItem) { this.server = server; this.item = item; }
}

/** Fresh provider negotiation; no player or visible selection is mutated here. */
export class PlaybackNavigation {
  static async resolve(server: ServerConfig, requested: MediaItem, sourceId: string,
    resumeMs: number, changingSource: boolean): Promise<PlaybackTarget> {
    const detail = await MediaServices.getItemDetail(server, requested.id);
    const item = detail.item;
    if (item.id.length === 0 || item.id !== requested.id) { throw new Error('服务器未返回所选影片的详情'); }
    if (item.seriesId.length === 0) { item.seriesId = requested.seriesId; }
    if (item.seriesName.length === 0) { item.seriesName = requested.seriesName; }
    if (item.type.length === 0) { item.type = requested.type; }
    if (item.indexNumber === 0) { item.indexNumber = requested.indexNumber; }
    if (item.parentIndexNumber === 0) { item.parentIndexNumber = requested.parentIndexNumber; }
    const target = new PlaybackTarget(server, item);
    target.sources = detail.sources;
    let source: MediaSource | null = null;
    if (sourceId.length > 0) {
      for (let i = 0; i < detail.sources.length; i++) {
        if (detail.sources[i].id === sourceId) { source = detail.sources[i]; break; }
      }
      if (source === null) { throw new Error('该视频源已不可用，请重新打开详情页'); }
    } else if (detail.sources.length > 0) { source = detail.sources[0]; }
    target.sourceId = source !== null ? source.id : '';
    target.isLive = item.type === 'Channel';
    if (target.isLive) { target.positionMs = 0; }
    else if (resumeMs >= 0) { target.positionMs = resumeMs; }
    else {
      target.positionMs = Math.max(0, Math.floor(item.progressTicks / 10000));
      const history = await ProgressRepository.loadForAccount(server.id, server.userId, 100);
      for (let i = 0; i < history.length; i++) {
        if (history[i].itemId === item.id) { target.positionMs = history[i].positionMs; break; }
      }
    }
    // The old compatibility adapter cannot map a different version to a native file.
    if ((server.kind === 'fnos' || server.kind === 'fnos-native') && changingSource) {
      throw new Error('当前飞牛接口未提供该版本的独立播放地址，已保留原视频源');
    }
    try {
      // Negotiate first: providers may open an fd, SMB bridge or native session.
      // Their synchronous streamUrl method deliberately cannot do that work.
      const playback = await MediaServices.getPlaybackInfo(server, item.id, target.sourceId,
        Math.floor(target.positionMs * 10000));
      target.leaseId = SourcePlaybackLeases.register(playback.release);
      if (playback.url.length === 0) { throw new Error('服务器未返回可播放的视频源'); }
      if (playback.mediaSourceId.length > 0 && target.sourceId.length > 0
        && playback.mediaSourceId !== target.sourceId) {
        throw new Error('服务器未接受所选视频源，已保留原视频源');
      }
      target.url = playback.url;
      target.isHls = playback.isHls;
      target.isLive = playback.isLive;
      if (target.isLive) { target.positionMs = 0; }
      target.headers = SourcePlaybackPolicy.headers(server.kind,
        playback.headers !== null ? playback.headers : MediaServices.streamHeaders(server), '');
      // Standard direct-file fallback must still identify the selected version.
      if ((server.kind === 'emby' || server.kind === 'jellyfin') && target.sourceId.length > 0
        && target.url === MediaServices.directStreamUrl(server, item.id)
        && !/[?&]MediaSourceId=/i.test(target.url)) {
        target.url += (target.url.indexOf('?') >= 0 ? '&' : '?') + 'MediaSourceId=' + encodeURIComponent(target.sourceId);
      }
      target.useMpv = SourcePlaybackPolicy.useMpv(server.kind, target.url);
      if (source !== null) {
        const streams = source.subtitleStreams();
        for (let i = 0; i < streams.length; i++) {
          const track = streams[i];
          if (!track.isExternal) { continue; }
          target.subtitles.push({ index: track.index, language: track.language, title: track.title,
            isExternal: true, url: MediaServices.subtitleUrl(server, item.id, source.id, track.index, track.codec) });
        }
      }
      return target;
    } catch (error) {
      await SourcePlaybackLeases.release(target.leaseId).catch(() => {});
      throw (error as Error);
    }
  }
}
