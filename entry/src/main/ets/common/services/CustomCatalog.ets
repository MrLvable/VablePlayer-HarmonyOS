import { ServerConfig, Library, MediaItem, ItemDetail, PlaybackInfo } from '../Models';
import { DirectCatalogBase } from './DirectCatalogBase';
import { MediaCatalog } from './MediaCatalog';
import { DirectSourceHttp } from './DirectSourceHttp';
import { SourceIdentity } from './SourceIdentity';
import { CustomManifest, CustomSnapshot, CustomEntry } from './CustomManifest';
import { LocalAccess } from './LocalAccess';

export class CustomCatalog extends DirectCatalogBase implements MediaCatalog {
  private transport: DirectSourceHttp = new DirectSourceHttp(); private generation: number = 0;
  private static cache: Map<string, CustomSnapshot> = new Map();
  cancel(): void { this.generation++; this.transport.cancel(); }
  headers(server: ServerConfig): Record<string, string> {
    if (server.authMode === 'anonymous' || server.sourceUrl.startsWith('file://')) { return {}; }
    if (server.authMode === 'token') { return server.token.length > 0 ? { 'Authorization': server.token } : {}; }
    return { 'Authorization': DirectSourceHttp.basic(server.username, server.password) };
  }
  private source(server: ServerConfig): string {
    if (server.sourceUrl.startsWith('file://')) { return LocalAccess.validate(server.sourceUrl); }
    if (server.sourceUrl.trim().length === 0) { throw new Error('请指定本应用 version1 JSON 媒体库地址或选择本地 JSON 文件'); }
    return DirectSourceHttp.resolve(server.sourceUrl, server.sourceUrl);
  }
  private cacheKey(server: ServerConfig): string {
    return SourceIdentity.scope(server) + SourceIdentity.key([server.sourceUrl, server.authMode, server.token, server.password].join('\u0000'));
  }
  private async snapshot(server: ServerConfig, refresh: boolean = false): Promise<CustomSnapshot> {
    const key = this.cacheKey(server); const old = CustomCatalog.cache.get(key);
    if (!refresh && old !== undefined && Date.now() - old.loaded < 30000) { return old; }
    const gen = this.generation; const address = this.source(server); const local = address.startsWith('file://');
    let text = ''; let finalAddress = address;
    if (local) {
      if (!/\.json$/i.test(LocalAccess.fileName(address))) { throw new Error('自定义媒体库请选择 .json 文件，选择器过滤不代替此校验'); }
      text = await LocalAccess.readDocument(address, 2097152);
    } else {
      const response = await this.transport.request(address, 'GET', this.headers(server), '', 2097152);
      if (response.status !== 200) { throw new Error('JSON 媒体库读取失败（HTTP ' + response.status.toString() + '）'); }
      text = response.text; finalAddress = response.address;
    }
    if (gen !== this.generation) { throw new Error('JSON 媒体库读取已取消'); }
    const snapshot = CustomManifest.parse(text, finalAddress, local, this.headers(server));
    CustomCatalog.cache.set(key, snapshot);
    if (CustomCatalog.cache.size > 8) {
      let first = ''; CustomCatalog.cache.forEach((_value: CustomSnapshot, id: string) => { if (first.length === 0) { first = id; } }); CustomCatalog.cache.delete(first);
    }
    return snapshot;
  }
  async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    if (password.length > 0) { server.password = password; }
    server.serverName = (await this.snapshot(server, true)).name; return server;
  }
  async getViews(server: ServerConfig): Promise<Library[]> { return [new Library('custom:root', (await this.snapshot(server)).name, 'folders')]; }
  private folder(id: string, snapshot: CustomSnapshot): string {
    if (id.length === 0 || id === 'custom:root') { return ''; }
    if (!id.startsWith('custom:folder:')) { throw new Error('JSON 目录标识无效'); }
    let raw = ''; try { raw = decodeURIComponent(id.substring(14)); } catch (e) { throw new Error('JSON 目录标识无效'); }
    if (!snapshot.folders.has(raw)) { throw new Error('JSON 目录不存在'); } return raw;
  }
  private descendant(parent: string, root: string, snapshot: CustomSnapshot): boolean {
    let value = parent;
    while (value.length > 0) { if (value === root) { return true; } value = snapshot.parents.get(value) || ''; }
    return root.length === 0;
  }
  async getItems(server: ServerConfig, parent: string, start: number, limit: number, recursive: boolean): Promise<MediaItem[]> {
    if (!Number.isInteger(start) || start < 0 || !Number.isInteger(limit) || limit < 1 || limit > 5000) { throw new Error('JSON 分页范围无效'); }
    const snapshot = await this.snapshot(server); const folder = this.folder(parent, snapshot); const items: MediaItem[] = [];
    if (!recursive) { snapshot.folders.forEach((item: MediaItem, id: string) => { if ((snapshot.parents.get(id) || '') === folder) { items.push(item); } }); }
    snapshot.entries.forEach((entry: CustomEntry) => { if (recursive ? this.descendant(entry.parentId, folder, snapshot) : entry.parentId === folder) { items.push(entry.item); } });
    return this.remember(server, items.slice(start, start + limit));
  }
  async getLatest(server: ServerConfig, parent: string, limit: number): Promise<MediaItem[]> {
    const items = await this.getItems(server, parent, 0, 5000, true);
    if (items.some((item: MediaItem) => item.createdAt.length === 0 && item.modifiedAt.length === 0)) { throw this.unsupported('完整时间元数据，无法推断“最新”排序'); }
    return items.sort((a: MediaItem, b: MediaItem) => Date.parse(b.modifiedAt || b.createdAt) - Date.parse(a.modifiedAt || a.createdAt)).slice(0, limit);
  }
  async search(server: ServerConfig, query: string, limit: number): Promise<MediaItem[]> {
    if (query.trim().length === 0) { return []; }
    return (await this.getItems(server, '', 0, 5000, true)).filter((item: MediaItem) => item.name.toLowerCase().indexOf(query.trim().toLowerCase()) >= 0).slice(0, limit);
  }
  private async entry(server: ServerConfig, id: string): Promise<CustomEntry> {
    if (!id.startsWith('custom:item:')) { throw new Error('JSON 媒体标识无效'); }
    let raw = ''; try { raw = decodeURIComponent(id.substring(12)); } catch (e) { throw new Error('JSON 媒体标识无效'); }
    const found = (await this.snapshot(server)).entries.get(raw); if (found === undefined) { throw new Error('JSON 媒体条目不存在'); } return found;
  }
  async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const entry = await this.entry(server, id); const detail = new ItemDetail(); detail.item = entry.item; detail.sources = [entry.source];
    detail.item.isFavorite = await this.isFavorite(server, id); detail.item.favoriteKnown = true; this.remember(server, [detail.item]); return detail;
  }
  async playback(server: ServerConfig, id: string): Promise<PlaybackInfo> {
    const entry = await this.entry(server, id);
    if (entry.address.startsWith('file://')) { const result = await LocalAccess.openPlayable(entry.address); result.mediaSourceId = id; return result; }
    const result = new PlaybackInfo(); result.url = entry.address; result.headers = entry.headers; result.isLive = entry.live;
    result.isHls = DirectSourceHttp.extension(entry.address) === 'm3u8'; result.mediaSourceId = id; return result;
  }
  imageUrl(_server: ServerConfig, _id: string, _width: number, tag: string): string { return /^https?:\/\//i.test(tag) ? DirectSourceHttp.resolve(tag, tag) : ''; }
  backdropUrl(server: ServerConfig, id: string, width: number, backdrop: string, primary: string): string { return this.imageUrl(server, id, width, backdrop || primary); }
  imageHeaders(server: ServerConfig): Record<string, string> { return this.headers(server); }
  subtitleUrl(server: ServerConfig, id: string, _source: string, index: number, _codec: string): string {
    const snapshot = CustomCatalog.cache.get(this.cacheKey(server));
    if (snapshot === undefined || !id.startsWith('custom:item:')) { throw new Error('请先读取 JSON 媒体详情'); }
    const entry = snapshot.entries.get(decodeURIComponent(id.substring(12))); const offset = index - 1000;
    if (entry === undefined || !Number.isInteger(offset) || offset < 0 || offset >= entry.subtitles.length) { throw new Error('JSON 字幕不存在'); }
    return entry.subtitles[offset].url;
  }
}
