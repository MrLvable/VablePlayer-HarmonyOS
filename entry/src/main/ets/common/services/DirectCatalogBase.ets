import { ServerConfig, Library, MediaItem, ItemDetail, Person } from '../Models';
import { MediaCatalog } from './MediaCatalog';
import { LocalSourceState } from './LocalSourceState';
import { SourceIdentity } from './SourceIdentity';

/** Explicit unsupported features plus local state; never calls an Emby endpoint. */
export class DirectCatalogBase implements MediaCatalog {
  private static snapshots: Map<string, MediaItem> = new Map();
  protected unsupported(feature: string): Error { return new Error('当前来源不提供' + feature); }
  private key(server: ServerConfig, id: string): string {
    return SourceIdentity.scope(server) + '|' + id;
  }
  protected remember(server: ServerConfig, items: MediaItem[]): MediaItem[] {
    items.forEach((item: MediaItem) => {
      const key = this.key(server, item.id); DirectCatalogBase.snapshots.delete(key); DirectCatalogBase.snapshots.set(key, item);
      if (DirectCatalogBase.snapshots.size > 5000) {
        let first = ''; DirectCatalogBase.snapshots.forEach((_entry: MediaItem, id: string) => { if (first.length === 0) { first = id; } });
        DirectCatalogBase.snapshots.delete(first);
      }
    });
    return items;
  }
  probePublic(_host: string, _port: number): Promise<string> { return Promise.reject(this.unsupported('无认证探测，请验证完整连接配置')); }
  getViews(_server: ServerConfig): Promise<Library[]> { return Promise.reject(this.unsupported('媒体库')); }
  getItems(_server: ServerConfig, _parent: string, _start: number, _limit: number, _recursive: boolean): Promise<MediaItem[]> { return Promise.reject(this.unsupported('目录')); }
  getLatest(server: ServerConfig, parent: string, limit: number): Promise<MediaItem[]> { return this.getItems(server, parent, 0, limit, true); }
  getResume(server: ServerConfig, limit: number): Promise<MediaItem[]> { return LocalSourceState.getResume(server, limit); }
  getItemDetail(_server: ServerConfig, _id: string): Promise<ItemDetail> { return Promise.reject(this.unsupported('详细信息')); }
  getSeasons(_server: ServerConfig, _series: string): Promise<MediaItem[]> { return Promise.reject(this.unsupported('剧集季信息')); }
  getEpisodes(_server: ServerConfig, _series: string, _season: string): Promise<MediaItem[]> { return Promise.reject(this.unsupported('剧集元数据')); }
  search(_server: ServerConfig, _q: string, _limit: number): Promise<MediaItem[]> { return Promise.reject(this.unsupported('搜索')); }
  getFavorites(server: ServerConfig, limit: number): Promise<MediaItem[]> { return LocalSourceState.getFavorites(server, limit); }
  async addFavorite(server: ServerConfig, id: string): Promise<void> {
    let item = DirectCatalogBase.snapshots.get(this.key(server, id));
    if (item === undefined) { item = (await this.getItemDetail(server, id)).item; }
    await LocalSourceState.addFavorite(server, id, item);
  }
  removeFavorite(server: ServerConfig, id: string): Promise<void> { return LocalSourceState.removeFavorite(server, id); }
  isFavorite(server: ServerConfig, id: string): Promise<boolean> { return LocalSourceState.isFavorite(server, id); }
  getPeople(_server: ServerConfig, _id: string): Promise<Person[]> { return Promise.reject(this.unsupported('演职员信息')); }
  personImageUrl(_server: ServerConfig, _id: string, _width: number): string { return ''; }
  imageUrl(_server: ServerConfig, _id: string, _width: number, _tag: string): string { return ''; }
  backdropUrl(_server: ServerConfig, _id: string, _width: number, _backdrop: string, _primary: string): string { return ''; }
  imageHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  subtitleUrl(_server: ServerConfig, _id: string, _source: string, _index: number, _codec: string): string { throw this.unsupported('字幕下载'); }
  reportProgress(server: ServerConfig, id: string, ticks: number, played: boolean): Promise<void> {
    return LocalSourceState.reportProgress(server, id, ticks, played, DirectCatalogBase.snapshots.get(this.key(server, id)));
  }
}
