import { ServerConfig, PlaybackInfo } from '../Models';
import { CloudCatalogBase, CloudFile, CloudPage } from './CloudCatalogBase';
import { DirectSourceHttp } from './DirectSourceHttp';
import { SourceJson } from './SourceJson';
import { GuangyaAuthorization } from './GuangyaAuthorization';

interface GuangyaFile { fileId?: string; fileName?: string; fileSize?: number | string; resType?: number; fileType?: number; mineType?: string; ext?: string; ctime?: number; utime?: number; thumbnail?: string; }
interface GuangyaData { total?: number; list?: GuangyaFile[]; fileInfo?: GuangyaFile; signedURL?: string; urlDuration?: number; userId?: string; nickName?: string; }
interface GuangyaReply { code?: number; data?: GuangyaData; }

export class GuangyaCatalog extends CloudCatalogBase {
  private transport: DirectSourceHttp = new DirectSourceHttp();
  private generation: number = 0;
  private static nextRequest: number = 0;
  cancel(): void { this.generation++; this.transport.cancel(); }
  protected rootId(server: ServerConfig): string { return server.rootPath === '/' || server.rootPath.length === 0 ? 'guangya:root' : server.rootPath; }
  private async request(server: ServerConfig, route: string, refresh: boolean = true): Promise<GuangyaData> {
    if (server.token.length === 0 || server.clientId.length === 0) { throw new Error('光鸭直连需要 client_id 与已授权用户 access_token'); }
    const gen = this.generation; const wait = Math.max(0, GuangyaCatalog.nextRequest - Date.now());
    if (wait > 5000) { throw new Error('光鸭请求过多，请稍后重试'); } GuangyaCatalog.nextRequest = Date.now() + wait + 500;
    if (wait > 0) { await new Promise<void>((resolve: () => void) => { setTimeout(resolve, wait); }); }
    if (gen !== this.generation) { throw new Error('光鸭请求已取消'); }
    const response = await this.transport.request('https://openapi.guangyapan.com/openapi/v1/' + route, 'GET', { 'x-client-id': server.clientId, 'Authorization': 'Bearer ' + server.token });
    let data: GuangyaReply; try { data = JSON.parse(SourceJson.preserveIntegers(response.text)) as GuangyaReply; } catch (e) { throw new Error('光鸭业务响应格式无效'); }
    if (data.code === 117 && refresh && server.refreshToken.length > 0) { await GuangyaAuthorization.refresh(server); if (gen !== this.generation) { throw new Error('光鸭请求已取消'); } return this.request(server, route, false); }
    if (response.status !== 200 || data.code !== 0 || data.data === undefined) { throw new Error('光鸭请求失败（HTTP ' + response.status.toString() + '，业务码 ' + (data.code !== undefined ? data.code.toString() : '缺失') + '），请核对应用能力与用户授权'); }
    return data.data;
  }
  private file(raw: GuangyaFile): CloudFile {
    if (typeof raw.fileId !== 'string' || raw.fileId.length === 0 || typeof raw.fileName !== 'string' || (raw.resType !== 1 && raw.resType !== 2)) { throw new Error('光鸭文件标识、名称或资源类型无效'); }
    const file = new CloudFile(); file.id = raw.fileId; file.name = raw.fileName; file.directory = raw.resType === 2;
    file.size = raw.fileSize !== undefined ? Number(raw.fileSize) : 0; if (!Number.isSafeInteger(file.size) || file.size < 0) { throw new Error('光鸭文件大小超出可表示范围'); }
    file.video = raw.fileType === 2 || (typeof raw.mineType === 'string' && raw.mineType.startsWith('video/'));
    const extension = /\.([A-Za-z0-9]+)$/.exec(file.name); file.container = typeof raw.ext === 'string' ? raw.ext.replace(/^\./, '').toLowerCase() : extension !== null ? extension[1].toLowerCase() : '';
    if (typeof raw.thumbnail === 'string' && raw.thumbnail.length > 0) { file.thumbnail = DirectSourceHttp.resolve(raw.thumbnail, raw.thumbnail); }
    if (raw.ctime !== undefined && raw.ctime > 0) { file.created = new Date(raw.ctime * 1000).toISOString(); }
    if (raw.utime !== undefined && raw.utime > 0) { file.modified = new Date(raw.utime * 1000).toISOString(); } return file;
  }
  async login(server: ServerConfig, token: string): Promise<ServerConfig> {
    if (token.trim().length > 0) { server.token = token.trim().replace(/^Bearer\s+/i, ''); }
    const account = await this.request(server, 'user/get_user_info');
    if (typeof account.userId !== 'string' || account.userId.length === 0) { throw new Error('光鸭用户身份响应无效'); }
    server.userId = account.userId; server.serverName = typeof account.nickName === 'string' ? account.nickName : server.name;
    await this.listPage(server, this.rootId(server), 0, 1); return server;
  }
  protected async listPage(server: ServerConfig, parent: string, pageIndex: number, limit: number): Promise<CloudPage> {
    const data = await this.request(server, 'file/get_file_list?page=' + pageIndex.toString() + '&pageSize=' + limit.toString() + '&orderBy=0&sortType=0'
      + (parent !== 'guangya:root' ? '&parentId=' + encodeURIComponent(parent) : ''));
    if (!Array.isArray(data.list) || !Number.isSafeInteger(data.total) || (data.total as number) < 0) { throw new Error('光鸭目录响应缺少完整分页信息'); }
    const page = new CloudPage(); page.files = data.list.map((raw: GuangyaFile) => this.file(raw)); page.total = data.total as number; page.next = pageIndex + 1;
    page.complete = page.total === 0; return page;
  }
  protected async readFile(server: ServerConfig, id: string): Promise<CloudFile> {
    if (id.length === 0 || id === 'guangya:root') { throw new Error('请选择光鸭实际文件'); }
    const data = await this.request(server, 'file/get_file_detail?fileId=' + encodeURIComponent(id));
    if (data.fileInfo === undefined || data.fileInfo.fileId !== id) { throw new Error('光鸭文件详情与请求不匹配'); } return this.file(data.fileInfo);
  }
  protected async resolveFile(server: ServerConfig, file: CloudFile): Promise<PlaybackInfo> {
    const data = await this.request(server, 'file/get_res_download_url?fileId=' + encodeURIComponent(file.id));
    if (typeof data.signedURL !== 'string' || data.signedURL.length === 0 || !Number.isFinite(data.urlDuration) || (data.urlDuration as number) <= 0) { throw new Error('光鸭未返回有效文件下载地址或下载权限'); }
    const info = new PlaybackInfo(); info.url = DirectSourceHttp.resolve(data.signedURL, data.signedURL); info.headers = {}; info.isHls = DirectSourceHttp.extension(info.url) === 'm3u8'; return info;
  }
}
