import { ServerConfig, Library, MediaItem, ItemDetail, Person, PlaybackInfo } from '../Models';
import { EmbyClient } from '../EmbyClient';
import { MediaServiceRegistry } from './MediaServiceRegistry';
import { NativePlaybackSession } from './MediaService';
import { SourceConfig } from './SourceConfig';
import { SourceIdentity } from './SourceIdentity';
import { BaiduAuthorization } from './BaiduAuthorization';
import { GuangyaAuthorization } from './GuangyaAuthorization';
import { SourceAuthorization, SourceAuthPoll } from './SourceAuthorization';
import { PlexCatalog } from './PlexCatalog';
import { Store } from '../Store';

/** Provider-dispatched facade. UI metadata method signatures remain compatible. */
export class MediaServices {
  static probePublic(host: string, port: number, kind: string = 'fnos'): Promise<string> {
    return MediaServiceRegistry.forKind(kind).catalog.probePublic(host, port);
  }
  static configureCredentials(): void {
    const rotate = async (next: ServerConfig, expected: string): Promise<void> => {
      if (expected.length === 0) { return; } // Unsaved form stays in memory until its explicit save.
      if (!await Store.refreshServerCredentials(next, expected)) { throw new Error('来源配置已改变，已忽略旧授权更新'); }
    };
    BaiduAuthorization.onRotate = rotate; GuangyaAuthorization.onRotate = rotate;
  }
  static async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    const service = MediaServiceRegistry.forServer(server);
    if (server.connectionMode === 'direct' && server.token.length === 0 && server.refreshToken.length > 0) {
      if (server.kind === 'baidu') { await BaiduAuthorization.refresh(server); }
      else if (server.kind === 'guangya') { await GuangyaAuthorization.refresh(server); }
    }
    const legacy = ['fnos', 'fnos-native', 'emby', 'jellyfin'].indexOf(server.kind) >= 0;
    if (legacy && server.token.length > 0 && (server.authMode === 'token' || password.length === 0)) {
      if (server.authMode === 'token') { await EmbyClient.verifyTokenUser(server); }
      await service.catalog.getViews(server);
      if (server.kind === 'fnos-native' && server.nativeToken.length === 0) {
        throw new Error('原生播放需要飞牛原生会话，请使用账号密码重新登录');
      }
      return server;
    }
    const logged = await service.login(server, password);
    if (legacy) { SourceConfig.preserve(server, logged); }
    else { SourceIdentity.ensureLocalAccount(logged); }
    // A successful password exchange alone does not prove this account can read
    // its libraries. Preserve HTTPS/basePath before testing the new session.
    if (server.kind === 'jellyfin') { await service.catalog.getViews(logged); }
    return logged;
  }
  static beginAuthorization(server: ServerConfig): Promise<SourceAuthorization> {
    if (server.kind === 'baidu' && server.connectionMode === 'direct') { return new BaiduAuthorization().beginDevice(server); }
    if (server.kind === 'guangya' && server.connectionMode === 'direct') { return new GuangyaAuthorization().authorize(server); }
    return Promise.reject(new Error('此来源不支持设备授权，请使用页面中的认证方式'));
  }
  static pollAuthorization(server: ServerConfig, flow: SourceAuthorization): Promise<SourceAuthPoll> {
    if (server.connectionMode === 'direct' && server.kind === 'baidu' && flow.provider === server.kind) { return new BaiduAuthorization().poll(server, flow); }
    if (server.connectionMode === 'direct' && server.kind === 'guangya' && flow.provider === server.kind) { return new GuangyaAuthorization().poll(server, flow); }
    return Promise.reject(new Error('授权来源已改变，请重新发起授权'));
  }
  static getViews(server: ServerConfig): Promise<Library[]> {
    return MediaServiceRegistry.forServer(server).catalog.getViews(server);
  }
  static getItems(server: ServerConfig, parentId: string, start: number,
                        limit: number, recursive: boolean): Promise<MediaItem[]> {
    return MediaServiceRegistry.forServer(server).catalog.getItems(server, parentId, start, limit, recursive);
  }
  static getLatest(server: ServerConfig, parentId: string, limit: number): Promise<MediaItem[]> {
    return MediaServiceRegistry.forServer(server).catalog.getLatest(server, parentId, limit);
  }
  static getResume(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    return MediaServiceRegistry.forServer(server).catalog.getResume(server, limit);
  }
  static getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    return MediaServiceRegistry.forServer(server).catalog.getItemDetail(server, id);
  }
  static getSeasons(server: ServerConfig, seriesId: string): Promise<MediaItem[]> {
    return MediaServiceRegistry.forServer(server).catalog.getSeasons(server, seriesId);
  }
  static getEpisodes(server: ServerConfig, seriesId: string,
                           seasonId: string): Promise<MediaItem[]> {
    return MediaServiceRegistry.forServer(server).catalog.getEpisodes(server, seriesId, seasonId);
  }
  static search(server: ServerConfig, q: string, limit: number): Promise<MediaItem[]> {
    return MediaServiceRegistry.forServer(server).catalog.search(server, q, limit);
  }
  static getFavorites(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    return MediaServiceRegistry.forServer(server).catalog.getFavorites(server, limit);
  }
  static addFavorite(server: ServerConfig, itemId: string): Promise<void> {
    return MediaServiceRegistry.forServer(server).catalog.addFavorite(server, itemId);
  }
  static removeFavorite(server: ServerConfig, itemId: string): Promise<void> {
    return MediaServiceRegistry.forServer(server).catalog.removeFavorite(server, itemId);
  }
  static isFavorite(server: ServerConfig, itemId: string): Promise<boolean> {
    return MediaServiceRegistry.forServer(server).catalog.isFavorite(server, itemId);
  }
  static getPeople(server: ServerConfig, itemId: string): Promise<Person[]> {
    return MediaServiceRegistry.forServer(server).catalog.getPeople(server, itemId);
  }
  static personImageUrl(server: ServerConfig, personId: string, w: number): string {
    return MediaServiceRegistry.forServer(server).catalog.personImageUrl(server, personId, w);
  }
  static getPlaybackInfo(server: ServerConfig, itemId: string,
                               mediaSourceId: string, startTicks: number): Promise<PlaybackInfo> {
    return MediaServiceRegistry.forServer(server).getPlaybackInfo(server, itemId, mediaSourceId, startTicks);
  }
  static streamUrl(server: ServerConfig, itemId: string): string {
    return MediaServiceRegistry.forServer(server).streamUrl(server, itemId);
  }
  static directStreamUrl(server: ServerConfig, itemId: string): string {
    return MediaServiceRegistry.forServer(server).streamUrl(server, itemId);
  }
  static streamHeaders(server: ServerConfig): Record<string, string> {
    return MediaServiceRegistry.forServer(server).streamHeaders(server);
  }
  static playHeaders(server: ServerConfig): Record<string, string> {
    return MediaServiceRegistry.forServer(server).playHeaders(server);
  }
  static imageUrl(server: ServerConfig, itemId: string, maxWidth: number, tag: string): string {
    return MediaServiceRegistry.forServer(server).catalog.imageUrl(server, itemId, maxWidth, tag);
  }
  static backdropUrl(server: ServerConfig, itemId: string, maxWidth: number,
                     backdropTag: string, primaryTag: string): string {
    return MediaServiceRegistry.forServer(server).catalog.backdropUrl(server, itemId, maxWidth, backdropTag, primaryTag);
  }
  static imageHeaders(server: ServerConfig): Record<string, string> {
    return MediaServiceRegistry.forServer(server).catalog.imageHeaders(server);
  }
  static subtitleUrl(server: ServerConfig, itemId: string, mediaSourceId: string,
                     index: number, codec: string): string {
    return MediaServiceRegistry.forServer(server).catalog.subtitleUrl(server, itemId, mediaSourceId, index, codec);
  }
  static reportProgress(server: ServerConfig, itemId: string,
                              positionTicks: number, played: boolean): Promise<void> {
    return MediaServiceRegistry.forServer(server).catalog.reportProgress(server, itemId, positionTicks, played);
  }
  static reportPlaybackState(server: ServerConfig, itemId: string, ticks: number,
                             durationTicks: number, state: string): Promise<void> {
    const service = MediaServiceRegistry.forServer(server);
    if (service.kind === 'plex') { return (service.catalog as PlexCatalog).reportTimeline(server, itemId, ticks, durationTicks, state); }
    return Promise.resolve();
  }
  static filterListItems(list: MediaItem[]): MediaItem[] {
    return EmbyClient.filterListItems(list);
  }
  static createNativePlayback(kind: string): NativePlaybackSession | null {
    return MediaServiceRegistry.forKind(kind).createNativePlayback();
  }
  static requireKind(kind: string): void { MediaServiceRegistry.forKind(kind); }
}
