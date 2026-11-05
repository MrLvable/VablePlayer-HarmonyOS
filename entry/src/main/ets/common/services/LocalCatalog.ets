import localNative, { LocalFileStat, LocalDirectoryEntry } from 'libnas_local.so';
import { ServerConfig, Library, MediaItem, ItemDetail, MediaSource } from '../Models';
import { DirectCatalogBase } from './DirectCatalogBase';
import { MediaCatalog } from './MediaCatalog';
import { LocalAccess } from './LocalAccess';

export class LocalCatalog extends DirectCatalogBase implements MediaCatalog {
  private generation: number = 0;
  cancel(): void { this.generation++; }
  root(server: ServerConfig): string { return LocalAccess.validate(server.sourceUrl); }
  path(id: string): string {
    if (id.length === 0) { return ''; }
    if (!id.startsWith('local:')) { throw new Error('不是本地来源的文件标识'); }
    try { return LocalAccess.relative(decodeURIComponent(id.substring(6))); } catch (e) { throw new Error('本地文件标识无效或超出根目录'); }
  }
  id(path: string): string { return 'local:' + encodeURIComponent(LocalAccess.relative(path)); }
  private async stat(server: ServerConfig, path: string): Promise<LocalFileStat> {
    const gen = this.generation;
    const result: LocalFileStat = await LocalAccess.withRoot<LocalFileStat>(this.root(server), (fd: number): Promise<LocalFileStat> => localNative.stat(fd, LocalAccess.relative(path)));
    if (gen !== this.generation) { throw new Error('本地目录读取已取消'); } return result;
  }
  private item(server: ServerConfig, path: string, stat: LocalFileStat): MediaItem {
    const item = new MediaItem(); item.id = this.id(path); item.path = path;
    item.name = path.length > 0 ? path.substring(path.lastIndexOf('/') + 1) : LocalAccess.fileName(this.root(server));
    item.type = stat.isDirectory ? 'Folder' : /\.(mkv|mp4|m4v|mov|webm|avi|ts|m2ts|mpg|mpeg|flv|wmv)$/i.test(item.name) ? 'Video' : 'File';
    if (!stat.isDirectory && item.name.indexOf('.') >= 0) { item.container = item.name.substring(item.name.lastIndexOf('.') + 1).toLowerCase(); }
    if (Number.isFinite(stat.modifiedTime) && Math.abs(stat.modifiedTime) <= 8640000000000000) { item.modifiedAt = new Date(stat.modifiedTime).toISOString(); }
    return item;
  }
  async login(server: ServerConfig, _password: string): Promise<ServerConfig> {
    await this.stat(server, ''); server.serverName = server.name.length > 0 ? server.name : LocalAccess.fileName(this.root(server)); return server;
  }
  async getViews(server: ServerConfig): Promise<Library[]> {
    const info = await this.stat(server, '');
    return [new Library(this.id(''), LocalAccess.fileName(this.root(server)), info.isDirectory ? 'folders' : 'files')];
  }
  private async children(server: ServerConfig, path: string): Promise<MediaItem[]> {
    const gen = this.generation;
    const result: LocalDirectoryEntry[] = await LocalAccess.withRoot<LocalDirectoryEntry[]>(this.root(server), (fd: number): Promise<LocalDirectoryEntry[]> => localNative.list(fd, LocalAccess.relative(path)));
    if (gen !== this.generation) { throw new Error('本地目录读取已取消'); }
    return result.map((entry: LocalDirectoryEntry) => this.item(server, path.length > 0 ? path + '/' + entry.name : entry.name, entry))
      .sort((a: MediaItem, b: MediaItem) => a.isFolder() !== b.isFolder() ? (a.isFolder() ? -1 : 1) : a.name.localeCompare(b.name));
  }
  private async collect(server: ServerConfig, root: string): Promise<MediaItem[]> {
    const queue: string[] = [root]; const items: MediaItem[] = []; let dirs = 0;
    while (queue.length > 0) {
      if (++dirs > 128) { throw new Error('本地目录超过递归上限，请进入子目录浏览'); }
      const path = queue.shift(); if (path === undefined) { break; }
      const children = await this.children(server, path);
      for (let i = 0; i < children.length; i++) {
        if (children[i].isFolder()) { queue.push(children[i].path); } else if (children[i].isPlayable()) { items.push(children[i]); }
        if (items.length > 5000) { throw new Error('本地文件超过递归上限，请进入子目录浏览'); }
      }
    }
    return items;
  }
  async getItems(server: ServerConfig, parent: string, start: number, limit: number, recursive: boolean): Promise<MediaItem[]> {
    if (!Number.isInteger(start) || start < 0 || !Number.isInteger(limit) || limit < 1 || limit > 5000) { throw new Error('本地分页范围无效'); }
    const path = this.path(parent); const info = await this.stat(server, path);
    const list = !info.isDirectory ? [this.item(server, path, info)] : recursive ? await this.collect(server, path) : await this.children(server, path);
    return this.remember(server, list.slice(start, start + limit));
  }
  async getLatest(server: ServerConfig, parent: string, limit: number): Promise<MediaItem[]> {
    const rows = await this.getItems(server, parent, 0, 5000, true);
    return rows.sort((a: MediaItem, b: MediaItem) => Date.parse(b.modifiedAt) - Date.parse(a.modifiedAt)).slice(0, limit);
  }
  async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const path = this.path(id); const stat = await this.stat(server, path); const detail = new ItemDetail(); detail.item = this.item(server, path, stat);
    detail.item.isFavorite = await this.isFavorite(server, id); detail.item.favoriteKnown = true; this.remember(server, [detail.item]);
    if (detail.item.isPlayable()) { const source = new MediaSource(); source.id = id; source.container = detail.item.container; source.sizeBytes = stat.size; detail.sources = [source]; }
    return detail;
  }
  async search(server: ServerConfig, query: string, limit: number): Promise<MediaItem[]> {
    if (query.trim().length === 0) { return []; }
    const items = await this.getItems(server, '', 0, 5000, true);
    return items.filter((item: MediaItem) => item.name.toLowerCase().indexOf(query.trim().toLowerCase()) >= 0).slice(0, limit);
  }
}
