import { ServerConfig, Library, MediaItem, ItemDetail, Person } from '../Models';
import { MediaCatalog } from './MediaCatalog';
import { CloudCatalogBase } from './CloudCatalogBase';
import { WebDavCatalog } from './WebDavCatalog';

/** Aggregate is an explicit, separately authenticated WebDAV route, never an automatic fallback. */
export class CloudModeCatalog implements MediaCatalog {
  direct: CloudCatalogBase;
  aggregate: WebDavCatalog = new WebDavCatalog();
  constructor(direct: CloudCatalogBase) { this.direct = direct; }
  private use(server: ServerConfig): MediaCatalog {
    if (server.connectionMode === 'aggregate') { return this.aggregate; }
    if (server.connectionMode !== 'direct') { throw new Error('不支持的云盘连接方式'); } return this.direct;
  }
  probePublic(_host: string, _port: number): Promise<string> { return Promise.reject(new Error('请填写完整云盘连接配置并验证')); }
  getViews(s: ServerConfig): Promise<Library[]> { return this.use(s).getViews(s); }
  getItems(s: ServerConfig, p: string, o: number, l: number, r: boolean): Promise<MediaItem[]> { return this.use(s).getItems(s, p, o, l, r); }
  getLatest(s: ServerConfig, p: string, l: number): Promise<MediaItem[]> { return this.use(s).getLatest(s, p, l); }
  getResume(s: ServerConfig, l: number): Promise<MediaItem[]> { return this.use(s).getResume(s, l); }
  getItemDetail(s: ServerConfig, id: string): Promise<ItemDetail> { return this.use(s).getItemDetail(s, id); }
  getSeasons(s: ServerConfig, id: string): Promise<MediaItem[]> { return this.use(s).getSeasons(s, id); }
  getEpisodes(s: ServerConfig, id: string, season: string): Promise<MediaItem[]> { return this.use(s).getEpisodes(s, id, season); }
  search(s: ServerConfig, q: string, l: number): Promise<MediaItem[]> { return this.use(s).search(s, q, l); }
  getFavorites(s: ServerConfig, l: number): Promise<MediaItem[]> { return this.use(s).getFavorites(s, l); }
  addFavorite(s: ServerConfig, id: string): Promise<void> { return this.use(s).addFavorite(s, id); }
  removeFavorite(s: ServerConfig, id: string): Promise<void> { return this.use(s).removeFavorite(s, id); }
  isFavorite(s: ServerConfig, id: string): Promise<boolean> { return this.use(s).isFavorite(s, id); }
  getPeople(s: ServerConfig, id: string): Promise<Person[]> { return this.use(s).getPeople(s, id); }
  personImageUrl(s: ServerConfig, id: string, w: number): string { return this.use(s).personImageUrl(s, id, w); }
  imageUrl(s: ServerConfig, id: string, w: number, t: string): string { return this.use(s).imageUrl(s, id, w, t); }
  backdropUrl(s: ServerConfig, id: string, w: number, b: string, p: string): string { return this.use(s).backdropUrl(s, id, w, b, p); }
  imageHeaders(s: ServerConfig): Record<string, string> { return this.use(s).imageHeaders(s); }
  subtitleUrl(s: ServerConfig, id: string, source: string, i: number, codec: string): string { return this.use(s).subtitleUrl(s, id, source, i, codec); }
  reportProgress(s: ServerConfig, id: string, ticks: number, played: boolean): Promise<void> { return this.use(s).reportProgress(s, id, ticks, played); }
}
