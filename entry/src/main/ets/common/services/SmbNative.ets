import nativeSmb, { SmbConnectionOptions, SmbDirectoryEntry, SmbFileStat, SmbReadSession } from 'libnas_smb.so';
import { ServerConfig } from '../Models';

/** Typed native boundary. Passwords remain runtime fields, never smb:// URLs. */
export class SmbNative {
  private static readSequence: number = 0;
  static options(server: ServerConfig): SmbConnectionOptions {
    if (server.kind !== 'smb' || server.connectionMode !== 'direct') { throw new Error('此连接不是 SMB 直连'); }
    let host = server.host.trim();
    if (host.startsWith('[') && host.endsWith(']')) { host = host.substring(1, host.length - 1); }
    if (host.length === 0 || /[\s/@?#\x00]/.test(host) || !Number.isInteger(server.port) || server.port < 1 || server.port > 65535) {
      throw new Error('SMB 主机或端口无效');
    }
    const share = server.shareName.trim();
    if (share.length === 0 || /[\\/\x00]/.test(share) || share === '.' || share === '..') { throw new Error('请填写有效的 SMB 共享名称'); }
    const anonymous = server.authMode === 'anonymous';
    if (!anonymous && server.username.length === 0) { throw new Error('请填写 SMB 用户名，或选择匿名访问'); }
    return { server: (host.indexOf(':') >= 0 ? '[' + host + ']' : host) + ':' + server.port.toString(),
      share: share, username: anonymous ? '' : server.username, password: anonymous ? '' : server.password,
      domain: server.domain, timeoutSeconds: 8 };
  }
  static path(value: string): string {
    const parts = value.replace(/\\/g, '/').split('/').filter((part: string) => part.length > 0);
    if (parts.some((part: string) => part === '.' || part === '..' || part.indexOf('\x00') >= 0)) { throw new Error('SMB 路径不能包含相对跳转'); }
    const path = '/' + parts.join('/');
    if (path.length > 4096) { throw new Error('SMB 路径过长'); }
    return path;
  }
  static id(path: string): string { return 'smb:' + encodeURIComponent(SmbNative.path(path)); }
  static fromId(server: ServerConfig, id: string): string {
    const root = SmbNative.path(server.rootPath);
    let path = root;
    if (id.length > 0) {
      if (!id.startsWith('smb:')) { throw new Error('不是此 SMB 来源的文件标识'); }
      try { path = SmbNative.path(decodeURIComponent(id.substring(4))); } catch (e) { throw new Error('SMB 文件标识无效'); }
    }
    if (root !== '/' && path !== root && !path.startsWith(root + '/')) { throw new Error('文件不在已配置的 SMB 根目录中'); }
    return path;
  }
  static nativePath(path: string): string { return SmbNative.path(path).substring(1); }
  static list(server: ServerConfig, path: string): Promise<SmbDirectoryEntry[]> {
    return nativeSmb.listDirectory(SmbNative.options(server), SmbNative.nativePath(path));
  }
  static stat(server: ServerConfig, path: string): Promise<SmbFileStat> {
    return nativeSmb.stat(SmbNative.options(server), SmbNative.nativePath(path));
  }
  static open(server: ServerConfig, path: string): Promise<SmbReadSession> {
    return nativeSmb.openRead(SmbNative.options(server), SmbNative.nativePath(path));
  }
  static requestId(): number {
    if (SmbNative.readSequence >= Number.MAX_SAFE_INTEGER - 1) { throw new Error('SMB 读取标识已耗尽，请重启应用'); }
    return ++SmbNative.readSequence;
  }
  static read(session: number, offset: number, length: number, requestId: number): Promise<ArrayBuffer> {
    return nativeSmb.readAt(session, offset, length, requestId);
  }
  static cancel(requestId: number): void { nativeSmb.cancelRead(requestId); }
  static close(session: number): Promise<void> { return nativeSmb.close(session); }
}
