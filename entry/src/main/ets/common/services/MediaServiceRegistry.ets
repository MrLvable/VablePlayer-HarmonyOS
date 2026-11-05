import { MediaService } from './MediaService';
import { FnosAdapter } from './FnosAdapter';
import { EmbyAdapter } from './EmbyAdapter';
import { JellyfinAdapter } from './JellyfinAdapter';
import { FnosNativeAdapter } from './FnosNativeAdapter';
import { PlexAdapter } from './PlexAdapter';
import { WebDavAdapter } from './WebDavAdapter';
import { IptvAdapter } from './IptvAdapter';
import { SmbAdapter } from './SmbAdapter';
import { CloudDriveAdapter } from './CloudDriveAdapter';
import { BaiduAdapter } from './BaiduAdapter';
import { GuangyaAdapter } from './GuangyaAdapter';
import { LocalAdapter } from './LocalAdapter';
import { CustomAdapter } from './CustomAdapter';
import { ServerConfig } from '../Models';

export class MediaServiceRegistry {
  static forServer(server: ServerConfig): MediaService {
    if (server.connectionMode === 'direct') { return MediaServiceRegistry.forKind(server.kind); }
    if (server.connectionMode === 'aggregate') {
      if (['clouddrive', 'baidu', 'guangya', 'smb', 'custom'].indexOf(server.kind) < 0) { throw new Error('此来源不支持聚合 WebDAV 连接'); }
      // Keep the original source kind/mode on the profile for scope and credential isolation.
      return new WebDavAdapter();
    }
    throw new Error('不支持的来源连接方式');
  }

  static forKind(kind: string): MediaService {
    if (kind === 'fnos') { return new FnosAdapter(); }
    if (kind === 'emby') { return new EmbyAdapter(); }
    if (kind === 'jellyfin') { return new JellyfinAdapter(); }
    if (kind === 'fnos-native') { return new FnosNativeAdapter(); }
    if (kind === 'plex') { return new PlexAdapter(); }
    if (kind === 'webdav') { return new WebDavAdapter(); }
    if (kind === 'iptv') { return new IptvAdapter(); }
    if (kind === 'smb') { return new SmbAdapter(); }
    if (kind === 'clouddrive') { return new CloudDriveAdapter(); }
    if (kind === 'baidu') { return new BaiduAdapter(); }
    if (kind === 'guangya') { return new GuangyaAdapter(); }
    if (kind === 'local') { return new LocalAdapter(); }
    if (kind === 'custom') { return new CustomAdapter(); }
    throw new Error('不支持的服务器类型：' + kind);
  }
}
