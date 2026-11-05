import { ServerConfig, Library, MediaItem, ItemDetail, MediaSource, MediaStream, PlaybackInfo } from '../Models';
import { DirectCatalogBase } from './DirectCatalogBase';
import { SourceIdentity } from './SourceIdentity';
import { DirectSourceHttp } from './DirectSourceHttp';

export class CloudFile {
  id: string = '';
  name: string = '';
  directory: boolean = false;
  size: number = 0;
  path: string = '';
  thumbnail: string = '';
  created: string = '';
  modified: string = '';
  video: boolean = false;
  container: string = '';
  runtimeTicks: number = 0;
  streams: MediaStream[] = [];
}
export class CloudPage { files: CloudFile[] = []; complete: boolean = false; next: number = 0; total: number = -1; }
class CloudFolderCache { files: CloudFile[] = []; loaded: number = 0; }
class CloudWalk { id: string = ''; depth: number = 0; constructor(id: string, depth: number) { this.id = id; this.depth = depth; } }
class CloudLink { info: PlaybackInfo = new PlaybackInfo(); created: number = 0; }

/** Protocol-specific subclasses supply all network calls; common browsing never borrows Emby routes. */
export abstract class CloudCatalogBase extends DirectCatalogBase {
  private static folders: Map<string, CloudFolderCache> = new Map();
  private static links: Map<string, CloudLink> = new Map();
  abstract login(server: ServerConfig, password: string): Promise<ServerConfig>;
  protected abstract rootId(server: ServerConfig): string;
  protected abstract listPage(server: ServerConfig, parent: string, start: number, limit: number): Promise<CloudPage>;
  protected abstract readFile(server: ServerConfig, id: string): Promise<CloudFile>;
  protected abstract resolveFile(server: ServerConfig, file: CloudFile): Promise<PlaybackInfo>;
  protected keyFor(server: ServerConfig, id: string): string { return SourceIdentity.scope(server) + '|' + id; }
  private convert(file: CloudFile): MediaItem | null {
    if (!file.directory && !file.video && !/^(mkv|mp4|m4v|mov|avi|webm|ts|m2ts|mts|mpg|mpeg|wmv|flv|vob|m3u8|ogv)$/i.test(file.container)) { return null; }
    if (file.id.length === 0 || file.name.length === 0) { throw new Error('云端目录含无效的文件标识或标题'); }
    const item = new MediaItem(); item.id = file.id; item.name = file.name; item.path = file.path;
    item.type = file.directory ? 'Folder' : 'Video'; item.container = file.container; item.runtimeTicks = file.runtimeTicks;
    item.createdAt = file.created; item.modifiedAt = file.modified; item.imageTag = file.thumbnail; item.hasPrimaryImage = file.thumbnail.length > 0; return item;
  }
  protected async folder(server: ServerConfig, parent: string): Promise<CloudFile[]> {
    const key = this.keyFor(server, parent); const existing = CloudCatalogBase.folders.get(key);
    if (existing !== undefined && Date.now() - existing.loaded < 30000) { return existing.files; }
    const result: CloudFile[] = []; const seen: Set<string> = new Set(); let start = 0; let total = -1;
    for (let request = 0; request < 50; request++) {
      const page = await this.listPage(server, parent, start, 200);
      if (page.total >= 0) {
        if (!Number.isSafeInteger(page.total) || (total >= 0 && total !== page.total)) { throw new Error('云端目录在分页期间改变，请重试'); } total = page.total;
      }
      for (let i = 0; i < page.files.length; i++) {
        if (seen.has(page.files[i].id)) { throw new Error('云端目录分页重复，请重试'); }
        seen.add(page.files[i].id); result.push(page.files[i]);
      }
      if (result.length > 5000) { throw new Error('云端目录超过 5000 项，请选择更小的根目录'); }
      if (total >= 0 && result.length > total) { throw new Error('云端目录条目超过响应总数'); }
      if (page.complete || (total >= 0 && result.length === total)) {
        if (total >= 0 && result.length !== total) { throw new Error('云端目录提前结束，未返回完整内容'); }
        const cached = new CloudFolderCache(); cached.files = result; cached.loaded = Date.now();
        CloudCatalogBase.folders.delete(key); CloudCatalogBase.folders.set(key, cached);
        let cachedCount = 0; CloudCatalogBase.folders.forEach((entry: CloudFolderCache) => { cachedCount += entry.files.length; });
        while (CloudCatalogBase.folders.size > 16 || cachedCount > 20000) {
          let first = ''; CloudCatalogBase.folders.forEach((_entry: CloudFolderCache, id: string) => { if (first.length === 0) { first = id; } });
          const removed = CloudCatalogBase.folders.get(first); if (removed !== undefined) { cachedCount -= removed.files.length; } CloudCatalogBase.folders.delete(first);
        }
        return result;
      }
      if (page.files.length === 0 || !Number.isSafeInteger(page.next) || page.next <= start) { throw new Error('云端目录分页未前进，已停止读取'); }
      start = page.next;
    }
    throw new Error('云端目录分页超过上限，请缩小目录');
  }
  private async walk(server: ServerConfig, parent: string, recursive: boolean): Promise<CloudFile[]> {
    if (!recursive) { return this.folder(server, parent); }
    const pending: CloudWalk[] = [new CloudWalk(parent, 0)]; const visited: Set<string> = new Set(); const files: CloudFile[] = [];
    while (pending.length > 0) {
      const current = pending.shift() as CloudWalk;
      if (visited.has(current.id) || current.depth > 8 || visited.size >= 64) { throw new Error('云端递归目录循环或超过上限，请缩小根目录'); }
      visited.add(current.id); const entries = await this.folder(server, current.id);
      entries.forEach((entry: CloudFile) => { if (entry.directory) { pending.push(new CloudWalk(entry.id, current.depth + 1)); } else { files.push(entry); } });
      if (files.length > 5000) { throw new Error('云端递归内容超过 5000 项，请选择更小的根目录'); }
    }
    return files;
  }
  async getViews(server: ServerConfig): Promise<Library[]> {
    await this.folder(server, this.rootId(server));
    return [new Library(this.rootId(server), server.name.length > 0 ? server.name : '云端文件', 'folders')];
  }
  async getItems(server: ServerConfig, parent: string, start: number, limit: number, recursive: boolean): Promise<MediaItem[]> {
    if (!Number.isSafeInteger(start) || start < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 5000) { throw new Error('云端目录分页范围无效'); }
    const converted: MediaItem[] = [];
    (await this.walk(server, parent, recursive)).forEach((file: CloudFile) => { const item = this.convert(file); if (item !== null) { converted.push(item); } });
    return this.remember(server, converted.slice(start, start + limit));
  }
  async getLatest(server: ServerConfig, parent: string, limit: number): Promise<MediaItem[]> {
    const files = (await this.walk(server, parent, true)).sort((a: CloudFile, b: CloudFile) => (b.modified || b.created).localeCompare(a.modified || a.created));
    const result: MediaItem[] = []; files.forEach((file: CloudFile) => { const item = this.convert(file); if (item !== null && result.length < limit) { result.push(item); } });
    return this.remember(server, result);
  }
  async search(server: ServerConfig, query: string, limit: number): Promise<MediaItem[]> {
    const needle = query.trim().toLowerCase(); if (needle.length === 0) { return []; }
    const result: MediaItem[] = [];
    (await this.walk(server, this.rootId(server), true)).forEach((file: CloudFile) => { if (file.name.toLowerCase().indexOf(needle) >= 0 && result.length < limit) { const item = this.convert(file); if (item !== null) { result.push(item); } } });
    return this.remember(server, result);
  }
  async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const file = await this.readFile(server, id); const item = this.convert(file);
    if (item === null) { throw new Error('此云端文件不是可播放的视频'); }
    const detail = new ItemDetail(); detail.item = item;
    if (!file.directory) { const source = new MediaSource(); source.id = file.id; source.sizeBytes = file.size; source.container = file.container; source.streams = file.streams; detail.sources = [source]; }
    this.remember(server, [item]); return detail;
  }
  async playback(server: ServerConfig, id: string, selected: string): Promise<PlaybackInfo> {
    if (selected.length > 0 && selected !== id) { throw new Error('云端视频源标识不匹配'); }
    const file = await this.readFile(server, id);
    if (file.directory || this.convert(file) === null) { throw new Error('云端条目不是可播放的视频文件'); }
    const info = await this.resolveFile(server, file); info.url = DirectSourceHttp.resolve(info.url, info.url); info.mediaSourceId = file.id;
    const link = new CloudLink(); link.info = info; link.created = Date.now(); const key = this.keyFor(server, id);
    CloudCatalogBase.links.delete(key); CloudCatalogBase.links.set(key, link);
    if (CloudCatalogBase.links.size > 64) { let first = ''; CloudCatalogBase.links.forEach((_link: CloudLink, id: string) => { if (first.length === 0) { first = id; } }); CloudCatalogBase.links.delete(first); }
    const item = this.convert(file); if (item !== null) { this.remember(server, [item]); } return info;
  }
  stream(server: ServerConfig, id: string): string {
    const link = CloudCatalogBase.links.get(this.keyFor(server, id));
    if (link === undefined || Date.now() - link.created > 30000) { throw new Error('请先解析云端实时播放地址'); } return link.info.url;
  }
  imageUrl(_server: ServerConfig, _id: string, _width: number, tag: string): string { return tag.length > 0 ? DirectSourceHttp.resolve(tag, tag) : ''; }
}
