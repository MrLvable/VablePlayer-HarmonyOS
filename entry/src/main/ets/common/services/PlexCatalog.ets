import { ServerConfig, Library, MediaItem, ItemDetail, MediaSource, MediaStream, Person, PlaybackInfo } from '../Models';
import { MediaCatalog } from './MediaCatalog';
import { DirectCatalogBase } from './DirectCatalogBase';
import { DirectSourceHttp } from './DirectSourceHttp';
import { SourceIdentity } from './SourceIdentity';

interface PlexTag { id?: string | number; tag?: string; thumb?: string; role?: string; }
interface PlexStream { id?: number | string; index?: number; streamType?: number; codec?: string; languageCode?: string; displayTitle?: string; key?: string; channels?: number; width?: number; height?: number; selected?: boolean; }
interface PlexPart { id?: number | string; key?: string; size?: number; Stream?: PlexStream[]; }
interface PlexMedia { id?: number | string; container?: string; width?: number; height?: number; bitrate?: number; Part?: PlexPart[]; }
interface PlexMetadata {
  ratingKey?: string; key?: string; type?: string; title?: string; year?: number; summary?: string; rating?: number;
  duration?: number; viewOffset?: number; viewCount?: number; thumb?: string; art?: string; index?: number;
  parentIndex?: number; parentRatingKey?: string; grandparentRatingKey?: string; grandparentTitle?: string;
  originallyAvailableAt?: string; addedAt?: number; Media?: PlexMedia[]; Role?: PlexTag[]; Genre?: PlexTag[];
}
interface PlexContainer { size?: number | string; offset?: number; totalSize?: number; Metadata?: PlexMetadata[]; Directory?: PlexMetadata[]; machineIdentifier?: string; version?: string; friendlyName?: string; }
interface PlexDocument { MediaContainer?: PlexContainer; }

