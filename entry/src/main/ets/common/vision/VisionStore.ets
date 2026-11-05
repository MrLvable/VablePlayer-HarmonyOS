import { util, url } from '@kit.ArkTS';
import { ServerConfig, MediaItem } from '../Models';
import { Store } from '../Store';
import { SourceIdentity } from '../services/SourceIdentity';
import { VisionReference, VisionPlaylist, VisionSnapshot } from './VisionModels';

interface VisionDocument { version: number; watchLater: VisionReference[]; playlists: VisionPlaylist[]; }

/** Personal library state; remote discovery/recommendation lists never stand in for user intent. */
export class VisionStore {
  private static readonly KEY: string = 'vision_library_v1';
  private static chain: Promise<void> = Promise.resolve();
  static key(server: ServerConfig, itemId: string): string { return SourceIdentity.key(SourceIdentity.scope(server) + '\u0000' + itemId); }
  private static art(value: string): string {
    if (typeof value !== 'string' || value.length > 2048 || /[\u0000-\u001f?#]/.test(value)) { return ''; }
    if (/^https?:\/\//i.test(value)) {
      try { const parsed = new url.URL(value); return parsed.username.length === 0 && parsed.password.length === 0 ? value : ''; } catch (e) { return ''; }
    }
    return value.indexOf('://') < 0 ? value : '';
  }
  static snapshot(item: MediaItem): MediaItem {
    if (typeof item.id !== 'string' || item.id.length === 0 || item.id.length > 2048
      || /https?:\/\/|https?%3a%2f%2f|[?\u0000-\u001f]/i.test(item.id)) { throw new Error('此来源条目标识不可安全保存，请先重新读取影片'); }
    const copy = new MediaItem(); copy.id = item.id; copy.name = typeof item.name === 'string' ? item.name.substring(0, 512) : '';
    copy.type = typeof item.type === 'string' ? item.type : ''; copy.year = Number.isFinite(item.year) ? item.year : 0;
    copy.overview = typeof item.overview === 'string' ? item.overview.substring(0, 2000) : '';
    copy.imageTag = VisionStore.art(item.imageTag); copy.backdropTag = VisionStore.art(item.backdropTag); copy.hasPrimaryImage = copy.imageTag.length > 0;
    copy.container = typeof item.container === 'string' ? item.container : ''; copy.premiereDate = typeof item.premiereDate === 'string' ? item.premiereDate : '';
    copy.createdAt = typeof item.createdAt === 'string' ? item.createdAt : ''; copy.modifiedAt = typeof item.modifiedAt === 'string' ? item.modifiedAt : '';
    copy.runtimeTicks = Number.isSafeInteger(item.runtimeTicks) && item.runtimeTicks >= 0 ? item.runtimeTicks : 0;
    copy.progressTicks = Number.isSafeInteger(item.progressTicks) && item.progressTicks >= 0 ? item.progressTicks : 0;
    copy.seriesId = typeof item.seriesId === 'string' ? item.seriesId : ''; copy.seriesName = typeof item.seriesName === 'string' ? item.seriesName : '';
    copy.indexNumber = Number.isInteger(item.indexNumber) ? item.indexNumber : 0; copy.indexNumberKnown = item.indexNumberKnown === true;
    copy.parentIndexNumber = Number.isInteger(item.parentIndexNumber) ? item.parentIndexNumber : 0; copy.parentIndexNumberKnown = item.parentIndexNumberKnown === true;
    copy.played = item.played === true; return copy;
  }
  private static reference(server: ServerConfig, item: MediaItem): VisionReference {
    const ref = new VisionReference(); ref.key = VisionStore.key(server, item.id); ref.serverId = server.id;
    ref.accountScope = SourceIdentity.scope(server); ref.item = VisionStore.snapshot(item); ref.addedAt = Date.now(); return ref;
  }
  private static parseReference(raw: VisionReference): VisionReference {
    if (raw === null || typeof raw !== 'object' || typeof raw.key !== 'string' || !/^[a-f0-9]{64}$/.test(raw.key)
      || typeof raw.serverId !== 'string' || typeof raw.accountScope !== 'string' || !/^[a-f0-9]{64}$/.test(raw.accountScope)) { throw new Error('待看条目格式无效'); }
    const ref = new VisionReference(); ref.key = raw.key; ref.serverId = raw.serverId; ref.accountScope = raw.accountScope;
    ref.item = VisionStore.snapshot(raw.item);
    if (ref.key !== SourceIdentity.key(ref.accountScope + '\u0000' + ref.item.id)) { throw new Error('待看条目身份无效'); }
    ref.addedAt = Number.isFinite(raw.addedAt) ? raw.addedAt : 0; return ref;
  }
  private static async read(): Promise<VisionDocument> {
    const text = await Store.get(VisionStore.KEY, '');
    if (text.length === 0) { return { version: 2, watchLater: [], playlists: [] }; }
    if (text.length > 2097152) { throw new Error('Vision 本机记录超过读取上限'); }
    try {
      const raw = JSON.parse(text) as VisionDocument;
      if ((raw.version !== 1 && raw.version !== 2) || !Array.isArray(raw.watchLater) || !Array.isArray(raw.playlists) || raw.watchLater.length > 500 || raw.playlists.length > 250) { throw new Error('format'); }
      const watch = raw.watchLater.map((entry: VisionReference) => VisionStore.parseReference(entry));
      const playlists: VisionPlaylist[] = []; const ids: Set<string> = new Set();
      raw.playlists.forEach((entry: VisionPlaylist) => {
        if (entry === null || typeof entry.id !== 'string' || entry.id.length === 0 || ids.has(entry.id) || typeof entry.name !== 'string'
          || !Array.isArray(entry.entries) || entry.entries.length > 200) { throw new Error('format'); }
        ids.add(entry.id); const refs = entry.entries.map((ref: VisionReference) => VisionStore.parseReference(ref));
        const owners: string[] = typeof entry.accountScope === 'string' && entry.accountScope.length > 0 ? [entry.accountScope] : [];
        refs.forEach((ref: VisionReference) => { if (owners.length === 0 || typeof entry.accountScope !== 'string' || entry.accountScope.length === 0) { if (owners.indexOf(ref.accountScope) < 0) { owners.push(ref.accountScope); } } });
        // Empty legacy lists have no trustworthy account owner. Preserve them in
        // storage, but never assign their name to whichever account opens first.
        if (owners.length === 0) { owners.push(''); }
        owners.forEach((owner: string) => {
          if (owner.length > 0 && !/^[a-f0-9]{64}$/.test(owner)) { throw new Error('format'); }
          if (typeof entry.accountScope === 'string' && entry.accountScope.length > 0 && refs.some((ref: VisionReference) => ref.accountScope !== owner)) { throw new Error('scope'); }
          const playlist = new VisionPlaylist(); playlist.accountScope = owner;
          playlist.id = typeof entry.accountScope === 'string' ? entry.id : SourceIdentity.key('vision-playlist\u0000' + entry.id + '\u0000' + owner);
          playlist.name = entry.name.substring(0, 80); playlist.createdAt = Number.isFinite(entry.createdAt) ? entry.createdAt : 0;
          playlist.entries = refs.filter((ref: VisionReference) => ref.accountScope === owner); playlists.push(playlist);
        });
      });
      if (playlists.length > 250) { throw new Error('capacity'); }
      return { version: 2, watchLater: watch, playlists: playlists };
    } catch (e) { throw new Error('Vision 本机记录无法读取，原记录已保留'); }
  }
  private static async write(document: VisionDocument): Promise<void> {
    const text = JSON.stringify(document); if (text.length > 2097152) { throw new Error('Vision 本机记录已达容量限制'); }
    await Store.set(VisionStore.KEY, text); if (await Store.get(VisionStore.KEY, '') !== text) { throw new Error('Vision 记录未能完整保存，请重试'); }
  }
  private static mutate(work: (document: VisionDocument) => void): Promise<void> {
    const task = VisionStore.chain.then(async () => { const document = await VisionStore.read(); work(document); await VisionStore.write(document); });
    VisionStore.chain = task.then(() => {}, () => {}); return task;
  }
  static async load(servers: ServerConfig[]): Promise<VisionSnapshot> {
    const scopes = servers.map((server: ServerConfig) => SourceIdentity.scope(server)); const document = await VisionStore.read(); const result = new VisionSnapshot();
    result.watchLater = document.watchLater.filter((ref: VisionReference) => scopes.indexOf(ref.accountScope) >= 0).sort((a: VisionReference, b: VisionReference) => b.addedAt - a.addedAt);
    result.playlists = document.playlists.filter((entry: VisionPlaylist) => scopes.indexOf(entry.accountScope) >= 0).map((entry: VisionPlaylist) => {
      const playlist = new VisionPlaylist(); playlist.id = entry.id; playlist.accountScope = entry.accountScope; playlist.name = entry.name; playlist.createdAt = entry.createdAt;
      playlist.entries = entry.entries.filter((ref: VisionReference) => scopes.indexOf(ref.accountScope) >= 0); return playlist;
    }); return result;
  }
  static async isWatchLater(server: ServerConfig, itemId: string): Promise<boolean> { const key = VisionStore.key(server, itemId); return (await VisionStore.read()).watchLater.some((entry: VisionReference) => entry.key === key); }
  static setWatchLater(server: ServerConfig, item: MediaItem, enabled: boolean): Promise<void> {
    const ref = VisionStore.reference(server, item);
    return VisionStore.mutate((document: VisionDocument) => {
      const index = document.watchLater.findIndex((entry: VisionReference) => entry.key === ref.key);
      if (!enabled) { document.watchLater = document.watchLater.filter((entry: VisionReference) => entry.key !== ref.key); }
      else if (index >= 0) { ref.addedAt = document.watchLater[index].addedAt; document.watchLater[index] = ref; }
      else { if (document.watchLater.length >= 500) { throw new Error('待看已达 500 条，请先移除部分内容'); } document.watchLater.push(ref); }
    });
  }
  static async toggleWatchLater(server: ServerConfig, item: MediaItem): Promise<boolean> {
    const ref = VisionStore.reference(server, item); let enabled = false;
    await VisionStore.mutate((document: VisionDocument) => {
      const found = document.watchLater.some((entry: VisionReference) => entry.key === ref.key); enabled = !found;
      if (found) { document.watchLater = document.watchLater.filter((entry: VisionReference) => entry.key !== ref.key); }
      else { if (document.watchLater.length >= 500) { throw new Error('待看已达 500 条'); } document.watchLater.push(ref); }
    }); return enabled;
  }
  static async createPlaylist(name: string, server: ServerConfig): Promise<string> {
    const title = name.trim(); if (title.length === 0 || title.length > 80) { throw new Error('播放列表名称需为 1–80 个字符'); }
    const id = util.generateRandomUUID(); await VisionStore.mutate((document: VisionDocument) => {
      const scope = SourceIdentity.scope(server);
      if (document.playlists.length >= 250 || document.playlists.filter((list: VisionPlaylist) => list.accountScope === scope).length >= 50) { throw new Error('播放列表已达容量上限'); }
      const playlist = new VisionPlaylist(); playlist.id = id; playlist.accountScope = scope; playlist.name = title; playlist.createdAt = Date.now(); document.playlists.push(playlist);
    }); return id;
  }
  static renamePlaylist(id: string, name: string, server: ServerConfig): Promise<void> {
    const title = name.trim(); if (title.length === 0 || title.length > 80) { return Promise.reject(new Error('播放列表名称需为 1–80 个字符')); }
    return VisionStore.mutate((document: VisionDocument) => { const list = document.playlists.find((entry: VisionPlaylist) => entry.id === id && entry.accountScope === SourceIdentity.scope(server)); if (list === undefined) { throw new Error('当前账号中不存在此播放列表'); } list.name = title; });
  }
  static deletePlaylist(id: string, server: ServerConfig): Promise<void> { return VisionStore.mutate((document: VisionDocument) => { document.playlists = document.playlists.filter((entry: VisionPlaylist) => entry.id !== id || entry.accountScope !== SourceIdentity.scope(server)); }); }
  static addToPlaylist(id: string, server: ServerConfig, item: MediaItem): Promise<void> {
    const ref = VisionStore.reference(server, item); return VisionStore.mutate((document: VisionDocument) => {
      const list = document.playlists.find((entry: VisionPlaylist) => entry.id === id && entry.accountScope === ref.accountScope); if (list === undefined) { throw new Error('当前账号中不存在此播放列表'); }
      if (list.entries.some((entry: VisionReference) => entry.key === ref.key)) { return; }
      if (list.entries.length >= 200) { throw new Error('单个播放列表已达 200 条'); } list.entries.push(ref);
    });
  }
  static removeFromPlaylist(id: string, key: string, server: ServerConfig): Promise<void> { return VisionStore.mutate((document: VisionDocument) => { const list = document.playlists.find((entry: VisionPlaylist) => entry.id === id && entry.accountScope === SourceIdentity.scope(server)); if (list === undefined) { throw new Error('当前账号中不存在此播放列表'); } list.entries = list.entries.filter((entry: VisionReference) => entry.key !== key); }); }
}
