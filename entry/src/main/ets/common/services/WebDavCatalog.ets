import { url } from '@kit.ArkTS';
import { ServerConfig, Library, MediaItem, ItemDetail, MediaSource, PlaybackInfo } from '../Models';
import { MediaCatalog } from './MediaCatalog';
import { DirectCatalogBase } from './DirectCatalogBase';
import { DirectSourceHttp } from './DirectSourceHttp';
import { SourceXml, SourceXmlNode } from './SourceXml';

class DavEntry {
  address: string = '';
  name: string = '';
  directory: boolean = false;
  size: number = 0;
  modified: string = '';
  contentType: string = '';
}
class DavWalk { address: string = ''; depth: number = 0; constructor(address: string, depth: number) { this.address = address; this.depth = depth; } }

/** RFC 4918 client. PROPFIND is sent as an actual RCP custom HTTP method. */
export class WebDavCatalog extends DirectCatalogBase implements MediaCatalog {
  private transport: DirectSourceHttp = new DirectSourceHttp();
  cancel(): void { this.transport.cancel(); }
  headers(server: ServerConfig): Record<string, string> {
    const headers: Record<string, string> = {};
    if (server.authMode !== 'anonymous') {
      if (!/^Basic [A-Za-z0-9+/]+=*$/.test(server.token)) { throw new Error('WebDAV 认证未配置，请重新验证连接'); }
      headers['Authorization'] = server.token;
    }
    return headers;
  }
  private checkRawPath(value: string): void {
    if (/[\\\u0000-\u0020]/.test(value)) { throw new Error('WebDAV 返回了不安全的资源路径'); }
    const path = value.replace(/^https?:\/\/[^/]+/i, '').split(/[?#]/)[0];
    const segments = path.split('/');
    for (let i = 0; i < segments.length; i++) {
      let segment = segments[i];
      for (let round = 0; round < 3; round++) {
        try { segment = decodeURIComponent(segment); } catch (e) { throw new Error('WebDAV 路径编码无效'); }
        if (segment === '.' || segment === '..' || /[\/\\\u0000-\u001f]/.test(segment)) { throw new Error('WebDAV 返回了不安全的资源路径'); }
        if (segment.indexOf('%') < 0) { break; }
      }
    }
  }
  root(server: ServerConfig): string {
    const path = server.rootPath.length > 0 ? server.rootPath : '/';
    this.checkRawPath(path);
    if (!path.startsWith('/') || /[?#]/.test(path)) { throw new Error('WebDAV 根目录必须是绝对路径'); }
    const base = server.baseUrl().replace(/\/+$/, '');
    return DirectSourceHttp.resolve(base + '/', base + (path === '/' ? '/' : path.replace(/\/+$/, '') + '/'));
  }
  private resource(server: ServerConfig, href: string, base: string): string {
    this.checkRawPath(href);
    const address = DirectSourceHttp.resolve(base, href);
    const parsed = new url.URL(address); const root = new url.URL(this.root(server));
    if (parsed.search.length > 0 || !DirectSourceHttp.sameOrigin(address, root.toString())) { throw new Error('WebDAV 资源不在当前服务器目录中'); }
    const path = decodeURIComponent(parsed.pathname); const allowed = decodeURIComponent(root.pathname);
    if (path !== allowed.replace(/\/$/, '') && !path.startsWith(allowed)) { throw new Error('WebDAV 资源越出了授权根目录'); }
    return address;
  }
  /** Persist only a canonical encoded path. Origin and authentication remain in the saved source. */
  private id(address: string): string { return 'dav:' + encodeURIComponent(new url.URL(address).pathname); }
  private address(server: ServerConfig, id: string): string {
    if (!id.startsWith('dav:')) { throw new Error('WebDAV 文件标识无效，请重新读取目录'); }
    let path = '';
    try { path = decodeURIComponent(id.substring(4)); } catch (e) { throw new Error('WebDAV 文件标识编码无效'); }
    if (!path.startsWith('/') || path.startsWith('//') || /[?#]/.test(path)
      || id !== 'dav:' + encodeURIComponent(path)) { throw new Error('WebDAV 文件标识无效'); }
    const root = this.root(server);
    return this.resource(server, new url.URL(root).origin + path, root);
  }
  private async entries(server: ServerConfig, address: string, depth: string): Promise<DavEntry[]> {
    address = this.resource(server, address, this.root(server));
    const headers = this.headers(server); headers['Depth'] = depth; headers['Content-Type'] = 'application/xml; charset=utf-8';
    const body = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getcontenttype/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>';
    const response = await this.transport.request(address, 'PROPFIND', headers, body);
    if (response.status !== 207) { throw new Error('WebDAV 目录读取失败（HTTP ' + response.status.toString() + '）'); }
    const root = SourceXml.parse(response.text);
    if (root.local !== 'multistatus' || root.namespace !== 'DAV:') { throw new Error('不是有效的 WebDAV 多状态响应'); }
    const result: DavEntry[] = []; const seen: string[] = [];
    const responses = root.all('response', 'DAV:');
    if (responses.length > 5001) { throw new Error('WebDAV 单目录超过 5000 项，请选择更小的根目录'); }
    responses.forEach((node: SourceXmlNode) => {
      const href = node.field('href', 'DAV:');
      if (href.length === 0) { throw new Error('WebDAV 响应缺少资源地址'); }
      const item = new DavEntry(); item.address = this.resource(server, href, response.address);
      if (seen.indexOf(item.address) >= 0) { throw new Error('WebDAV 目录含重复资源'); } seen.push(item.address);
      const status = node.field('status', 'DAV:');
      if (status.length > 0 && !/^HTTP\/\S+ 2\d\d(?: |$)/.test(status)) { throw new Error('WebDAV 部分资源不可访问，请检查目录权限'); }
      let valid = false;
      node.all('propstat', 'DAV:').forEach((state: SourceXmlNode) => {
        if (!/^HTTP\/\S+ 2\d\d(?: |$)/.test(state.field('status', 'DAV:'))) { return; }
        const prop = state.first('prop', 'DAV:'); if (prop === undefined) { return; } valid = true;
        const type = prop.first('resourcetype', 'DAV:');
        if (type !== undefined) { item.directory = type.first('collection', 'DAV:') !== undefined; }
        const name = prop.field('displayname', 'DAV:'); if (name.length > 0) { item.name = name; }
        const size = prop.field('getcontentlength', 'DAV:');
        if (size.length > 0) { if (!/^\d+$/.test(size) || !Number.isSafeInteger(Number(size))) { throw new Error('WebDAV 文件大小无效'); } item.size = Number(size); }
        item.contentType = prop.field('getcontenttype', 'DAV:');
        const modified = prop.field('getlastmodified', 'DAV:');
        if (modified.length > 0 && Number.isFinite(Date.parse(modified))) { item.modified = new Date(modified).toISOString(); }
      });
      if (!valid) { throw new Error('WebDAV 资源属性不可访问'); }
      if (item.name.length === 0) { const pieces = new url.URL(item.address).pathname.replace(/\/$/, '').split('/'); item.name = decodeURIComponent(pieces[pieces.length - 1]); }
      if (item.directory && !item.address.endsWith('/')) { item.address += '/'; }
      result.push(item);
    });
    const self = address.replace(/\/$/, '');
    if (!result.some((entry: DavEntry) => entry.address.replace(/\/$/, '') === self)) { throw new Error('WebDAV 响应缺少请求目录自身，未确认完整结果'); }
    return result;
  }
  private item(entry: DavEntry): MediaItem | undefined {
    const extension = DirectSourceHttp.extension(entry.address);
    if (!entry.directory && !/^(mkv|mp4|m4v|mov|avi|webm|ts|m2ts|mts|mpg|mpeg|wmv|flv|vob|m3u8|ogv)$/.test(extension)
      && !entry.contentType.toLowerCase().startsWith('video/')) { return undefined; }
    const item = new MediaItem(); item.id = this.id(entry.address); item.path = new url.URL(entry.address).pathname; item.name = entry.name;
    item.type = entry.directory ? 'Folder' : 'Video'; item.container = extension; item.createdAt = entry.modified; return item;
  }
  async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    if (server.authMode === 'anonymous') { server.token = ''; }
    else if (password.length > 0 || server.token.length === 0) { server.token = DirectSourceHttp.basic(server.username, password); }
    const entries = await this.entries(server, this.root(server), '1');
    const self = entries.find((entry: DavEntry) => entry.address.replace(/\/$/, '') === this.root(server).replace(/\/$/, ''));
    if (self === undefined || !self.directory) { throw new Error('WebDAV 根路径不是可浏览的目录'); }
    server.serverName = self.name.length > 0 ? self.name : server.name; return server;
  }
  async getViews(server: ServerConfig): Promise<Library[]> {
    const entries = await this.entries(server, this.root(server), '0'); const self = entries[0];
    if (self === undefined || !self.directory) { throw new Error('WebDAV 根目录不可用'); }
    return [new Library(this.id(this.root(server)), self.name.length > 0 ? self.name : server.name, 'folders')];
  }
  private async list(server: ServerConfig, parent: string, recursive: boolean): Promise<MediaItem[]> {
    const origin = this.address(server, parent); const pending: DavWalk[] = [new DavWalk(origin, 0)];
    const seen: string[] = []; const items: MediaItem[] = [];
    while (pending.length > 0) {
      const current = pending.shift() as DavWalk;
      if (seen.indexOf(current.address) >= 0) { throw new Error('WebDAV 目录循环，已停止读取'); } seen.push(current.address);
      if (seen.length > 128 || current.depth > 8) { throw new Error('WebDAV 递归目录超过上限，请选择更小的根目录'); }
      const entries = await this.entries(server, current.address, '1');
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i]; if (entry.address.replace(/\/$/, '') === current.address.replace(/\/$/, '')) { continue; }
        const currentPath = new url.URL(current.address).pathname.replace(/\/?$/, '/');
        const entryPath = new url.URL(entry.address).pathname;
        if (!entryPath.startsWith(currentPath)) { throw new Error('WebDAV Depth 1 返回了当前目录以外的资源'); }
        const relative = entryPath.substring(currentPath.length).replace(/\/$/, '');
        if (relative.indexOf('/') >= 0 || relative.length === 0) { throw new Error('WebDAV Depth 1 返回了非直属目录资源'); }
        if (recursive && entry.directory) { pending.push(new DavWalk(entry.address, current.depth + 1)); }
        else { const item = this.item(entry); if (item !== undefined) { items.push(item); } }
        if (items.length > 5000) { throw new Error('WebDAV 内容超过 5000 项，请选择更小的根目录'); }
      }
    }
    return this.remember(server, items);
  }
  async getItems(server: ServerConfig, parent: string, start: number, limit: number, recursive: boolean): Promise<MediaItem[]> {
    if (!Number.isInteger(start) || start < 0 || !Number.isInteger(limit) || limit < 1 || limit > 5000) { throw new Error('WebDAV 分页范围无效'); }
    return (await this.list(server, parent, recursive)).slice(start, start + limit);
  }
  async getLatest(server: ServerConfig, parent: string, limit: number): Promise<MediaItem[]> {
    return (await this.list(server, parent, true)).sort((a: MediaItem, b: MediaItem) => b.createdAt.localeCompare(a.createdAt)).slice(0, limit);
  }
  async search(server: ServerConfig, query: string, limit: number): Promise<MediaItem[]> {
    const needle = query.trim().toLowerCase(); if (needle.length === 0) { return []; }
    return (await this.list(server, this.id(this.root(server)), true)).filter((item: MediaItem) => item.name.toLowerCase().indexOf(needle) >= 0).slice(0, limit);
  }
  async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const address = this.address(server, id); const entries = await this.entries(server, address, '0');
    const entry = entries.find((value: DavEntry) => value.address.replace(/\/$/, '') === address.replace(/\/$/, ''));
    if (entry === undefined) { throw new Error('WebDAV 文件已不存在'); }
    const item = this.item(entry); if (item === undefined) { throw new Error('此 WebDAV 文件不是支持的视频来源'); }
    const detail = new ItemDetail(); detail.item = item;
    if (!entry.directory) { const source = new MediaSource(); source.id = item.id; source.container = item.container; source.sizeBytes = entry.size; detail.sources = [source]; }
    this.remember(server, [item]); return detail;
  }
  async playback(server: ServerConfig, id: string, selected: string): Promise<PlaybackInfo> {
    const detail = await this.getItemDetail(server, id);
    if (detail.sources.length !== 1 || (selected.length > 0 && selected !== detail.sources[0].id)) { throw new Error('WebDAV 视频源不可用'); }
    const info = new PlaybackInfo(); info.url = this.address(server, detail.sources[0].id);
    info.mediaSourceId = detail.sources[0].id; info.headers = this.headers(server); info.isHls = DirectSourceHttp.extension(info.url) === 'm3u8'; return info;
  }
  stream(server: ServerConfig, id: string): string { return this.address(server, id); }
}
