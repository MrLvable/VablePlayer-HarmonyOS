import { ServerConfig, Library, MediaItem, ItemDetail, MediaSource } from '../Models';
import { SmbDirectoryEntry, SmbFileStat } from 'libnas_smb.so';
import { MediaCatalog } from './MediaCatalog';
import { DirectCatalogBase } from './DirectCatalogBase';
import { SmbNative } from './SmbNative';

/** Read-only file catalog. No invented Series/Episode indices, posters or remote favorites. */
export class SmbCatalog extends DirectCatalogBase implements MediaCatalog {
  private video(name: string): boolean { return /\.(mkv|mp4|m4v|mov|webm|avi|ts|m2ts|mpg|mpeg|flv|wmv)$/i.test(name); }
  private item(path: string, stat: SmbFileStat): MediaItem {
    const result = new MediaItem(); result.id = SmbNative.id(path); result.path = path;
    result.name = path.substring(path.lastIndexOf('/') + 1); if (result.name.length === 0) { result.name = '/'; }
    result.type = stat.isDirectory ? 'Folder' : this.video(result.name) ? 'Video' : 'File';
    if (Number.isFinite(stat.modifiedTime) && Math.abs(stat.modifiedTime) <= 8640000000000000) { result.modifiedAt = new Date(stat.modifiedTime).toISOString(); }
    if (!stat.isDirectory && result.name.indexOf('.') >= 0) { result.container = result.name.substring(result.name.lastIndexOf('.') + 1).toLowerCase(); }
    return result;
  }
  async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    if (password.length > 0) { server.password = password; }
    const root = SmbNative.fromId(server, ''); const info = await SmbNative.stat(server, root);
    if (!info.isDirectory) { throw new Error('SMB 根路径不是目录'); }
    await SmbNative.list(server, root);
    server.serverName = server.name.length > 0 ? server.name : server.shareName;
    return server;
  }
  async getViews(server: ServerConfig): Promise<Library[]> {
    const root = SmbNative.fromId(server, ''); const info = await SmbNative.stat(server, root);
    if (!info.isDirectory) { throw new Error('SMB 根路径不是目录'); }
    return [new Library(SmbNative.id(root), server.shareName, 'folders')];
  }
  private async children(server: ServerConfig, path: string): Promise<MediaItem[]> {
    const raw = await SmbNative.list(server, path); const result: MediaItem[] = [];
    raw.forEach((entry: SmbDirectoryEntry) => {
      if (entry.type !== 0 && entry.type !== 1) { return; }
      const child = SmbNative.path((path === '/' ? '' : path) + '/' + entry.name);
      const item = this.item(child, entry); result.push(item);
    });
    result.sort((a: MediaItem, b: MediaItem) => a.isFolder() !== b.isFolder() ? (a.isFolder() ? -1 : 1) : a.name.localeCompare(b.name));
    return result;
  }
  private async collect(server: ServerConfig, root: string, maximum: number): Promise<MediaItem[]> {
    const queue: string[] = [root]; const out: MediaItem[] = []; let directories = 0;
    while (queue.length > 0) {
      if (++directories > 128) { throw new Error('SMB 递归目录过多，请进入子目录浏览'); }
      const path = queue.shift(); if (path === undefined) { break; }
      const rows = await this.children(server, path);
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].isFolder()) { queue.push(rows[i].path); }
        else if (rows[i].isPlayable()) { out.push(rows[i]); }
        if (out.length > maximum) { throw new Error('SMB 递归文件过多，请进入子目录浏览'); }
      }
    }
    return out;
  }
  async getItems(server: ServerConfig, parent: string, start: number, limit: number, recursive: boolean): Promise<MediaItem[]> {
    if (!Number.isInteger(start) || start < 0 || !Number.isInteger(limit) || limit < 1 || limit > 5000) { throw new Error('SMB 分页范围无效'); }
    const path = SmbNative.fromId(server, parent);
    const rows = recursive ? await this.collect(server, path, 5000) : await this.children(server, path);
    return this.remember(server, rows.slice(start, start + limit));
  }
  getLatest(_server: ServerConfig, _parent: string, _limit: number): Promise<MediaItem[]> {
    return Promise.reject(this.unsupported('影视“最新”元数据，请从真实文件目录浏览'));
  }
  async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const path = SmbNative.fromId(server, id); const raw = await SmbNative.stat(server, path);
    const detail = new ItemDetail(); detail.item = this.item(path, raw);
    detail.item.isFavorite = await this.isFavorite(server, id); detail.item.favoriteKnown = true;
    this.remember(server, [detail.item]);
    if (raw.type === 0 && detail.item.isPlayable()) {
      const source = new MediaSource(); source.id = id; source.container = detail.item.container; source.sizeBytes = raw.size;
      detail.sources = [source];
    }
    return detail;
  }
  async search(server: ServerConfig, query: string, limit: number): Promise<MediaItem[]> {
    if (query.trim().length === 0) { return []; }
    if (!Number.isInteger(limit) || limit < 1 || limit > 5000) { throw new Error('SMB 搜索范围无效'); }
    const rows = await this.collect(server, SmbNative.fromId(server, ''), 5000);
    return this.remember(server, rows.filter((row: MediaItem) => row.name.toLowerCase().indexOf(query.trim().toLowerCase()) >= 0).slice(0, limit));
  }
}
