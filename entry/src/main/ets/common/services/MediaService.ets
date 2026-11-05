import { ServerConfig, PlaybackInfo } from '../Models';
import { FnosPlaybackResult } from '../FnosPlayback';
import { MediaCatalog } from './MediaCatalog';

export interface NativePlaybackSession {
  resolve(url: string, token: string, itemId: string): Promise<FnosPlaybackResult>;
  close(): Promise<void>;
}

export interface MediaService {
  kind: string;
  catalog: MediaCatalog;
  login(server: ServerConfig, password: string): Promise<ServerConfig>;
  getPlaybackInfo(server: ServerConfig, itemId: string, mediaSourceId: string, startTicks: number): Promise<PlaybackInfo>;
  streamUrl(server: ServerConfig, itemId: string): string;
  streamHeaders(server: ServerConfig): Record<string, string>;
  playHeaders(server: ServerConfig): Record<string, string>;
  createNativePlayback(): NativePlaybackSession | null;
}