export class PlexCatalog extends DirectCatalogBase implements MediaCatalog {
  private transport: DirectSourceHttp = new DirectSourceHttp();
  private static sections: Map<string, string> = new Map();
  private static paths: Map<string, string> = new Map();
  private static subtitlePaths: Map<string, string> = new Map();
  private static personPaths: Map<string, string> = new Map();
  cancel(): void { this.transport.cancel(); }
  headers(server: ServerConfig): Record<string, string> {
    const headers: Record<string, string> = { 'Accept': 'application/json', 'X-Plex-Client-Identifier': server.clientId.length > 0 ? server.clientId : 'nasplayer-' + server.id,
      'X-Plex-Product': 'NAS Player Harmony', 'X-Plex-Version': '1.0' };
    if (server.token.length > 0) { headers['X-Plex-Token'] = server.token; }
    return headers;
  }
  private scope(server: ServerConfig, id: string): string { return SourceIdentity.scope(server) + '|' + id; }
  private put(target: Map<string, string>, key: string, value: string): void {
    target.delete(key); target.set(key, value);
    if (target.size > 20000) {
      let first = ''; target.forEach((_entry: string, id: string) => { if (first.length === 0) { first = id; } }); target.delete(first);
    }
  }
  private endpoint(server: ServerConfig, path: string): string {
    const base = server.baseUrl().replace(/\/+$/, '');
    const address = /^https?:\/\//i.test(path) ? DirectSourceHttp.resolve(base + '/', path) : base + '/' + path.replace(/^\/+/, '');
    if (!DirectSourceHttp.sameOrigin(base, address)) { throw new Error('Plex 返回了不同主机的认证资源地址'); }
    return address;
  }
  private async get(server: ServerConfig, path: string, headers: Record<string, string> = {}): Promise<PlexContainer> {
    const merged = this.headers(server); Object.keys(headers).forEach((key: string) => { merged[key] = headers[key]; });
    const response = await this.transport.request(this.endpoint(server, path), 'GET', merged);
    if (response.status !== 200) { throw new Error('Plex 请求失败（HTTP ' + response.status.toString() + '）'); }
    let document: PlexDocument;
    try { document = JSON.parse(response.text) as PlexDocument; } catch (e) { throw new Error('Plex 返回了无效 JSON'); }
    if (document.MediaContainer === undefined) { throw new Error('不是有效的 Plex 媒体响应'); }
    const returnedStart = response.headers['x-plex-container-start'];
    const returnedTotal = response.headers['x-plex-container-total-size'];
    if (returnedStart !== undefined) {
      if (!/^\d+$/.test(returnedStart) || (document.MediaContainer.offset !== undefined && document.MediaContainer.offset !== Number(returnedStart))) { throw new Error('Plex 分页头与响应偏移不匹配'); }
      document.MediaContainer.offset = Number(returnedStart);
    }
    if (returnedTotal !== undefined) {
      if (!/^\d+$/.test(returnedTotal) || (document.MediaContainer.totalSize !== undefined && document.MediaContainer.totalSize !== Number(returnedTotal))) { throw new Error('Plex 分页总数不匹配'); }
      document.MediaContainer.totalSize = Number(returnedTotal);
    }
    return document.MediaContainer;
  }
  async login(server: ServerConfig, token: string): Promise<ServerConfig> {
    if (token.trim().length > 0) { server.token = token.trim(); }
    if (server.token.length === 0) { throw new Error('请填写 Plex 访问令牌'); }
    const identity = await this.get(server, '/identity');
    if (typeof identity.machineIdentifier !== 'string' || identity.machineIdentifier.length === 0) { throw new Error('Plex 身份验证响应无效'); }
    await this.getViews(server); // identity is public; library access is the authentication check.
    server.version = typeof identity.version === 'string' ? identity.version : '';
    const info = await this.get(server, '/');
    server.serverName = typeof info.friendlyName === 'string' ? info.friendlyName : server.name;
    return server;
  }
  async getViews(server: ServerConfig): Promise<Library[]> {
    const data = await this.get(server, '/library/sections');
    if (!Array.isArray(data.Directory)) { if (Number(data.size) === 0) { return []; } throw new Error('Plex 库列表响应缺少 Directory'); }
    const result: Library[] = [];
    data.Directory.forEach((entry: PlexMetadata) => {
      if (typeof entry.key !== 'string' || typeof entry.title !== 'string') { throw new Error('Plex 库标识无效'); }
      if (entry.type !== 'movie' && entry.type !== 'show') { return; }
      this.put(PlexCatalog.sections, this.scope(server, entry.key), entry.type);
      result.push(new Library(entry.key, entry.title, entry.type === 'movie' ? 'movies' : 'tvshows'));
    });
    return result;
  }
  private item(server: ServerConfig, raw: PlexMetadata): MediaItem {
    if (typeof raw.ratingKey !== 'string' || raw.ratingKey.length === 0 || typeof raw.title !== 'string') { throw new Error('Plex 元数据缺少真实标识或标题'); }
    const item = new MediaItem(); item.id = raw.ratingKey; item.name = raw.title;
    item.type = raw.type === 'show' ? 'Series' : raw.type === 'season' ? 'Season' : raw.type === 'episode' ? 'Episode' : raw.type === 'movie' ? 'Movie' : 'Video';
    item.year = raw.year !== undefined ? raw.year : 0; item.overview = raw.summary !== undefined ? raw.summary : '';
    item.rating = raw.rating !== undefined ? raw.rating : 0; item.runtimeTicks = Math.max(0, raw.duration !== undefined ? raw.duration : 0) * 10000;
    item.progressTicks = Math.max(0, raw.viewOffset !== undefined ? raw.viewOffset : 0) * 10000; item.played = (raw.viewCount !== undefined ? raw.viewCount : 0) > 0;
    item.indexNumber = raw.index !== undefined ? raw.index : 0; item.indexNumberKnown = raw.index !== undefined;
    item.parentIndexNumber = raw.parentIndex !== undefined ? raw.parentIndex : 0; item.parentIndexNumberKnown = raw.parentIndex !== undefined;
    item.seriesId = raw.type === 'episode' ? (raw.grandparentRatingKey !== undefined ? raw.grandparentRatingKey : '')
      : raw.type === 'season' ? (raw.parentRatingKey !== undefined ? raw.parentRatingKey : '') : '';
    item.seriesName = raw.grandparentTitle !== undefined ? raw.grandparentTitle : '';
    item.premiereDate = raw.originallyAvailableAt !== undefined ? raw.originallyAvailableAt : '';
    if (raw.addedAt !== undefined && raw.addedAt > 0) { item.createdAt = new Date(raw.addedAt * 1000).toISOString(); }
    item.genres = raw.Genre !== undefined ? raw.Genre.map((tag: PlexTag) => tag.tag !== undefined ? tag.tag : '').filter((name: string) => name.length > 0) : [];
    item.imageTag = this.safeImage(server, raw.thumb); item.backdropTag = this.safeImage(server, raw.art); item.hasPrimaryImage = item.imageTag.length > 0;
    if (raw.Media !== undefined && raw.Media.length > 0) { item.container = raw.Media[0].container !== undefined ? raw.Media[0].container : ''; }
    return item;
  }
  private safeImage(server: ServerConfig, key?: string): string {
    if (typeof key !== 'string' || key.length === 0) { return ''; }
    try { return this.endpoint(server, key); } catch (e) { return ''; }
  }
  private async page(server: ServerConfig, path: string, start: number, limit: number): Promise<MediaItem[]> {
    if (!Number.isInteger(start) || start < 0 || !Number.isInteger(limit) || limit < 1 || limit > 5000) { throw new Error('Plex 分页范围无效'); }
    const output: MediaItem[] = []; const ids: string[] = []; let offset = start; let total = -1;
    for (let request = 0; output.length < limit && request < 100; request++) {
      const count = Math.min(200, limit - output.length);
      const data = await this.get(server, path, { 'X-Plex-Container-Start': offset.toString(), 'X-Plex-Container-Size': count.toString() });
      if (data.Metadata === undefined && Number(data.size) !== 0) { throw new Error('Plex 分页响应缺少 Metadata'); }
      const list = data.Metadata !== undefined ? data.Metadata : [];
      if (!Array.isArray(list) || (data.offset !== undefined && data.offset !== offset)) { throw new Error('Plex 分页响应偏移不匹配'); }
      if (data.offset === undefined) {
        // PMS may ignore pagination and return the whole collection. Slice that
        // collection locally; never mistake its first page for a nonzero offset.
        if (data.totalSize !== undefined && data.totalSize !== list.length) { throw new Error('Plex 未标明分页偏移且内容不完整'); }
        return this.remember(server, list.slice(start, start + limit).map((raw: PlexMetadata) => this.item(server, raw)));
      }
      if (data.totalSize !== undefined) {
        if (total >= 0 && total !== data.totalSize) { throw new Error('Plex 内容在分页期间改变，请重试'); }
        total = data.totalSize;
      }
      if (list.length === 0) {
        if (data.totalSize !== undefined && offset < data.totalSize) { throw new Error('Plex 分页提前结束，未返回完整内容'); }
        break;
      }
      for (let i = 0; i < list.length && output.length < limit; i++) {
        const item = this.item(server, list[i]);
        if (ids.indexOf(item.id) >= 0) { throw new Error('Plex 分页重复，已停止读取'); }
        ids.push(item.id); output.push(item);
      }
      offset += list.length;
      if (data.totalSize !== undefined ? offset >= data.totalSize : list.length < count) { break; }
      if (request === 99 && output.length < limit) { throw new Error('Plex 分页超过安全上限'); }
    }
    return this.remember(server, output);
  }
  async getItems(server: ServerConfig, parent: string, start: number, limit: number, recursive: boolean): Promise<MediaItem[]> {
    if (!PlexCatalog.sections.has(this.scope(server, parent))) { await this.getViews(server); }
    const section = PlexCatalog.sections.has(this.scope(server, parent));
    const path = section ? '/library/sections/' + encodeURIComponent(parent) + (recursive ? '/allLeaves' : '/all')
      : '/library/metadata/' + encodeURIComponent(parent) + (recursive ? '/allLeaves' : '/children');
    return this.page(server, path, start, limit);
  }
  getLatest(server: ServerConfig, parent: string, limit: number): Promise<MediaItem[]> { return this.page(server, '/library/sections/' + encodeURIComponent(parent) + '/recentlyAdded', 0, limit); }
  getSeasons(server: ServerConfig, series: string): Promise<MediaItem[]> { return this.page(server, '/library/metadata/' + encodeURIComponent(series) + '/children', 0, 5000); }
  getEpisodes(server: ServerConfig, series: string, season: string): Promise<MediaItem[]> {
    return this.page(server, '/library/metadata/' + encodeURIComponent(season.length > 0 ? season : series) + (season.length > 0 ? '/children' : '/allLeaves'), 0, 5000);
  }
  search(server: ServerConfig, query: string, limit: number): Promise<MediaItem[]> {
    return this.page(server, '/library/all?title=' + encodeURIComponent(query), 0, limit);
  }
  async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const data = await this.get(server, '/library/metadata/' + encodeURIComponent(id));
    if (data.Metadata === undefined || data.Metadata.length !== 1) { throw new Error('Plex 影片详细信息不可用'); }
    const raw = data.Metadata[0]; const detail = new ItemDetail(); detail.item = this.item(server, raw);
    const media = raw.Media !== undefined ? raw.Media : [];
    for (let i = 0; i < media.length; i++) {
      const parts = media[i].Part !== undefined ? media[i].Part as PlexPart[] : [];
      if (parts.length !== 1 || typeof parts[0].key !== 'string' || (parts[0].key as string).length === 0) { continue; }
      const source = new MediaSource(); source.id = media[i].id !== undefined ? String(media[i].id) : parts[0].key as string;
      source.container = media[i].container !== undefined ? media[i].container as string : ''; source.sizeBytes = parts[0].size !== undefined ? parts[0].size as number : 0;
      this.put(PlexCatalog.paths, this.scope(server, id + '|' + source.id), this.endpoint(server, parts[0].key as string));
      if (detail.sources.length === 0) { this.put(PlexCatalog.paths, this.scope(server, id + '|'), this.endpoint(server, parts[0].key as string)); }
      const streams = parts[0].Stream !== undefined ? parts[0].Stream as PlexStream[] : [];
      streams.forEach((entry: PlexStream) => {
        // Plex Stream.id is a server-wide key, not the native demux stream index.
        const stream = new MediaStream(); stream.index = entry.index !== undefined ? entry.index : -1;
        if (!Number.isInteger(stream.index) || stream.index < 0) { return; }
        stream.type = entry.streamType === 1 ? 'Video' : entry.streamType === 2 ? 'Audio' : entry.streamType === 3 ? 'Subtitle' : '';
        stream.codec = entry.codec !== undefined ? entry.codec : ''; stream.language = entry.languageCode !== undefined ? entry.languageCode : '';
        stream.title = entry.displayTitle !== undefined ? entry.displayTitle : ''; stream.width = entry.width !== undefined ? entry.width : media[i].width !== undefined ? media[i].width as number : 0;
        stream.height = entry.height !== undefined ? entry.height : media[i].height !== undefined ? media[i].height as number : 0;
        stream.channels = entry.channels !== undefined ? entry.channels : 0; stream.isDefault = entry.selected === true;
        if (entry.streamType === 3 && typeof entry.key === 'string' && entry.key.length > 0) {
          this.put(PlexCatalog.subtitlePaths, this.scope(server, id + '|' + source.id + '|' + stream.index.toString()), this.endpoint(server, entry.key)); stream.isExternal = true;
        }
        if (stream.type.length > 0) { source.streams.push(stream); }
      });
      detail.sources.push(source);
    }
    this.remember(server, [detail.item]); return detail;
  }
  async playback(server: ServerConfig, id: string, selected: string): Promise<PlaybackInfo> {
    const detail = await this.getItemDetail(server, id);
    const source = selected.length > 0 ? detail.sources.find((entry: MediaSource) => entry.id === selected) : detail.sources[0];
    if (source === undefined) { throw new Error('Plex 没有可直连的单文件媒体源；多分段影片暂不支持'); }
    const info = new PlaybackInfo(); info.url = this.stream(server, id, source.id); info.mediaSourceId = source.id;
    info.isHls = DirectSourceHttp.extension(info.url) === 'm3u8'; info.headers = this.headers(server); return info;
  }
  stream(server: ServerConfig, id: string, source: string = ''): string {
    const key = this.scope(server, id + '|' + source); const found = PlexCatalog.paths.get(key);
    if (found !== undefined) { return found; }
    throw new Error('Plex 真实 Part 地址尚未解析，请先读取播放信息');
  }
  async getPeople(server: ServerConfig, id: string): Promise<Person[]> {
    const data = await this.get(server, '/library/metadata/' + encodeURIComponent(id));
    if (data.Metadata === undefined || data.Metadata.length === 0) { throw new Error('Plex 演职员信息读取失败'); }
    const roles = data.Metadata[0].Role !== undefined ? data.Metadata[0].Role as PlexTag[] : [];
    return roles.map((entry: PlexTag) => {
      const person = new Person(); person.id = entry.id !== undefined ? String(entry.id) : entry.tag !== undefined ? entry.tag : '';
      person.name = entry.tag !== undefined ? entry.tag : ''; person.role = entry.role !== undefined ? entry.role : ''; person.type = 'Actor';
      const image = this.safeImage(server, entry.thumb); person.hasImage = image.length > 0;
      if (person.hasImage) { this.put(PlexCatalog.personPaths, this.scope(server, person.id), image); } return person;
    });
  }
  imageHeaders(server: ServerConfig): Record<string, string> { return this.headers(server); }
  imageUrl(server: ServerConfig, _id: string, _width: number, tag: string): string { return this.safeImage(server, tag); }
  backdropUrl(server: ServerConfig, id: string, width: number, backdrop: string, primary: string): string { return this.imageUrl(server, id, width, backdrop.length > 0 ? backdrop : primary); }
  personImageUrl(server: ServerConfig, id: string, _width: number): string { const value = PlexCatalog.personPaths.get(this.scope(server, id)); return value !== undefined ? value : ''; }
  subtitleUrl(server: ServerConfig, id: string, source: string, index: number, _codec: string): string {
    const value = PlexCatalog.subtitlePaths.get(this.scope(server, id + '|' + source + '|' + index.toString()));
    if (value === undefined) { throw new Error('Plex 未提供该字幕的真实下载地址'); } return value;
  }
  /** Caller supplies real playback state; local bookmark reporting never invents a server session. */
  async reportTimeline(server: ServerConfig, id: string, positionTicks: number, durationTicks: number, state: string): Promise<void> {
    if (!Number.isSafeInteger(positionTicks) || positionTicks < 0 || !Number.isSafeInteger(durationTicks) || durationTicks < 0
      || (state !== 'playing' && state !== 'paused' && state !== 'stopped') || id.length === 0) { throw new Error('Plex 播放状态或时间无效'); }
    const path = '/:/timeline?ratingKey=' + encodeURIComponent(id) + '&key=' + encodeURIComponent('/library/metadata/' + id)
      + '&state=' + state + '&time=' + Math.floor(positionTicks / 10000).toString()
      + (durationTicks > 0 ? '&duration=' + Math.floor(durationTicks / 10000).toString() : '');
    const response = await this.transport.request(this.endpoint(server, path), 'POST', this.headers(server));
    if (response.status !== 200) { throw new Error('Plex 播放状态同步失败（HTTP ' + response.status.toString() + '）'); }
  }
}
