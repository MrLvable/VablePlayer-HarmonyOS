import { ServerConfig, PlaybackInfo } from '../Models';
import { MediaService, NativePlaybackSession } from './MediaService';
import { CloudCatalogBase } from './CloudCatalogBase';
import { CloudModeCatalog } from './CloudModeCatalog';

export class CloudAdapterBase implements MediaService {
  kind: string;
  catalog: CloudModeCatalog;
  constructor(kind: string, direct: CloudCatalogBase) { this.kind = kind; this.catalog = new CloudModeCatalog(direct); }
  login(server: ServerConfig, password: string): Promise<ServerConfig> {
    if (server.connectionMode === 'aggregate') { return this.catalog.aggregate.login(server, password); }
    if (server.connectionMode !== 'direct') { return Promise.reject(new Error('不支持的云盘连接方式')); }
    return this.catalog.direct.login(server, password);
  }
  getPlaybackInfo(server: ServerConfig, id: string, selected: string, _ticks: number): Promise<PlaybackInfo> {
    if (server.connectionMode !== 'aggregate' && server.connectionMode !== 'direct') { return Promise.reject(new Error('不支持的云盘连接方式')); }
    return server.connectionMode === 'aggregate' ? this.catalog.aggregate.playback(server, id, selected) : this.catalog.direct.playback(server, id, selected);
  }
  streamUrl(server: ServerConfig, id: string): string { if (server.connectionMode !== 'aggregate' && server.connectionMode !== 'direct') { throw new Error('不支持的云盘连接方式'); } return server.connectionMode === 'aggregate' ? this.catalog.aggregate.stream(server, id) : this.catalog.direct.stream(server, id); }
  streamHeaders(server: ServerConfig): Record<string, string> { if (server.connectionMode !== 'aggregate' && server.connectionMode !== 'direct') { throw new Error('不支持的云盘连接方式'); } return server.connectionMode === 'aggregate' ? this.catalog.aggregate.headers(server) : {}; }
  playHeaders(server: ServerConfig): Record<string, string> { return this.streamHeaders(server); }
  createNativePlayback(): NativePlaybackSession | null { return null; }
}
