import { MediaItem, ServerConfig } from './Models';
import { MediaServices } from './services/MediaServices';

interface QueueBatch {
  season: number;
  items: MediaItem[];
}

/** A visible failure is preferable to guessing an episode from a title or a partial seed list. */
export class PlaybackQueueError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = 'PlaybackQueueError';
    this.code = code;
  }
}

/** Resolves the server's full series list; does not release a player or navigate. */
export class PlaybackQueueResolver {
  private static readonly MAX_SEASONS: number = 64;
  private static readonly MAX_EPISODES: number = 5000;
  private static readonly CONCURRENCY: number = 3;

  static async resolve(server: ServerConfig, current: MediaItem, seed: MediaItem[]): Promise<MediaItem[]> {
    if (server === null || server === undefined ||
        ['fnos', 'fnos-native', 'emby', 'jellyfin', 'plex'].indexOf(server.kind) < 0 ||
        server.id.length === 0 || server.host.length === 0 || server.host.startsWith('file:')) {
      throw new PlaybackQueueError('unsupported', '本地文件或当前来源不支持自动下一集');
    }
    if (current === null || current === undefined || current.type !== 'Episode' ||
        current.id.length === 0 || current.seriesId.length === 0) {
      throw new PlaybackQueueError('not-episode', '当前条目没有可确认的剧集身份');
    }
    let fresh = current;
    if (!PlaybackQueueResolver.knownEpisodeOrder(current)) {
      try { fresh = (await MediaServices.getItemDetail(server, current.id)).item; }
      catch (e) { throw new PlaybackQueueError('current-load', '无法读取当前集信息，请手动选集或重试'); }
      if (fresh.type !== 'Episode' || fresh.id !== current.id || fresh.seriesId !== current.seriesId) {
        throw new PlaybackQueueError('identity-changed', '当前集身份已变化，请重新进入剧集');
      }
    }
    if (!PlaybackQueueResolver.knownEpisodeOrder(fresh)) {
      throw new PlaybackQueueError('unknown-current-order', '当前集缺少真实季集编号，无法确定下一集');
    }

    const batches = await PlaybackQueueResolver.fetchAll(server, fresh.seriesId);
    const seedMap: Map<string, MediaItem> = new Map<string, MediaItem>();
    for (let i = 0; i < seed.length; i++) {
      const item = seed[i];
      if (item.type === 'Episode' && item.seriesId === fresh.seriesId && item.id.length > 0) {
        seedMap.set(item.id, item);
      }
    }
    const byId: Map<string, MediaItem> = new Map<string, MediaItem>();
    for (let i = 0; i < batches.length; i++) {
      for (let j = 0; j < batches[i].items.length; j++) {
        const source = batches[i].items[j];
        if (source.type !== 'Episode' || source.id.length === 0 ||
            (source.seriesId.length > 0 && source.seriesId !== fresh.seriesId)) { continue; }
        const item = PlaybackQueueResolver.copy(source);
        // Membership comes from the /Shows/{seriesId}/Episodes request, never a guessed name.
        item.seriesId = fresh.seriesId;
        if (!PlaybackQueueResolver.knownSeason(item) && batches[i].season >= 0) {
          item.parentIndexNumber = batches[i].season;
          item.parentIndexNumberKnown = true;
        }
        if (item.id === fresh.id) {
          PlaybackQueueResolver.applyCurrentOrder(item, fresh);
        }
        if (!PlaybackQueueResolver.knownEpisodeOrder(item)) {
          throw new PlaybackQueueError('unknown-order', '分集列表缺少真实季集编号，请手动选集');
        }
        const previous = byId.get(item.id);
        if (previous !== undefined) {
          if (previous.parentIndexNumber !== item.parentIndexNumber || previous.indexNumber !== item.indexNumber) {
            throw new PlaybackQueueError('conflicting-order', '服务器返回的分集编号不一致，请手动选集');
          }
          continue;
        }
        const cached = seedMap.get(item.id);
        if (cached !== undefined) { PlaybackQueueResolver.enrichPresentation(item, cached); }
        byId.set(item.id, item);
        if (byId.size > PlaybackQueueResolver.MAX_EPISODES) {
          throw new PlaybackQueueError('too-many', '分集列表过大，请手动选择剧集');
        }
      }
    }
    if (!byId.has(fresh.id)) {
      throw new PlaybackQueueError('current-missing', '服务器分集列表未包含当前集，请重新选集');
    }
    const queue: MediaItem[] = [];
    byId.forEach((item: MediaItem) => { queue.push(item); });
    queue.sort((a: MediaItem, b: MediaItem) =>
      a.parentIndexNumber - b.parentIndexNumber || a.indexNumber - b.indexNumber);
    for (let i = 1; i < queue.length; i++) {
      if (queue[i].parentIndexNumber === queue[i - 1].parentIndexNumber &&
          queue[i].indexNumber === queue[i - 1].indexNumber) {
        throw new PlaybackQueueError('ambiguous-version', '同一季集编号存在多个条目，请手动选择版本');
      }
    }
    return queue;
  }

