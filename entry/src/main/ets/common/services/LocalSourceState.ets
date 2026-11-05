import { MediaItem, ServerConfig } from '../Models';
import { Store } from '../Store';
import { SourceIdentity } from './SourceIdentity';

interface LocalEntry {
  item: MediaItem;
  favorite: boolean;
  updatedAt: number;
}
interface LocalDocument { version: number; entries: LocalEntry[]; }

/** Local-only favorites/history for protocols without those remote APIs. No fake remote writes. */
export class LocalSourceState {
  private static chain: Promise<void> = Promise.resolve();
  private static readonly LIMIT: number = 256;

  private static key(server: ServerConfig): string { return 'local_source_state_v1.' + SourceIdentity.scope(server); }

  private static cleanImage(value: string): string {
    if (typeof value !== 'string' || value.length > 4096) { return ''; }
    // Resolve signed image/stream URLs from the provider again rather than retaining credentials in metadata.
    return /^https?:\/\//i.test(value) && /[?@]/.test(value.substring(value.indexOf('://') + 3)) ? '' : value;
  }

  private static snapshot(value: MediaItem): MediaItem {
    if (value === null || typeof value !== 'object' || typeof value.id !== 'string'
      || value.id.length === 0 || value.id.length > 4096 || /^https?:\/\//i.test(value.id)) {
      throw new Error('来源标识无效，请重新读取文件或频道');
    }
    const types = ['Folder', 'CollectionFolder', 'BoxSet', 'Series', 'Season', 'Episode', 'Movie', 'Video',
      'MusicVideo', 'Channel', 'TvChannel', 'LiveTvChannel', 'Program', 'TvProgram', 'LiveTvProgram',
      'Audio', 'MusicAlbum', 'MusicArtist', 'Playlist', 'Photo', 'PhotoAlbum', 'Book'];
    if (typeof value.name !== 'string' || value.name.trim().length === 0 || value.name.indexOf('\x00') >= 0
      || typeof value.type !== 'string' || types.indexOf(value.type) < 0) {
      throw new Error('来源条目名称或类型无效，请重新读取文件或频道');
    }
    const item = new MediaItem();
    item.id = value.id;
    item.name = value.name.substring(0, 512);
    item.type = value.type;
    item.year = Number.isInteger(value.year) ? value.year : 0;
    item.overview = typeof value.overview === 'string' ? value.overview.substring(0, 2048) : '';
    item.rating = Number.isFinite(value.rating) ? value.rating : 0;
    item.runtimeTicks = Number.isSafeInteger(value.runtimeTicks) && value.runtimeTicks > 0 ? value.runtimeTicks : 0;
    item.progressTicks = Number.isSafeInteger(value.progressTicks) && value.progressTicks > 0 ? value.progressTicks : 0;
    item.played = value.played === true;
    item.imageTag = LocalSourceState.cleanImage(value.imageTag);
    item.backdropTag = LocalSourceState.cleanImage(value.backdropTag);
    item.hasPrimaryImage = value.hasPrimaryImage === true && item.imageTag.length > 0;
    item.path = LocalSourceState.cleanImage(value.path);
    item.container = typeof value.container === 'string' ? value.container.substring(0, 32) : '';
    item.seriesId = typeof value.seriesId === 'string' ? value.seriesId.substring(0, 4096) : '';
    item.seriesName = typeof value.seriesName === 'string' ? value.seriesName.substring(0, 512) : '';
    item.indexNumber = Number.isFinite(value.indexNumber) ? value.indexNumber : 0;
    item.parentIndexNumber = Number.isFinite(value.parentIndexNumber) ? value.parentIndexNumber : 0;
    item.indexNumberKnown = value.indexNumberKnown === true;
    item.parentIndexNumberKnown = value.parentIndexNumberKnown === true;
    item.createdAt = typeof value.createdAt === 'string' ? value.createdAt.substring(0, 64) : '';
    item.modifiedAt = typeof value.modifiedAt === 'string' ? value.modifiedAt.substring(0, 64) : '';
    item.premiereDate = typeof value.premiereDate === 'string' ? value.premiereDate.substring(0, 64) : '';
    item.favoriteKnown = true;
    item.isFavorite = value.isFavorite === true;
    item.genres = Array.isArray(value.genres) ? value.genres.filter((genre: string) =>
      typeof genre === 'string' && genre.length <= 64).slice(0, 32) : [];
    return item;
  }

  private static async load(key: string): Promise<LocalEntry[]> {
    const raw = await Store.get(key, '');
    if (raw.length === 0) { return []; }
    if (raw.length > 2097152) { throw new Error('本机来源记录过大，请清理该来源记录'); }
    try {
      const document = JSON.parse(raw) as LocalDocument;
      if (document.version !== 1 || !Array.isArray(document.entries)) { throw new Error('schema'); }
      const output: LocalEntry[] = [];
      const ids: Set<string> = new Set();
      for (let index = 0; index < Math.min(document.entries.length, LocalSourceState.LIMIT * 2); index++) {
        const entry = document.entries[index];
        try {
          const item = LocalSourceState.snapshot(entry.item);
          if (ids.has(item.id)) { continue; }
          ids.add(item.id); item.isFavorite = entry.favorite === true;
          output.push({ item: item, favorite: entry.favorite === true,
            updatedAt: Number.isFinite(entry.updatedAt) ? entry.updatedAt : 0 });
        } catch (invalidEntry) {}
      }
      return output;
    } catch (e) { throw new Error('本机来源记录无法读取，原记录已保留'); }
  }

