import { url } from '@kit.ArkTS';
import { ServerConfig, PlaybackInfo } from '../Models';
import { CloudCatalogBase, CloudFile, CloudPage } from './CloudCatalogBase';
import { DirectSourceHttp } from './DirectSourceHttp';
import { CloudDriveWire, ProtoField } from './CloudDriveWire';

export class CloudDriveCatalog extends CloudCatalogBase {
  private transport: DirectSourceHttp = new DirectSourceHttp();
  cancel(): void { this.transport.cancel(); }
  private path(server: ServerConfig, value: string): string {
    if (!value.startsWith('/') || /[\\\u0000-\u001f]/.test(value) || value.split('/').some((piece: string) => piece === '..' || piece === '.')) { throw new Error('CloudDrive 文件路径无效'); }
    const root = (server.rootPath.length > 0 ? server.rootPath : '/').replace(/\/$/, '') || '/'; const path = value.replace(/\/$/, '') || '/';
    if (root !== '/' && path !== root && !path.startsWith(root + '/')) { throw new Error('CloudDrive 路径超出配置根目录'); } return path;
  }
  protected rootId(server: ServerConfig): string { return this.path(server, server.rootPath.length > 0 ? server.rootPath : '/'); }
  private async rpc(server: ServerConfig, name: string, bytes: Uint8Array): Promise<Uint8Array[]> {
    if (!/^(GetSystemInfo|GetSubFiles|FindFileByPath|GetDownloadUrlPath)$/.test(name)) { throw new Error('不支持的 CloudDrive 只读方法'); }
    const headers: Record<string, string> = { 'Content-Type': 'application/grpc-web+proto', 'Accept': 'application/grpc-web+proto', 'X-Grpc-Web': '1' };
    if (server.token.length > 0) { headers['Authorization'] = 'Bearer ' + server.token; }
    const framed = CloudDriveWire.frame(bytes); const body = framed.buffer.slice(framed.byteOffset, framed.byteOffset + framed.byteLength);
    const response = await this.transport.requestBinary(server.baseUrl().replace(/\/+$/, '') + '/clouddrive.CloudDriveFileSrv/' + name, 'POST', headers, body);
    if (response.status !== 200) { throw new Error('CloudDrive RPC 连接失败（HTTP ' + response.status.toString() + '），请核对官方 HTTP 服务端口'); }
    return CloudDriveWire.replies(response.data, response.headers);
  }
  private date(fields: ProtoField[], number: number): string {
    const values = CloudDriveWire.nested(fields, number); if (values.length === 0) { return ''; }
    const seconds = CloudDriveWire.integer(values[0], 1); return Number.isSafeInteger(seconds) && seconds > 0 && seconds < 253402300800 ? new Date(seconds * 1000).toISOString() : '';
  }
  private file(server: ServerConfig, fields: ProtoField[]): CloudFile {
    if (CloudDriveWire.integer(fields, 36) !== 0) { throw new Error('CloudDrive 返回了禁止访问的文件'); }
    const file = new CloudFile(); file.path = this.path(server, CloudDriveWire.text(fields, 3)); file.id = file.path; file.name = CloudDriveWire.text(fields, 2);
    if (file.name.length === 0 && file.path === '/') { file.name = server.name.length > 0 ? server.name : 'CloudDrive'; }
    if (file.name.length === 0) { throw new Error('CloudDrive 文件缺少名称'); }
    file.directory = CloudDriveWire.integer(fields, 30) === 1 || CloudDriveWire.integer(fields, 5) === 0;
    file.size = CloudDriveWire.integer(fields, 4); if (!Number.isSafeInteger(file.size) || file.size < 0) { throw new Error('CloudDrive 文件大小超出当前播放器可表示范围'); }
    file.created = this.date(fields, 6); file.modified = this.date(fields, 7);
    const thumbnail = CloudDriveWire.text(fields, 10); if (thumbnail.length > 0) { file.thumbnail = DirectSourceHttp.resolve(server.baseUrl() + '/', thumbnail); }
    const extension = /\.([A-Za-z0-9]+)$/.exec(file.name); file.container = extension === null ? '' : extension[1].toLowerCase(); return file;
  }
  async login(server: ServerConfig, token: string): Promise<ServerConfig> {
    if (token.trim().length > 0) { server.token = token.trim().replace(/^Bearer\s+/i, ''); }
    if (server.token.length === 0) { throw new Error('请提供在 CloudDrive2 中创建的只读 API 令牌'); }
    const replies = await this.rpc(server, 'GetSystemInfo', new Uint8Array(0));
    if (replies.length !== 1) { throw new Error('CloudDrive 系统信息响应无效'); }
    const fields = CloudDriveWire.fields(replies[0]);
    if (CloudDriveWire.integer(fields, 3) !== 1 || CloudDriveWire.integer(fields, 5) !== 0) { throw new Error('CloudDrive 服务尚未就绪'); }
    const account = CloudDriveWire.text(fields, 10); if (account.length > 0) { server.username = account; }
    await this.listPage(server, this.rootId(server), 0, 200); // Public system info alone does not verify token scope.
    server.serverName = server.name.length > 0 ? server.name : 'CloudDrive2'; return server;
  }
  protected async listPage(server: ServerConfig, parent: string, start: number, _limit: number): Promise<CloudPage> {
    if (start !== 0) { throw new Error('CloudDrive 流式目录不支持虚构的偏移分页'); }
    const replies = await this.rpc(server, 'GetSubFiles', CloudDriveWire.string(1, this.path(server, parent)));
    const page = new CloudPage();
    replies.forEach((reply: Uint8Array) => { CloudDriveWire.nested(CloudDriveWire.fields(reply), 1).forEach((fields: ProtoField[]) => {
      const file = this.file(server, fields);
      const expected = (parent === '/' ? '/' : parent.replace(/\/$/, '') + '/');
      if (!file.path.startsWith(expected) || file.path.substring(expected.length).indexOf('/') >= 0) { throw new Error('CloudDrive 目录回复含非直属子项'); }
      page.files.push(file); if (page.files.length > 5000) { throw new Error('CloudDrive 单目录超过 5000 项'); }
    }); }); page.complete = true; page.next = page.files.length; return page;
  }
  protected async readFile(server: ServerConfig, id: string): Promise<CloudFile> {
    // fullPathName is already absolute; a second parent prefix would duplicate a configured subdirectory.
    const path = this.path(server, id); const replies = await this.rpc(server, 'FindFileByPath', CloudDriveWire.string(2, path));
    if (replies.length !== 1) { throw new Error('CloudDrive 文件信息响应无效'); }
    const file = this.file(server, CloudDriveWire.fields(replies[0])); if (file.id !== path) { throw new Error('CloudDrive 文件信息与请求不匹配'); } return file;
  }
  protected async resolveFile(server: ServerConfig, file: CloudFile): Promise<PlaybackInfo> {
    const replies = await this.rpc(server, 'GetDownloadUrlPath', CloudDriveWire.join([CloudDriveWire.string(1, file.path), CloudDriveWire.bool(4, true)]));
    if (replies.length !== 1) { throw new Error('CloudDrive 下载信息响应无效'); }
    const fields = CloudDriveWire.fields(replies[0]); let address = CloudDriveWire.text(fields, 3); const headers: Record<string, string> = {};
    CloudDriveWire.nested(fields, 5).forEach((entry: ProtoField[]) => { const key = CloudDriveWire.text(entry, 1); const value = CloudDriveWire.text(entry, 2);
      if (!/^[A-Za-z0-9!#$%&'*+.^_|~-]+$/.test(key) || /[\r\n]/.test(value)) { throw new Error('CloudDrive 返回了无效下载请求头'); } headers[key] = value;
    });
    const agent = CloudDriveWire.text(fields, 4); if (agent.length > 0) { if (/[\r\n]/.test(agent)) { throw new Error('CloudDrive 下载客户端标识无效'); } headers['User-Agent'] = agent; }
    if (address.length === 0) {
      const base = new url.URL(server.baseUrl());
      const template = CloudDriveWire.text(fields, 1).replace(/\{SCHEME\}/g, base.protocol.replace(':', '')).replace(/\{HOST\}/g, base.host).replace(/\{PREVIEW\}/g, 'false');
      if (template.length === 0 || /\{[^}]+\}/.test(template)) { throw new Error('CloudDrive 未返回可用下载地址'); }
      address = DirectSourceHttp.resolve(server.baseUrl() + '/', template);
      if (!DirectSourceHttp.sameOrigin(server.baseUrl(), address)) { throw new Error('CloudDrive 代理地址离开了当前服务器'); }
      headers['Authorization'] = 'Bearer ' + server.token;
    }
    const info = new PlaybackInfo(); info.url = DirectSourceHttp.resolve(address, address); info.headers = headers;
    info.isHls = DirectSourceHttp.extension(info.url) === 'm3u8'; return info;
  }
}
