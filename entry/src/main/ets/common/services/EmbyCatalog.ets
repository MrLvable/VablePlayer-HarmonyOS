import { ServerConfig, Library, MediaItem, ItemDetail, Person, PlaybackInfo } from '../Models';
import { EmbyClient } from '../EmbyClient';
import { MediaCatalog } from './MediaCatalog';

/** Shared Emby-compatible catalog transport; not a native FnOS catalog implementation. */
export class EmbyCatalog implements MediaCatalog {
  probePublic(host: string, port: number): Promise<string> {
    return EmbyClient.probePublic(host, port);
  }
  getViews(server: ServerConfig): Promise<Library[]> {
    return EmbyClient.getViews(server);
  }
  getItems(server: ServerConfig, parentId: string, start: number,
                        limit: number, recursive: boolean): Promise<MediaItem[]> {
    return EmbyClient.getItems(server, parentId, start, limit, recursive);
  }
  getLatest(server: ServerConfig, parentId: string, limit: number): Promise<MediaItem[]> {
    return EmbyClient.getLatest(server, parentId, limit);
  }
  getResume(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    return EmbyClient.getResume(server, limit);
  }
  getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    return EmbyClient.getItemDetail(server, id);
  }
  getSeasons(server: ServerConfig, seriesId: string): Promise<MediaItem[]> {
    return EmbyClient.getSeasons(server, seriesId);
  }
  getEpisodes(server: ServerConfig, seriesId: string,
                           seasonId: string): Promise<MediaItem[]> {
    return EmbyClient.getEpisodes(server, seriesId, seasonId);
  }
  search(server: ServerConfig, q: string, limit: number): Promise<MediaItem[]> {
    return EmbyClient.search(server, q, limit);
  }
  getFavorites(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    return EmbyClient.getFavorites(server, limit);
  }
  addFavorite(server: ServerConfig, itemId: string): Promise<void> {
    return EmbyClient.addFavorite(server, itemId);
  }
  removeFavorite(server: ServerConfig, itemId: string): Promise<void> {
    return EmbyClient.removeFavorite(server, itemId);
  }
  isFavorite(server: ServerConfig, itemId: string): Promise<boolean> {
    return EmbyClient.isFavorite(server, itemId);
  }
  getPeople(server: ServerConfig, itemId: string): Promise<Person[]> {
    return EmbyClient.getPeople(server, itemId);
  }
  personImageUrl(server: ServerConfig, personId: string, w: number): string {
    return EmbyClient.personImageUrl(server, personId, w);
  }
  imageUrl(server: ServerConfig, itemId: string, maxWidth: number, tag: string): string {
    return EmbyClient.imageUrl(server, itemId, maxWidth, tag);
  }
  backdropUrl(server: ServerConfig, itemId: string, maxWidth: number,
                     backdropTag: string, primaryTag: string): string {
    return EmbyClient.backdropUrl(server, itemId, maxWidth, backdropTag, primaryTag);
  }
  imageHeaders(server: ServerConfig): Record<string, string> {
    return EmbyClient.imageHeaders(server);
  }
  subtitleUrl(server: ServerConfig, itemId: string, mediaSourceId: string,
                     index: number, codec: string): string {
    return EmbyClient.subtitleUrl(server, itemId, mediaSourceId, index, codec);
  }
  reportProgress(server: ServerConfig, itemId: string,
                              positionTicks: number, played: boolean): Promise<void> {
    return EmbyClient.reportProgress(server, itemId, positionTicks, played);
  }
}