  private static async save(key: string, entries: LocalEntry[]): Promise<void> {
    entries.sort((left: LocalEntry, right: LocalEntry) => right.updatedAt - left.updatedAt);
    const favorites = entries.filter((entry: LocalEntry) => entry.favorite);
    if (favorites.length > LocalSourceState.LIMIT) { throw new Error('本机收藏已达 256 条，请先移除部分收藏'); }
    // History retention must never silently remove a favorite.
    const history = entries.filter((entry: LocalEntry) => !entry.favorite).slice(0, LocalSourceState.LIMIT);
    const document: LocalDocument = { version: 1, entries: favorites.concat(history) };
    const raw = JSON.stringify(document);
    if (raw.length > 2097152) { throw new Error('本机来源记录已达容量限制'); }
    await Store.set(key, raw);
  }

  private static mutate(task: () => Promise<void>): Promise<void> {
    const next = LocalSourceState.chain.then(task);
    LocalSourceState.chain = next.then(() => {}, () => {});
    return next;
  }

  static async getFavorites(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    const entries = await LocalSourceState.load(LocalSourceState.key(server));
    return entries.filter((entry: LocalEntry) => entry.favorite).sort((a: LocalEntry, b: LocalEntry) =>
      b.updatedAt - a.updatedAt).slice(0, Math.max(0, Math.min(LocalSourceState.LIMIT, limit)))
      .map((entry: LocalEntry) => LocalSourceState.snapshot(entry.item));
  }

  static addFavorite(server: ServerConfig, id: string, item?: MediaItem): Promise<void> {
    const key = LocalSourceState.key(server);
    const snapshot = item !== undefined ? LocalSourceState.snapshot(item) : null;
    return LocalSourceState.mutate(async () => {
      const entries = await LocalSourceState.load(key);
      let entry = entries.find((value: LocalEntry) => value.item.id === id);
      if (snapshot !== null && snapshot.id !== id) { throw new Error('收藏条目不匹配'); }
      if (entry === undefined) {
        if (snapshot === null) { throw new Error('请先读取影片或文件详情再收藏'); }
        entry = { item: snapshot, favorite: true, updatedAt: Date.now() }; entries.push(entry);
      } else if (snapshot !== null) { entry.item = snapshot; }
      entry.favorite = true; entry.item.isFavorite = true; entry.updatedAt = Date.now();
      await LocalSourceState.save(key, entries);
    });
  }

  static removeFavorite(server: ServerConfig, id: string): Promise<void> {
    const key = LocalSourceState.key(server);
    return LocalSourceState.mutate(async () => {
      const entries = await LocalSourceState.load(key);
      for (let index = 0; index < entries.length; index++) {
        if (entries[index].item.id === id) { entries[index].favorite = false; entries[index].item.isFavorite = false; }
      }
      await LocalSourceState.save(key, entries);
    });
  }

  static async isFavorite(server: ServerConfig, id: string): Promise<boolean> {
    return (await LocalSourceState.load(LocalSourceState.key(server)))
      .some((entry: LocalEntry) => entry.item.id === id && entry.favorite);
  }

  static async getResume(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    const entries = await LocalSourceState.load(LocalSourceState.key(server));
    return entries.filter((entry: LocalEntry) => !entry.item.played && entry.item.progressTicks > 0)
      .sort((a: LocalEntry, b: LocalEntry) => b.updatedAt - a.updatedAt)
      .slice(0, Math.max(0, Math.min(LocalSourceState.LIMIT, limit)))
      .map((entry: LocalEntry) => LocalSourceState.snapshot(entry.item));
  }

  static reportProgress(server: ServerConfig, id: string, positionTicks: number, played: boolean,
    item?: MediaItem): Promise<void> {
    if (!Number.isSafeInteger(positionTicks) || positionTicks < 0) { return Promise.reject(new Error('播放位置无效')); }
    const key = LocalSourceState.key(server);
    const snapshot = item !== undefined ? LocalSourceState.snapshot(item) : null;
    return LocalSourceState.mutate(async () => {
      const entries = await LocalSourceState.load(key);
      let entry = entries.find((value: LocalEntry) => value.item.id === id);
      if (snapshot !== null && snapshot.id !== id) { throw new Error('播放条目不匹配'); }
      if (entry === undefined) {
        if (snapshot === null) { throw new Error('尚未读取此播放条目'); }
        entry = { item: snapshot, favorite: snapshot.isFavorite, updatedAt: Date.now() }; entries.push(entry);
      }
      const favorite = entry.favorite;
      if (snapshot !== null) { entry.item = snapshot; entry.item.isFavorite = favorite; }
      entry.item.progressTicks = positionTicks; entry.item.played = played; entry.updatedAt = Date.now();
      await LocalSourceState.save(key, entries);
    });
  }
}
