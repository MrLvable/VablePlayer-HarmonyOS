import { url } from '@kit.ArkTS';
import { ServerConfig, PlaybackInfo } from '../Models';
import { CloudCatalogBase, CloudFile, CloudPage } from './CloudCatalogBase';
import { DirectSourceHttp } from './DirectSourceHttp';
import { SourceJson } from './SourceJson';
import { BaiduAuthorization } from './BaiduAuthorization';

interface BaiduFile {
  fs_id?: string | number; path?: string; filename?: string; server_filename?: string; isdir?: number;
  size?: number | string; category?: number; server_ctime?: number; server_mtime?: number; duration?: number;
  dlink?: string; errno?: number; isdelete?: number;
}
interface BaiduReply { errno?: number; list?: BaiduFile[]; data?: BaiduReply; }

export class BaiduCatalog extends CloudCatalogBase {
  private transport: DirectSourceHttp = new DirectSourceHttp();
  private generation: number = 0;
  cancel(): void { this.generation++; this.transport.cancel(); }
  private path(server: ServerConfig, value: string): string {
    if (!value.startsWith('/') || /[\\\u0000-\u001f]/.test(value) || value.split('/').some((piece: string) => piece === '.' || piece === '..')) { throw new Error('百度网盘路径无效'); }
    const root = server.rootPath.replace(/\/$/, '') || '/'; const path = value.replace(/\/$/, '') || '/';
    if (root !== '/' && path !== root && !path.startsWith(root + '/')) { throw new Error('百度网盘文件超出了配置目录'); } return path;
  }
  protected rootId(server: ServerConfig): string { return 'baidu:root:' + encodeURIComponent(this.path(server, server.rootPath.length > 0 ? server.rootPath : '/')); }
  private async request(server: ServerConfig, route: string, refresh: boolean = true): Promise<BaiduReply> {
    if (server.token.length === 0) { throw new Error('请先取得百度用户授权或导入有效 access_token'); }
    const gen = this.generation;
    const response = await this.transport.request('https://pan.baidu.com/rest/2.0/xpan/' + route + '&access_token=' + encodeURIComponent(server.token), 'GET', { 'User-Agent': 'pan.baidu.com' });
    let data: BaiduReply; try { data = JSON.parse(SourceJson.preserveIntegers(response.text)) as BaiduReply; } catch (e) { throw new Error('百度网盘响应格式无效'); }
    if ((data.errno === 110 || data.errno === 111 || response.status === 401) && refresh && server.refreshToken.length > 0) { await BaiduAuthorization.refresh(server); if (gen !== this.generation) { throw new Error('百度来源请求已取消'); } return this.request(server, route, false); }
    if (response.status !== 200 || data.errno !== 0 || (data.data !== undefined && data.data.errno !== undefined && data.data.errno !== 0)) {
      throw new Error('百度网盘请求失败（HTTP ' + response.status.toString() + '，业务码 ' + (data.errno !== undefined ? data.errno.toString() : '缺失') + '），请核对授权范围和应用目录权限');
    }
    return data.data !== undefined && data.data.list !== undefined ? data.data : data;
  }
  private file(server: ServerConfig, raw: BaiduFile): CloudFile {
    if ((raw.errno !== undefined && raw.errno !== 0) || raw.isdelete === 1) { throw new Error('百度网盘文件不可访问或已删除'); }
    const file = new CloudFile(); file.id = SourceJson.id(raw.fs_id);
    if (typeof raw.path !== 'string' || (raw.isdir !== 0 && raw.isdir !== 1)) { throw new Error('百度网盘文件缺少路径或类型'); }
    file.path = this.path(server, raw.path); file.directory = raw.isdir === 1;
    file.name = typeof raw.server_filename === 'string' ? raw.server_filename : typeof raw.filename === 'string' ? raw.filename : '';
    if (file.name.length === 0) { const pieces = file.path.split('/'); file.name = pieces[pieces.length - 1]; }
    file.size = raw.size !== undefined ? Number(raw.size) : 0; if (!Number.isSafeInteger(file.size) || file.size < 0) { throw new Error('百度网盘文件大小超出可表示范围'); }
    const extension = /\.([A-Za-z0-9]+)$/.exec(file.name); file.container = extension === null ? '' : extension[1].toLowerCase(); file.video = raw.category === 1;
    if (raw.server_ctime !== undefined && raw.server_ctime > 0) { file.created = new Date(raw.server_ctime * 1000).toISOString(); }
    if (raw.server_mtime !== undefined && raw.server_mtime > 0) { file.modified = new Date(raw.server_mtime * 1000).toISOString(); }
    if (raw.duration !== undefined && Number.isFinite(raw.duration) && raw.duration > 0) { file.runtimeTicks = Math.round(raw.duration * 10000000); } return file;
  }
  async login(server: ServerConfig, token: string): Promise<ServerConfig> {
    if (token.trim().length > 0) { server.token = token.trim().replace(/^Bearer\s+/i, ''); }
    await this.listPage(server, this.rootId(server), 0, 1); server.serverName = server.name.length > 0 ? server.name : '百度网盘'; return server;
  }
  protected async listPage(server: ServerConfig, parent: string, start: number, limit: number): Promise<CloudPage> {
    const directory = parent.startsWith('baidu:root:') ? this.path(server, decodeURIComponent(parent.substring(11))) : (await this.readFile(server, parent)).path;
    const data = await this.request(server, 'file?method=list&dir=' + encodeURIComponent(directory) + '&start=' + start.toString() + '&limit=' + limit.toString() + '&order=name&folder=0');
    if (!Array.isArray(data.list)) { throw new Error('百度目录响应缺少 list，未确认空目录'); }
    const page = new CloudPage(); page.files = data.list.map((raw: BaiduFile) => this.file(server, raw)); page.next = start + page.files.length; page.complete = page.files.length < limit; return page;
  }
  private async metadata(server: ServerConfig, id: string, download: boolean): Promise<BaiduFile> {
    if (!/^\d+$/.test(id)) { throw new Error('百度网盘文件标识无效'); }
    // Numeric JSON is assembled from already validated decimal text; uint64 is never rounded.
    const data = await this.request(server, 'multimedia?method=filemetas&fsids=' + encodeURIComponent('[' + id + ']') + '&dlink=' + (download ? '1' : '0') + '&needmedia=1');
    if (!Array.isArray(data.list) || data.list.length !== 1 || SourceJson.id(data.list[0].fs_id) !== id) { throw new Error('百度文件详细信息不匹配'); } return data.list[0];
  }
  protected async readFile(server: ServerConfig, id: string): Promise<CloudFile> { return this.file(server, await this.metadata(server, id, false)); }
  protected async resolveFile(server: ServerConfig, file: CloudFile): Promise<PlaybackInfo> {
    const raw = await this.metadata(server, file.id, true); this.file(server, raw);
    if (typeof raw.dlink !== 'string' || raw.dlink.length === 0) { throw new Error('百度未授予此文件的下载权限，请检查应用目录、审核状态或账号权益'); }
    const address = new url.URL(DirectSourceHttp.resolve(raw.dlink, raw.dlink)); address.searchParams.set('access_token', server.token);
    const info = new PlaybackInfo(); info.url = address.toString(); info.headers = { 'User-Agent': 'pan.baidu.com' }; info.isHls = DirectSourceHttp.extension(info.url) === 'm3u8'; return info;
  }
  imageHeaders(_server: ServerConfig): Record<string, string> { return { 'User-Agent': 'pan.baidu.com' }; }
}
