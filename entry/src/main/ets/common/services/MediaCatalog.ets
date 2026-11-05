import { ServerConfig, Library, MediaItem, ItemDetail, Person } from '../Models';

/** Protocol-neutral catalog contract. A provider must never inherit unrelated HTTP routes. */
export interface MediaCatalog {
  probePublic(host: string, port: number): Promise<string>;
  getViews(server: ServerConfig): Promise<Library[]>;
  getItems(server: ServerConfig, parentId: string, start: number, limit: number,
    recursive: boolean): Promise<MediaItem[]>;
  getLatest(server: ServerConfig, parentId: string, limit: number): Promise<MediaItem[]>;
  getResume(server: ServerConfig, limit: number): Promise<MediaItem[]>;
  getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail>;
  getSeasons(server: ServerConfig, seriesId: string): Promise<MediaItem[]>;
  getEpisodes(server: ServerConfig, seriesId: string, seasonId: string): Promise<MediaItem[]>;
  search(server: ServerConfig, q: string, limit: number): Promise<MediaItem[]>;
  getFavorites(server: ServerConfig, limit: number): Promise<MediaItem[]>;
  addFavorite(server: ServerConfig, itemId: string): Promise<void>;
  removeFavorite(server: ServerConfig, itemId: string): Promise<void>;
  isFavorite(server: ServerConfig, itemId: string): Promise<boolean>;
  getPeople(server: ServerConfig, itemId: string): Promise<Person[]>;
  personImageUrl(server: ServerConfig, personId: string, w: number): string;
  imageUrl(server: ServerConfig, itemId: string, maxWidth: number, tag: string): string;
  backdropUrl(server: ServerConfig, itemId: string, maxWidth: number, backdropTag: string,
    primaryTag: string): string;
  imageHeaders(server: ServerConfig): Record<string, string>;
  subtitleUrl(server: ServerConfig, itemId: string, mediaSourceId: string, index: number,
    codec: string): string;
  reportProgress(server: ServerConfig, itemId: string, positionTicks: number, played: boolean): Promise<void>;
}