  private static async fetchAll(server: ServerConfig, seriesId: string): Promise<QueueBatch[]> {
    try {
      const seasons = await MediaServices.getSeasons(server, seriesId);
      const unique: MediaItem[] = [];
      const seasonIds: string[] = [];
      for (let i = 0; i < seasons.length; i++) {
        const season = seasons[i];
        if (season.type !== 'Season' || season.id.length === 0 || !PlaybackQueueResolver.knownIndex(season)) {
          throw new Error('Unusable season metadata');
        }
        if (seasonIds.indexOf(season.id) < 0) { unique.push(season); seasonIds.push(season.id); }
      }
      if (unique.length > 0 && unique.length <= PlaybackQueueResolver.MAX_SEASONS) {
        const batches: QueueBatch[] = [];
        for (let start = 0; start < unique.length; start += PlaybackQueueResolver.CONCURRENCY) {
          const group = unique.slice(start, start + PlaybackQueueResolver.CONCURRENCY);
          const loaded = await Promise.all(group.map(async (season: MediaItem): Promise<QueueBatch> => {
            const items = await MediaServices.getEpisodes(server, seriesId, season.id);
            return { season: season.indexNumber, items: items };
          }));
          for (let i = 0; i < loaded.length; i++) { batches.push(loaded[i]); }
        }
        return batches;
      }
    } catch (e) {
      // A provider may omit the seasons endpoint. Try the standard all-series request below.
      // Never return a successfully fetched first season as if it were the complete series.
    }
    try {
      const items = await MediaServices.getEpisodes(server, seriesId, '');
      return [{ season: -1, items: items }];
    } catch (e) {
      throw new PlaybackQueueError('queue-load', '无法加载完整分集列表，请重试或手动选集');
    }
  }

  private static knownIndex(item: MediaItem): boolean {
    const value = item.indexNumber;
    return typeof value === 'number' && Number.isFinite(value) && value >= 0 && Math.floor(value) === value &&
      (value > 0 || item.indexNumberKnown === true);
  }

  private static knownSeason(item: MediaItem): boolean {
    const value = item.parentIndexNumber;
    return typeof value === 'number' && Number.isFinite(value) && value >= 0 && Math.floor(value) === value &&
      (value > 0 || item.parentIndexNumberKnown === true);
  }

  private static knownEpisodeOrder(item: MediaItem): boolean {
    return PlaybackQueueResolver.knownIndex(item) && PlaybackQueueResolver.knownSeason(item);
  }

  private static applyCurrentOrder(item: MediaItem, fresh: MediaItem): void {
    if ((PlaybackQueueResolver.knownIndex(item) && item.indexNumber !== fresh.indexNumber) ||
        (PlaybackQueueResolver.knownSeason(item) && item.parentIndexNumber !== fresh.parentIndexNumber)) {
      throw new PlaybackQueueError('current-order-conflict', '当前集与列表编号不一致，请重新进入剧集');
    }
    item.indexNumber = fresh.indexNumber;
    item.parentIndexNumber = fresh.parentIndexNumber;
    item.indexNumberKnown = true;
    item.parentIndexNumberKnown = true;
  }

  private static enrichPresentation(item: MediaItem, seed: MediaItem): void {
    if (item.name.length === 0) { item.name = seed.name; }
    if (item.overview.length === 0) { item.overview = seed.overview; }
    if (!item.hasPrimaryImage && seed.hasPrimaryImage) {
      item.hasPrimaryImage = true; item.imageTag = seed.imageTag;
    }
    if (item.backdropTag.length === 0) { item.backdropTag = seed.backdropTag; }
  }

  private static copy(source: MediaItem): MediaItem {
    const item = new MediaItem();
    item.id = source.id; item.name = source.name; item.type = source.type;
    item.year = source.year; item.overview = source.overview; item.rating = source.rating;
    item.runtimeTicks = source.runtimeTicks; item.hasPrimaryImage = source.hasPrimaryImage;
    item.imageTag = source.imageTag; item.backdropTag = source.backdropTag; item.container = source.container;
    item.genres = source.genres.slice(); item.createdAt = source.createdAt; item.premiereDate = source.premiereDate;
    item.isFavorite = source.isFavorite; item.favoriteKnown = source.favoriteKnown; item.path = source.path;
    item.indexNumber = source.indexNumber; item.parentIndexNumber = source.parentIndexNumber;
    item.indexNumberKnown = source.indexNumberKnown; item.parentIndexNumberKnown = source.parentIndexNumberKnown;
    item.seriesId = source.seriesId; item.seriesName = source.seriesName;
    item.played = source.played; item.progressTicks = source.progressTicks;
    return item;
  }
}
